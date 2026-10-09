import Foundation

public enum OAuthCallbackError: LocalizedError, Equatable, Sendable {
    case invalid, denied
    public var errorDescription: String? {
        self == .denied ? "授权已拒绝或取消。" : "OAuth 回调校验失败。"
    }
}

public enum OAuthCallback {
    public static func code(httpRequest: Data, redirectURI: String, expectedState: String) throws -> String {
        guard httpRequest.count <= 8192, !expectedState.isEmpty,
              let request = String(data: httpRequest, encoding: .utf8),
              let redirect = URLComponents(string: redirectURI), let port = redirect.port,
              let host = redirect.host, ["127.0.0.1", "localhost"].contains(host), redirect.scheme == "http" else { throw OAuthCallbackError.invalid }
        let lines = request.components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").split(separator: " ")
        guard requestLine.count == 3, requestLine[0] == "GET",
              requestLine[2] == "HTTP/1.1", requestLine[1].hasPrefix("/") else { throw OAuthCallbackError.invalid }
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "\(host):\(port)",
              let target = URLComponents(string: "http://\(host):\(port)\(requestLine[1])"),
              target.host == redirect.host, target.port == port, target.path == redirect.path,
              target.fragment == nil else { throw OAuthCallbackError.invalid }
        let query = target.queryItems ?? []
        let states = query.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == expectedState else { throw OAuthCallbackError.invalid }
        if query.contains(where: { $0.name == "error" }) { throw OAuthCallbackError.denied }
        let codes = query.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty, code.utf8.count <= 4096,
              !code.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw OAuthCallbackError.invalid }
        return code
    }
}
