import Foundation

/// This is an execution choice, not a provider identity or authentication mode.
public enum TextBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case builtIn, swiftAI
    public var id: String { rawValue }
    public var title: String { self == .builtIn ? "内置适配" : "Swift AI SDK" }
}

/// Adapters receive an already-authorized, endpoint-bound request. They must not
/// load environment credentials, retry, choose accounts, or redirect requests.
public protocol TextGenerationBackend: Sendable {
    func generate(api: APIProtocol, model: String, text: String, instruction: String,
                  authorizedRequest: URLRequest) async throws -> String
    func generateDetailed(api: APIProtocol, model: String, text: String, instruction: String,
                          authorizedRequest: URLRequest, options: TextCallOptions) async throws -> TextGenerationResult
}
extension TextGenerationBackend {
    public func generateDetailed(api: APIProtocol, model: String, text: String, instruction: String,
                                 authorizedRequest: URLRequest, options: TextCallOptions) async throws -> TextGenerationResult {
        guard options.reasoning.isDefault, options.maxOutputTokens == 4096, !options.enforceOutputLimit else { throw HubError("此文字后端尚未接入调用选项。") }
        return .init(text: try await generate(api: api, model: model, text: text, instruction: instruction, authorizedRequest: authorizedRequest))
    }
}

extension Provider {
    public var supportsSDKText: Bool {
        !channelType.isSubscription && [.openAIChat, .openAIResponses, .anthropic, .gemini].contains(effectiveProtocol)
    }
}
