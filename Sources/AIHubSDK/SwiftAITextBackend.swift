import Foundation
import AIHubCore
import AISDKProvider
import AISDKProviderUtils
import OpenAIProvider
import AnthropicProvider
import GoogleProvider

/// Only provider protocol modules are linked. No agent runtime, tools, telemetry,
/// global SDK credential lookup, retry policy or automatic provider fallback.
private actor SDKUsageCapture {
    var value = TokenUsage()
    func set(_ usage: TokenUsage) { value = usage }
}

public struct SwiftAITextBackend: TextGenerationBackend {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = SecureHTTPTransport()) { self.transport = transport }

    public func generate(api: APIProtocol, model: String, text: String, instruction: String,
                         authorizedRequest: URLRequest) async throws -> String {
        try await generateDetailed(api: api, model: model, text: text, instruction: instruction, authorizedRequest: authorizedRequest, options: .init()).text
    }
    public func generateDetailed(api: APIProtocol, model: String, text: String, instruction: String,
                                 authorizedRequest: URLRequest, options callOptions: TextCallOptions) async throws -> TextGenerationResult {
        try Task.checkCancellation()
        let usage = SDKUsageCapture()
        guard let expected = authorizedRequest.url, authorizedRequest.httpMethod == "POST" else {
            throw HubError("文字后端收到无效的授权请求。")
        }
        let route = try ProtocolAdapter.generationRoute(protocol: api, model: model)
        let suffix = "/" + route
        guard expected.path.hasSuffix(suffix) else { throw HubError("文字后端请求地址不匹配。") }
        var base = URLComponents(url: expected, resolvingAgainstBaseURL: false)!
        base.path = String(base.path.dropLast(suffix.count)); base.query = nil
        guard let baseURL = base.url?.absoluteString else { throw HubError("文字后端地址无效。") }
        let fetch: FetchFunction = { request in
            // SDKs are serializers/parsers here, never authorities for transport
            // destinations or auth. Reject unexpected URLs before attaching secrets.
            guard request.url == expected, request.httpMethod == "POST", request.httpBody != nil else {
                throw HubError("Swift AI SDK 请求越过已授权的接口边界，已停止。")
            }
            try Task.checkCancellation()
            // URLRequest's header setter may merge rather than clear headers.
            // Start from our authorized request and copy only the serialized body.
            var bound = authorizedRequest
            bound.httpBody = try ReasoningWire.apply(request.httpBody!, api: api, options: callOptions)
            bound.timeoutInterval = 120
            do {
                let (data, response) = try await transport.send(bound, maximumResponseBytes: 4 * 1024 * 1024)
                try Task.checkCancellation()
                guard data.count <= 4 * 1024 * 1024 else { throw HubError("文字生成响应过大，已停止读取。") }
                guard (200...299).contains(response.statusCode) else {
                    throw ProviderFailure.http(status: response.statusCode, purpose: .textGeneration, data: data)
                }
                await usage.set(TokenUsageParser.parse(data, api: api))
                return FetchResponse(body: .data(data), urlResponse: response)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw HubError(error.code == .timedOut ? "文字生成超时，请稍后重试。" : "文字生成无法连接服务，请检查网络、代理及渠道地址。", isNetworkFailure: true)
            }
        }
        // Explicit placeholder avoids SDK environment-variable lookup. The
        // placeholder is never sent; the bound fetch replaces all HTTP headers.
        let sentinel = "aihub-transport-injected"
        do {
            let languageModel: any LanguageModelV3
            switch api {
            case .openAIChat, .openAIResponses:
                let provider = try createOpenAIProvider(settings: .init(baseURL: baseURL, apiKey: sentinel, fetch: fetch))
                languageModel = api == .openAIResponses ? provider.responses(model) : provider.chat(model)
            case .anthropic:
                languageModel = try createAnthropicProvider(settings: .init(baseURL: baseURL, apiKey: sentinel, fetch: fetch)).languageModel(modelId: model)
            case .gemini:
                let id = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
                languageModel = try createGoogleGenerativeAI(settings: .init(baseURL: baseURL, apiKey: sentinel, fetch: fetch)).languageModel(modelId: id)
            default: throw HubError("此协议尚未接入 Swift AI SDK，请选择内置适配。")
            }
            let options = LanguageModelV3CallOptions(
                prompt: [.system(content: instruction, providerOptions: nil),
                         .user(content: [.text(.init(text: text))], providerOptions: nil)],
                maxOutputTokens: callOptions.maxOutputTokens,
                providerOptions: api == .openAIResponses ? ["openai": ["store": .bool(false)]] : nil
            )
            // Direct provider method: exactly one attempt, no retry wrapper and
            // no tool execution. Only complete, user-visible text is returned.
            let result = try await languageModel.doGenerate(options: options)
            try Task.checkCancellation()
            guard result.finishReason.unified == .stop else {
                throw HubError("模型输出未正常完成，未保存不完整结果。")
            }
            let output = result.content.compactMap { content -> String? in
                if case .text(let value) = content { return value.text }
                return nil
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw HubError("模型没有返回有效文字。") }
            return .init(text: output, usage: await usage.value)
        } catch is CancellationError { throw CancellationError() }
        catch let error as HubError { throw error }
        catch {
            // SDK errors can include request bodies, credentials or upstream
            // free-form error messages. Never surface/log those descriptions.
            throw HubError("Swift AI SDK 无法解析文字响应，请检查模型与协议，或选择内置适配。")
        }
    }
}
