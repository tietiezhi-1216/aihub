import Foundation

public struct Endpoint: Sendable {
    public let baseURL: URL

    public init(_ raw: String, defaultVersion: String = "v1") throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw HubError("请输入完整的 API 基础地址，不要包含用户名、查询参数或片段。")
        }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else {
            throw HubError("远程供应商必须使用 HTTPS；HTTP 仅允许 localhost 或本机回环地址。")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        guard !["/models", "/audio/transcriptions", "/chat/completions", "/responses", "/messages"].contains(where: path.hasSuffix) else {
            throw HubError("请填写基础地址（如 https://api.openai.com/v1），而不是完整接口路径。")
        }
        if path.isEmpty { path = "/\(defaultVersion)" }
        components.path = path
        guard let url = components.url else { throw HubError("API 地址无效。") }
        baseURL = url
    }

    public func url(for route: String, query: [URLQueryItem] = []) -> URL {
        let url = route.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = query
        return components.url ?? url
    }
}
