import Foundation

public struct AccountOAuthCredential: Codable, Equatable, Sendable {
    public var channel: ChannelType
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var accountID: String?
    public var email: String?
    public var projectID: String?

    public init(channel: ChannelType, accessToken: String, refreshToken: String, expiresAt: Date,
                accountID: String? = nil, email: String? = nil, projectID: String? = nil) {
        self.channel = channel; self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.accountID = accountID; self.email = email; self.projectID = projectID
    }
    public func validate() throws {
        guard channel.isSubscription, !accessToken.isEmpty, !refreshToken.isEmpty,
              expiresAt.timeIntervalSince1970.isFinite else { throw HubError("登录凭据不完整，请重新登录。") }
        for value in [accessToken, refreshToken] {
            guard value.utf8.count <= 16 * 1024,
                  value.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }) else {
                throw HubError("登录令牌格式无效，请重新登录。")
            }
        }
        for value in [accountID ?? "", email ?? "", projectID ?? ""] {
            guard value == (try Validation.apiKey(value)) else { throw HubError("登录账户信息格式无效。") }
        }
        if channel == .codex, accountID?.isEmpty != false {
            throw HubError("Codex 凭据缺少 ChatGPT 账户标识，请重新登录。")
        }
    }
}

/// Public installed-client identifiers from the respective OAuth implementations.
/// No credentials are read from other apps, and all token endpoints are fixed.
public struct AccountOAuthDefinition: Sendable {
    public let channel: ChannelType
    public var clientID: String {
        switch channel {
        case .codex: "app_EMoamEEZ73f0CkXaXp7hrann"
        case .grok: "b1a00492-073a-47ea-816f-4c329264a828"
        case .antigravity: "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
        default: ""
        }
    }
    public var clientSecret: String? {
        channel == .antigravity ? "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" : nil
    }
    public var port: UInt16 { channel == .codex ? 1455 : channel == .grok ? 56121 : 51121 }
    public var callbackHost: String { channel == .grok ? "127.0.0.1" : "localhost" }
    public var callbackPath: String { channel == .codex ? "/auth/callback" : channel == .grok ? "/callback" : "/oauth-callback" }
    public var redirectURI: String { "http://\(callbackHost):\(port)\(callbackPath)" }
    public var tokenURL: URL {
        URL(string: channel == .codex ? "https://auth.openai.com/oauth/token"
            : channel == .grok ? "https://auth.x.ai/oauth2/token" : "https://oauth2.googleapis.com/token")!
    }
    public init(channel: ChannelType) throws {
        guard channel.isSubscription else { throw HubError("此渠道不使用订阅账号登录。") }
        self.channel = channel
    }
    public func authorizationURL(state: String, verifier: String, nonce: String) -> URL {
        var components = URLComponents(string: channel == .codex ? "https://auth.openai.com/oauth/authorize"
            : channel == .grok ? "https://auth.x.ai/oauth2/authorize" : "https://accounts.google.com/o/oauth2/v2/auth")!
        let scope = channel == .codex ? "openid profile email offline_access"
            : channel == .grok ? "openid profile email offline_access grok-cli:access api:access"
            : "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/cclog https://www.googleapis.com/auth/experimentsandconfigs"
        components.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scope),
            .init(name: "state", value: state), .init(name: "nonce", value: nonce),
            .init(name: "code_challenge", value: OAuthPKCE.challenge(verifier)), .init(name: "code_challenge_method", value: "S256")
        ]
        if channel == .codex {
            components.queryItems! += [.init(name: "codex_cli_simplified_flow", value: "true"),
                                      .init(name: "id_token_add_organizations", value: "true"), .init(name: "originator", value: "aihub")]
        } else if channel == .grok {
            components.queryItems! += [.init(name: "plan", value: "generic"), .init(name: "referrer", value: "aihub")]
        } else {
            components.queryItems! += [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")]
        }
        return components.url!
    }
}

public enum OAuthJWT {
    // Decoded claims are only routing/display hints from a TLS-authenticated token
    // exchange or explicitly imported file; the model backend validates the token.
    public static func claims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.utf8.count <= 16 * 1024 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return claims
    }
    public static func accountID(_ token: String) -> String? {
        (claims(token)["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
    }
}

public struct AccountOAuthClient: Sendable {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = SecureHTTPTransport()) { self.transport = transport }

    public func exchange(code: String, definition: AccountOAuthDefinition, verifier: String, nonce: String) async throws -> AccountOAuthCredential {
        var fields = ["grant_type": "authorization_code", "client_id": definition.clientID,
                      "code": code, "redirect_uri": definition.redirectURI, "code_verifier": verifier]
        if let secret = definition.clientSecret { fields["client_secret"] = secret }
        let response = try await token(fields, definition: definition)
        if let idToken = response.id_token {
            let claims = OAuthJWT.claims(idToken)
            // xAI is an OIDC flow; Codex's custom flow may omit nonce in its
            // ID token. In all cases the authorization code is state/PKCE-bound.
            if definition.channel == .grok || claims["nonce"] != nil {
                guard claims["nonce"] as? String == nonce else { throw HubError("登录身份校验失败，请重新登录。") }
            }
        }
        return try credential(response, channel: definition.channel, previous: nil)
    }
    public func refresh(_ current: AccountOAuthCredential) async throws -> AccountOAuthCredential {
        try current.validate()
        let definition = try AccountOAuthDefinition(channel: current.channel)
        var fields = ["grant_type": "refresh_token", "client_id": definition.clientID, "refresh_token": current.refreshToken]
        if let secret = definition.clientSecret { fields["client_secret"] = secret }
        return try credential(await token(fields, definition: definition), channel: current.channel, previous: current)
    }
    private struct Token: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: TimeInterval?
        let token_type: String?
        let id_token: String?
    }
    private func credential(_ token: Token, channel: ChannelType, previous: AccountOAuthCredential?) throws -> AccountOAuthCredential {
        let expires = token.expires_in ?? 3600
        guard !token.access_token.isEmpty, expires.isFinite, expires > 0, expires <= 86_400,
              token.token_type?.lowercased() ?? "bearer" == "bearer" else { throw HubError("授权返回了无效的令牌，请重新登录。") }
        let claims = OAuthJWT.claims(token.id_token ?? token.access_token)
        let result = AccountOAuthCredential(
            channel: channel, accessToken: token.access_token,
            refreshToken: token.refresh_token ?? previous?.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(expires),
            accountID: OAuthJWT.accountID(token.access_token) ?? previous?.accountID,
            email: claims["email"] as? String ?? previous?.email, projectID: previous?.projectID
        )
        try result.validate()
        return result
    }
    private func token(_ fields: [String: String], definition: AccountOAuthDefinition) async throws -> Token {
        var request = URLRequest(url: definition.tokenURL)
        request.httpMethod = "POST"; request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
        do {
            let (data, response) = try await transport.send(request, maximumResponseBytes: 64 * 1024)
            try Task.checkCancellation()
            guard response.statusCode == 200, let token = try? JSONDecoder().decode(Token.self, from: data) else {
                throw HubError("\(definition.channel.title) 授权或刷新失败（\(response.statusCode)），请重新登录。")
            }
            return token
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw HubError("无法连接 \(definition.channel.title) 授权服务器。")
        }
    }
}
