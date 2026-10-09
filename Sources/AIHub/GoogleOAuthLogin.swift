import AppKit
import Foundation
import Network
import AIHubCore

@MainActor
final class GoogleOAuthLogin {
    private let client: GoogleDesktopClient
    private let receiver: LoopbackOAuthReceiver
    private let verifier: String
    init(client: GoogleDesktopClient) throws {
        self.client = client
        verifier = try OAuthPKCE.random()
        receiver = try LoopbackOAuthReceiver()
    }
    func login() async throws -> String {
        defer { receiver.cancel() }
        let oauth = GoogleOAuthClient()
        let code = try await receiver.authorize { redirect in
            oauth.authorizationURL(client: self.client, redirectURI: redirect, state: self.receiver.state, verifier: self.verifier)
        }
        try Task.checkCancellation()
        let credential = try await oauth.exchange(code: code, client: client, redirectURI: receiver.redirectURI, verifier: verifier)
        return try CredentialEnvelope(baseURL: ChannelType.googleOAuth.defaultURL, authentication: .googleOAuth, google: credential).encoded()
    }
    func cancel() { receiver.cancel() }
}

@MainActor
final class AccountOAuthLogin {
    private let definition: AccountOAuthDefinition
    private let receiver: LoopbackOAuthReceiver
    private let verifier: String
    private let nonce: String
    init(channel: ChannelType) throws {
        definition = try AccountOAuthDefinition(channel: channel)
        verifier = try OAuthPKCE.random()
        nonce = try OAuthPKCE.random()
        receiver = try LoopbackOAuthReceiver(host: definition.callbackHost, port: definition.port, path: definition.callbackPath)
    }
    func login() async throws -> String {
        defer { receiver.cancel() }
        let code = try await receiver.authorize { _ in
            self.definition.authorizationURL(state: self.receiver.state, verifier: self.verifier, nonce: self.nonce)
        }
        try Task.checkCancellation()
        let credential = try await AccountOAuthClient().exchange(code: code, definition: definition, verifier: verifier, nonce: nonce)
        return try CredentialEnvelope(baseURL: definition.channel.defaultURL, authentication: .accountOAuth, account: credential).encoded()
    }
    func cancel() { receiver.cancel() }
}

/// One isolated callback listener per login. Bound only to the IPv4 loopback,
/// including flows whose registered redirect host is literally `localhost`.
@MainActor
final class LoopbackOAuthReceiver {
    let state: String
    private(set) var redirectURI = ""
    private let host: String
    private let port: UInt16?
    private let path: String
    private let openURL: @MainActor (URL) -> Bool
    private let timeoutSeconds: Double
    private var listener: NWListener?
    private var ready: CheckedContinuation<String, any Error>?
    private var callback: CheckedContinuation<String, any Error>?
    private var callbackResult: Result<String, any Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var timeout: Task<Void, Never>?

    init(host: String = "127.0.0.1", port: UInt16? = nil, path: String = "/oauth/callback",
         timeoutSeconds: Double = 300, openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) throws {
        guard ["127.0.0.1", "localhost"].contains(host), path.hasPrefix("/") else { throw OAuthCallbackError.invalid }
        state = try OAuthPKCE.random()
        self.host = host; self.port = port; self.path = path; self.openURL = openURL; self.timeoutSeconds = timeoutSeconds
    }

    func authorize(makeURL: @MainActor (String) -> URL) async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            defer { cancel() }
            timeout = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: .seconds(self.timeoutSeconds))
                    let error = HubError("登录超时，请重试。")
                    self.ready?.resume(throwing: error); self.ready = nil
                    self.finish(.failure(error))
                } catch {}
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            redirectURI = try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.stateUpdateHandler = { [weak self] status in Task { @MainActor in self?.listenerChanged(status) } }
                listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
                listener.start(queue: .main)
            }
            try Task.checkCancellation()
            guard openURL(makeURL(redirectURI)) else { throw HubError("无法打开登录浏览器。") }
            let code: String
            if let callbackResult { code = try callbackResult.get() }
            else { code = try await withCheckedThrowingContinuation { callback = $0 } }
            try Task.checkCancellation()
            return code
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func cancel() {
        finish(.failure(CancellationError()))
        ready?.resume(throwing: CancellationError()); ready = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        timeout?.cancel(); timeout = nil
    }
    private func listenerChanged(_ status: NWListener.State) {
        switch status {
        case .ready:
            guard let actualPort = listener?.port else { return }
            ready?.resume(returning: "http://\(host):\(actualPort.rawValue)\(path)"); ready = nil
        case .failed:
            let error = HubError("无法创建登录回调端口，请关闭其他登录窗口后重试。")
            ready?.resume(throwing: error); ready = nil
            finish(.failure(error))
        default: break
        }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .main)
        receive(connection, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var data = accumulated
                if let bytes { data.append(bytes) }
                guard data.count <= 8192, error == nil else { self.reply(connection, accepted: false); return }
                guard data.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if complete { self.reply(connection, accepted: false) }
                    else { self.receive(connection, accumulated: data) }
                    return
                }
                do {
                    let code = try OAuthCallback.code(httpRequest: data, redirectURI: self.redirectURI, expectedState: self.state)
                    self.reply(connection, accepted: true, code: code)
                } catch {
                    self.reply(connection, accepted: false)
                    if error as? OAuthCallbackError == .denied { self.finish(.failure(error)) }
                }
            }
        }
    }
    private func reply(_ connection: NWConnection, accepted: Bool, code: String? = nil) {
        let body = accepted ? "Authorization received. Return to AIHub." : "Invalid authorization callback."
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in
                self?.connections[ObjectIdentifier(connection)] = nil
                if let code { self?.finish(.success(code)) }
            }
        })
    }
    private func finish(_ result: Result<String, any Error>) {
        guard callbackResult == nil else { return }
        callbackResult = result
        callback?.resume(with: result); callback = nil
    }
}
