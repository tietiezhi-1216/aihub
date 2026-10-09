import CryptoKit
import Foundation
import Security

public struct GoogleOAuthCredential: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String
    public var refreshToken: String
    public var accessToken: String?
    public var expiresAt: Date?
    public var quotaProject: String?

    public init(clientID: String, clientSecret: String, refreshToken: String,
                accessToken: String? = nil, expiresAt: Date? = nil, quotaProject: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.quotaProject = quotaProject
    }

    public func validate() throws {
        guard clientID.hasSuffix(".apps.googleusercontent.com"), !refreshToken.isEmpty else {
            throw HubError("Google OAuth 凭据缺少有效的 client_id 或 refresh_token。")
        }
        for value in [clientID, clientSecret, refreshToken, accessToken ?? ""] { _ = try Validation.apiKey(value) }
        if let quotaProject {
            guard !quotaProject.isEmpty, quotaProject.count <= 128,
                  quotaProject.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._:".contains($0)) }) else {
                throw HubError("Google quota_project_id 格式无效。")
            }
        }
    }
}

public struct CredentialEnvelope: Codable, Sendable {
    public var version = 1
    public var baseURL: String
    public var authentication: AuthenticationMethod
    public var secret: String?
    public var google: GoogleOAuthCredential?
    public var account: AccountOAuthCredential?
    public static let prefix = "aihub-credential-v1:"

    public init(baseURL: String, authentication: AuthenticationMethod, secret: String? = nil, google: GoogleOAuthCredential? = nil, account: AccountOAuthCredential? = nil) {
        self.baseURL = baseURL
        self.authentication = authentication
        self.secret = secret
        self.google = google
        self.account = account
    }

    public func encoded() throws -> String {
        Self.prefix + String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public static func decode(_ value: String) throws -> CredentialEnvelope? {
        guard value.hasPrefix(prefix) else { return nil }
        guard value.utf8.count <= 64 * 1024,
              let credential = try? JSONDecoder().decode(Self.self, from: Data(value.dropFirst(prefix.count).utf8)),
              credential.version == 1 else { throw HubError("已保存的鉴权凭据格式无效。") }
        return credential
    }

    public func validate(for provider: Provider) throws {
        try provider.validateChannel()
        let bound = try Endpoint(baseURL, defaultVersion: provider.effectiveProtocol.defaultVersion).baseURL.absoluteString
        guard bound == (try provider.normalizedBaseURL), authentication == provider.authentication else {
            throw HubError("鉴权凭据与当前 API 地址或鉴权方式不匹配，请重新授权或导入。")
        }
        switch authentication {
        case .accountOAuth:
            guard let account, account.channel == provider.channelType else {
                throw HubError("登录凭据与渠道类型不匹配，请重新登录。")
            }
            try account.validate()
        case .googleOAuth:
            guard provider.effectiveProtocol == .gemini,
                  URLComponents(string: bound)?.host?.lowercased() == "generativelanguage.googleapis.com",
                  let google else { throw HubError("Google OAuth 仅用于官方 Gemini API，不能发送到自定义中转地址。") }
            try google.validate()
        case .bearer, .apiKey:
            guard let secret, !secret.isEmpty else { throw HubError("凭据中缺少密钥或访问令牌。") }
            _ = try Validation.apiKey(secret)
        }
    }

    public static func validateStored(_ value: String, for provider: Provider) throws -> String {
        try provider.validateChannel()
        if let envelope = try decode(value) {
            try envelope.validate(for: provider)
            return value
        }
        guard provider.authentication == .apiKey else {
            throw HubError("请导入对应的鉴权文件或重新登录。")
        }
        return try Validation.apiKey(value)
    }
}

public struct ImportedCredential: Sendable {
    public var value: String
    public var authentication: AuthenticationMethod
    public var baseURL: String?
    public var apiProtocol: APIProtocol?
    public var channelType: ChannelType? = nil
}

public enum CredentialImport {
    public static let maximumBytes = 256 * 1024

