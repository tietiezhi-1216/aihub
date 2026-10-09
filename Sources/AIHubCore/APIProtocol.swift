import Foundation

public enum APIProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, openAIChat, openAIResponses, anthropic, gemini, xiaomi
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "自动识别"
        case .openAIChat: "OpenAI Chat Completions"
        case .openAIResponses: "OpenAI Responses"
        case .anthropic: "Anthropic Messages"
        case .gemini: "Google Gemini"
        case .xiaomi: "小米 MiMo"
        }
    }

    public static func detect(baseURL: String) -> APIProtocol {
        let host = URLComponents(string: baseURL)?.host?.lowercased() ?? ""
        if host == "api.anthropic.com" { return .anthropic }
        if host == "generativelanguage.googleapis.com" { return .gemini }
        if host == "xiaomimimo.com" || host.hasSuffix(".xiaomimimo.com") { return .xiaomi }
        return .openAIChat
    }

    public var defaultVersion: String { self == .gemini ? "v1beta" : "v1" }
    public var supportsMultipartSpeech: Bool {
        self == .openAIChat || self == .openAIResponses
    }
}

public enum AuthenticationMethod: String, Codable, Sendable {
    case apiKey, bearer, googleOAuth, accountOAuth
    public var title: String {
        switch self {
        case .apiKey: "API Key"
        case .bearer: "Bearer Token"
        case .googleOAuth: "Google OAuth"
        case .accountOAuth: "账号登录"
        }
    }
}

public struct ModelPage: Equatable, Sendable {
    public var models: [AIModel]
    public var nextCursor: String?
    public init(models: [AIModel], nextCursor: String? = nil) {
        self.models = models
        self.nextCursor = nextCursor
    }
}
