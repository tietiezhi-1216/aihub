import Foundation

/// Channel identity is independent from the wire protocol. Subscription credentials
/// must never be treated as API keys or sent to user-editable endpoints.
public enum ChannelType: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, antigravity, grok
    case openAIChat, openAIResponses, anthropic, gemini, xiaomi, custom, googleOAuth, cliProxyAPI
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .grok: "Grok"
        case .openAIChat: "OpenAI Chat Completions"
        case .openAIResponses: "OpenAI Responses"
        case .anthropic: "Anthropic Messages"
        case .gemini: "Google Gemini API"
        case .xiaomi: "小米 MiMo"
        case .custom: "自定义 API"
        case .cliProxyAPI: "CLIProxyAPI（本机）"
        case .googleOAuth: "Google Gemini OAuth（自有客户端）"
        }
    }
    public static var loginChannels: [Self] { [.codex, .antigravity, .grok, .googleOAuth] }
    public static var apiChannels: [Self] { [.openAIChat, .openAIResponses, .anthropic, .gemini, .xiaomi, .custom, .cliProxyAPI] }
    public var isSubscription: Bool { self == .codex || self == .antigravity || self == .grok }
    public var usesLogin: Bool { isSubscription || self == .googleOAuth }
    public var defaultURL: String {
        switch self {
        case .codex: "https://chatgpt.com/backend-api/codex"
        case .antigravity: "https://cloudcode-pa.googleapis.com/v1internal"
        case .grok: "https://cli-chat-proxy.grok.com/v1"
        case .openAIChat, .openAIResponses: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini, .googleOAuth: "https://generativelanguage.googleapis.com/v1beta"
        case .xiaomi: "https://api.xiaomimimo.com/v1"
        case .custom: ""
        case .cliProxyAPI: "http://127.0.0.1:8317/v1"
        }
    }
    public var apiProtocol: APIProtocol {
        switch self {
        case .codex, .openAIResponses: .openAIResponses
        case .antigravity, .gemini, .googleOAuth: .gemini
        case .grok, .openAIChat, .cliProxyAPI: .openAIChat
        case .anthropic: .anthropic
        case .xiaomi: .xiaomi
        case .custom: .automatic
        }
    }
    public var authentication: AuthenticationMethod {
        isSubscription ? .accountOAuth : self == .googleOAuth ? .googleOAuth : .apiKey
    }
    public static func infer(protocol api: APIProtocol, authentication: AuthenticationMethod) -> Self {
        if authentication == .googleOAuth { return .googleOAuth }
        switch api {
        case .automatic: return .custom
        case .openAIChat: return .openAIChat
        case .openAIResponses: return .openAIResponses
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        case .xiaomi: return .xiaomi
        }
    }
}

extension Provider {
    public mutating func selectChannel(_ channel: ChannelType) {
        let old = channelType
        if name.isEmpty || name == old.title { name = channel.title }
        channelType = channel
        kind = .compatible
        baseURL = channel.defaultURL
        apiProtocol = channel.apiProtocol
        authentication = channel.authentication
        requiresAPIKey = true
        models = []
        thinkingSelections = [:]
        withdrawnThinkingModelIDs = []
        textBackend = [.openAIChat, .openAIResponses, .anthropic, .gemini, .cliProxyAPI].contains(channel) ? .swiftAI : .builtIn
        discoveredAt = nil
    }

    public func validateChannel() throws {
        if channelType.isSubscription {
            guard try normalizedBaseURL == channelType.defaultURL,
                  authentication == .accountOAuth, requiresAPIKey,
                  apiProtocol == channelType.apiProtocol else {
                throw HubError("账号登录渠道的地址、协议和鉴权方式不可修改，请重新选择渠道。")
            }
        } else if channelType == .cliProxyAPI {
            try LocalProxyEndpoint.validate(baseURL)
            guard authentication == .apiKey, requiresAPIKey, apiProtocol == .openAIChat else {
                throw HubError("本机 CLIProxyAPI 只能使用本地访问密钥，不接受订阅令牌或其他 OAuth 凭据。")
            }
        } else if authentication == .accountOAuth {
            throw HubError("订阅凭据仅能用于对应的账号登录渠道。")
        }
    }
}