    public static func parse(_ data: Data, channel: ChannelType? = nil) throws -> ImportedCredential {
        guard !data.isEmpty, data.count <= maximumBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HubError("请选择有效的 JSON 鉴权文件（最大 256 KB）。")
        }
        if channel == .cliProxyAPI {
            guard Set(json.keys) == ["api_key"], let key = json["api_key"] as? String else {
                throw HubError("请导入只含 api_key 的本机访问密钥文件，不要使用厂商密钥或账号凭据文件。")
            }
            let value = try Validation.apiKey(key)
            guard !value.isEmpty else { throw HubError("本机访问密钥不能为空。") }
            return ImportedCredential(value: value, authentication: .apiKey, baseURL: nil, apiProtocol: .openAIChat, channelType: .cliProxyAPI)
        }
        if let account = try AccountCredentialImport.parse(json, channel: channel) { return account }
        if json["type"] as? String == "authorized_user" {
            guard let clientID = json["client_id"] as? String,
                  let clientSecret = json["client_secret"] as? String,
                  let refreshToken = json["refresh_token"] as? String else {
                throw HubError("Google 鉴权文件缺少 client_id、client_secret 或 refresh_token。")
            }
            let google = GoogleOAuthCredential(clientID: clientID, clientSecret: clientSecret,
                                               refreshToken: refreshToken, quotaProject: json["quota_project_id"] as? String)
            try google.validate()
            let base = "https://generativelanguage.googleapis.com/v1beta"
            let envelope = CredentialEnvelope(baseURL: base, authentication: .googleOAuth, google: google)
            return ImportedCredential(value: try envelope.encoded(), authentication: .googleOAuth, baseURL: base, apiProtocol: .gemini)
        }
        let fields: [(String, String?, APIProtocol?)] = [
            ("OPENAI_API_KEY", "https://api.openai.com/v1", .openAIResponses),
            ("ANTHROPIC_API_KEY", "https://api.anthropic.com/v1", .anthropic),
            ("GEMINI_API_KEY", "https://generativelanguage.googleapis.com/v1beta", .gemini),
            ("XAI_API_KEY", "https://api.x.ai/v1", .openAIChat),
            ("api_key", nil, nil)
        ]
        let keys = fields.compactMap { field -> (String, String?, APIProtocol?)? in
            guard let value = json[field.0] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (value, field.1, field.2)
        }
        guard keys.count <= 1 else { throw HubError("文件中包含多组 API Key，请分别导入。") }
        if let key = keys.first {
            return ImportedCredential(value: try Validation.apiKey(key.0), authentication: .apiKey, baseURL: key.1, apiProtocol: key.2)
        }
        if let access = json["access_token"] as? String,
           let base = json["api_address"] as? String,
           let protocolName = json["api_protocol"] as? String,
           let api = APIProtocol(rawValue: protocolName), api != .automatic {
            let normalized = try Endpoint(base, defaultVersion: api.defaultVersion).baseURL.absoluteString
            let secret = try Validation.apiKey(access)
            guard !secret.isEmpty else { throw HubError("访问令牌不能为空。") }
            let envelope = CredentialEnvelope(baseURL: normalized, authentication: .bearer, secret: secret)
            return ImportedCredential(value: try envelope.encoded(), authentication: .bearer, baseURL: normalized, apiProtocol: api)
        }
        throw HubError("此鉴权文件尚未适配，请选择对应渠道的 API Key 或完整登录凭据文件。")
    }
}

public struct ResolvedCredential: Sendable {
    public var secret: String
    public var bearer: Bool
    public var quotaProject: String?
    public var accountID: String? = nil
    public var projectID: String? = nil
}

