import Foundation

public enum LocalProxyEndpoint {
    /// Literal loopback only: no DNS aliases, LAN hosts, Unix socket proxies,
    /// query credentials or management routes. TLS is allowed for local servers.
    public static func validate(_ raw: String) throws {
        let endpoint = try Endpoint(raw).baseURL
        guard let c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              ["127.0.0.1", "::1", "[::1]"].contains(c.host?.lowercased() ?? ""),
              c.path == "/v1", c.query == nil, c.fragment == nil,
              c.user == nil, c.password == nil else {
            throw HubError("CLIProxyAPI 地址必须是本机回环地址，例如 http://127.0.0.1:8317/v1。")
        }
    }
}
