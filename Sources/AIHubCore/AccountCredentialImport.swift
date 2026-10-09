import Foundation

public enum AccountCredentialImport {
    public static func parse(_ json: [String: Any], channel selected: ChannelType?) throws -> ImportedCredential? {
        let channel: ChannelType
        let fields: [String: Any]
        if let tokens = json["tokens"] as? [String: Any] {
            channel = .codex; fields = tokens
        } else if selected == .antigravity, json["type"] as? String == "authorized_user" {
            let definition = try AccountOAuthDefinition(channel: .antigravity)
            guard json["client_id"] as? String == definition.clientID else {
                throw HubError("此 Google 凭据不是 Antigravity 登录凭据，请直接登录。")
            }
            channel = .antigravity; fields = json
        } else if let grok = json["xai"] as? [String: Any] {
            channel = .grok; fields = grok
        } else if let grok = json["https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"] as? [String: Any] {
            channel = .grok; fields = grok
        } else if let name = json["channel"] as? String, let parsed = ChannelType(rawValue: name), parsed.isSubscription {
            channel = parsed; fields = json
        } else { return nil }
        if let selected, selected != channel { throw HubError("鉴权文件与所选渠道不同，请先选择 \(channel.title)。") }
        let access = fields["access_token"] as? String ?? fields["access"] as? String ?? ""
        let refresh = fields["refresh_token"] as? String ?? fields["refresh"] as? String ?? ""
        // Missing access is acceptable only for a Google ADC file with a refresh token.
        let accountID = fields["account_id"] as? String ?? fields["accountId"] as? String ?? OAuthJWT.accountID(access)
        let epoch = fields["expires_at"] as? Double ?? fields["expires"] as? Double ?? OAuthJWT.claims(access)["exp"] as? Double ?? 0
        let expires = Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
        let credential = AccountOAuthCredential(
            channel: channel, accessToken: access.isEmpty && channel == .antigravity ? "refresh-required" : access,
            refreshToken: refresh, expiresAt: expires, accountID: accountID,
            email: fields["email"] as? String, projectID: fields["project_id"] as? String ?? fields["projectId"] as? String
        )
        try credential.validate()
        let envelope = CredentialEnvelope(baseURL: channel.defaultURL, authentication: .accountOAuth, account: credential)
        return ImportedCredential(value: try envelope.encoded(), authentication: .accountOAuth,
                                  baseURL: channel.defaultURL, apiProtocol: channel.apiProtocol, channelType: channel)
    }
}