public actor CredentialResolver {
    private let oauth: GoogleOAuthClient
    private let accountOAuth: AccountOAuthClient
    private var accountCache: [String: AccountOAuthCredential] = [:]
    private let vault: (any CredentialVault)?
    private var cache: [String: GoogleOAuthCredential] = [:]
    public init(transport: any HTTPTransport, vault: (any CredentialVault)? = nil) {
        oauth = GoogleOAuthClient(transport: transport)
        accountOAuth = AccountOAuthClient(transport: transport)
        self.vault = vault
    }

    public func resolve(_ value: String?, for provider: Provider) async throws -> ResolvedCredential {
        try provider.validateChannel()
        let raw = value ?? ""
        if raw.isEmpty, !provider.requiresAPIKey { return .init(secret: "", bearer: false) }
        let validated = try CredentialEnvelope.validateStored(raw, for: provider)
        guard let envelope = try CredentialEnvelope.decode(validated) else {
            guard !validated.isEmpty else { throw HubError("请输入 API Key 或导入鉴权文件。") }
            return .init(secret: validated, bearer: false)
        }

        if let account = envelope.account, envelope.authentication == .accountOAuth {
            let fingerprint = Self.fingerprint(validated)
            var current = accountCache[fingerprint] ?? account
            if current.expiresAt <= Date().addingTimeInterval(60) {
                current = try await accountOAuth.refresh(current)
                try Task.checkCancellation()
                if accountCache.count >= 32 { accountCache.removeAll() }
                accountCache[fingerprint] = current
            }
            try persistAccount(current, envelope: envelope, original: validated, provider: provider)
            return .init(secret: current.accessToken, bearer: true, accountID: current.accountID, projectID: current.projectID)
        }
        if let google = envelope.google, envelope.authentication == .googleOAuth {
            let fingerprint = SHA256.hash(data: Data(validated.utf8)).map { String(format: "%02x", $0) }.joined()
            var current = cache[fingerprint] ?? google
            if current.accessToken == nil || (current.expiresAt ?? .distantPast) <= Date().addingTimeInterval(60) {
                current = try await oauth.refresh(current)
                try Task.checkCancellation()
                if cache.count >= 32 { cache.removeAll() }
                cache[fingerprint] = current
            }
            // Retry persistence after a prior write failure; never overwrite a replacement or unsaved draft.
            if let vault, current != google, try vault.read(provider.id) == validated {
                var refreshed = envelope
                refreshed.google = current
                try vault.set(refreshed.encoded(), for: provider.id)
            }
            return .init(secret: current.accessToken ?? "", bearer: true, quotaProject: current.quotaProject)
        }
        return .init(secret: envelope.secret ?? "", bearer: envelope.authentication == .bearer)
    }
    public func refreshedCredential(_ value: String, for provider: Provider) throws -> String? {
        guard var envelope = try CredentialEnvelope.decode(value) else { return nil }
        try envelope.validate(for: provider)
        let fingerprint = Self.fingerprint(value)
        if envelope.authentication == .accountOAuth {
            guard let account = accountCache[fingerprint] else { return nil }
            envelope.account = account
            return try envelope.encoded()
        }
        guard envelope.authentication == .googleOAuth, let google = cache[fingerprint] else { return nil }
        envelope.google = google
        return try envelope.encoded()
    }

    public func setProject(_ project: String, value: String, for provider: Provider) throws {
        guard let envelope = try CredentialEnvelope.decode(value), var account = envelope.account,
              account.channel == .antigravity else { throw HubError("Antigravity 登录凭据无效。") }
        try envelope.validate(for: provider)
        account = accountCache[Self.fingerprint(value)] ?? account
        account.projectID = try Validation.apiKey(project)
        guard account.projectID?.isEmpty == false else { throw HubError("Antigravity 账户项目不可用。") }
        if accountCache.count >= 32 { accountCache.removeAll() }
        accountCache[Self.fingerprint(value)] = account
        try persistAccount(account, envelope: envelope, original: value, provider: provider)
    }
    private func persistAccount(_ account: AccountOAuthCredential, envelope: CredentialEnvelope, original: String, provider: Provider) throws {
        if let vault, account != envelope.account, try vault.read(provider.id) == original {
            var refreshed = envelope
            refreshed.account = account
            try vault.set(refreshed.encoded(), for: provider.id)
        }
    }
    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct GoogleDesktopClient: Sendable {
    public var clientID: String
    public var clientSecret: String
    public init(clientID: String, clientSecret: String) { self.clientID = clientID; self.clientSecret = clientSecret }
    public static func parse(_ data: Data) throws -> GoogleDesktopClient {
        guard data.count <= CredentialImport.maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = root["installed"] as? [String: Any],
              let id = installed["client_id"] as? String,
              id.hasSuffix(".apps.googleusercontent.com"),
              let secret = installed["client_secret"] as? String else {
            throw HubError("请选择 Google Cloud 下载的桌面应用 OAuth Client JSON 文件。")
        }
        _ = try Validation.apiKey(id)
        _ = try Validation.apiKey(secret)
        return .init(clientID: id, clientSecret: secret)
    }
}

public enum OAuthPKCE {
    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HubError("无法生成安全的 OAuth 随机数。")
        }
        return base64URL(Data(bytes))
    }
    public static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct GoogleOAuthClient: Sendable {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = SecureHTTPTransport()) { self.transport = transport }

    public func authorizationURL(client: GoogleDesktopClient, redirectURI: String, state: String, verifier: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: client.clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "state", value: state),
            .init(name: "code_challenge", value: OAuthPKCE.challenge(verifier)), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/generative-language.retriever"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")
        ]
        return components.url!
    }

    public func exchange(code: String, client: GoogleDesktopClient, redirectURI: String, verifier: String) async throws -> GoogleOAuthCredential {
        let response = try await token([
            "grant_type": "authorization_code", "code": code, "client_id": client.clientID,
            "client_secret": client.clientSecret, "redirect_uri": redirectURI, "code_verifier": verifier
        ])
        guard let refreshToken = response.refresh_token, !refreshToken.isEmpty else {
            throw HubError("Google 未返回 refresh_token，请重新登录并确认离线访问授权。")
        }
        return .init(clientID: client.clientID, clientSecret: client.clientSecret, refreshToken: refreshToken,
                     accessToken: response.access_token, expiresAt: Date().addingTimeInterval(response.expires_in))
    }

    public func refresh(_ credential: GoogleOAuthCredential) async throws -> GoogleOAuthCredential {
        try credential.validate()
        let response = try await token([
            "grant_type": "refresh_token", "refresh_token": credential.refreshToken,
            "client_id": credential.clientID, "client_secret": credential.clientSecret
        ])
        var current = credential
        current.accessToken = response.access_token
        current.expiresAt = Date().addingTimeInterval(response.expires_in)
        current.refreshToken = response.refresh_token ?? credential.refreshToken
        return current
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: TimeInterval
        let refresh_token: String?
        let token_type: String
    }
    private func token(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
        do {
            let (data, response) = try await transport.send(request, maximumResponseBytes: 64 * 1024)
            try Task.checkCancellation()
            guard response.statusCode == 200,
                  let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
                  token.token_type.lowercased() == "bearer", !token.access_token.isEmpty,
                  token.expires_in > 0, token.expires_in <= 86_400 else {
                throw HubError("Google 授权或令牌刷新失败，请重新登录并检查 OAuth 客户端与项目权限。")
            }
            _ = try Validation.apiKey(token.access_token)
            return token
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw HubError("无法连接 Google 授权服务器。")
        }
    }
}
