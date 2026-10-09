import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse)
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

public struct SecureHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else {
            throw HubError("供应商未返回 HTTP 响应。")
        }
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
            throw HubError("供应商响应过大，已停止读取。")
        }
        var data = Data()
        for try await byte in bytes {
            if data.count >= maximumResponseBytes {
                throw HubError("供应商响应过大，已停止读取。")
            }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response)
    }
}

public struct AIClient: Sendable {
    private let transport: any HTTPTransport
    private let credentials: CredentialResolver
    private let textBackend: (any TextGenerationBackend)?

    public init(transport: any HTTPTransport = SecureHTTPTransport(), vault: (any CredentialVault)? = nil,
                textBackend: (any TextGenerationBackend)? = nil) {
        self.transport = transport
        self.textBackend = textBackend
        credentials = CredentialResolver(transport: transport, vault: vault)
    }

    public func refreshedCredential(_ value: String, for provider: Provider) async throws -> String? {
        try await credentials.refreshedCredential(value, for: provider)
    }

    private func request(
        provider: Provider, key: String?, route: String, query: [URLQueryItem] = [], apiOverride: APIProtocol? = nil
    ) async throws -> URLRequest {
        let credential = try await credentials.resolve(key, for: provider)
        let api = apiOverride ?? provider.effectiveProtocol
        var request = URLRequest(url: try Endpoint(provider.baseURL, defaultVersion: api.defaultVersion).url(for: route, query: query))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if api == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        if !credential.secret.isEmpty {
            if credential.bearer {
                request.setValue("Bearer \(credential.secret)", forHTTPHeaderField: "Authorization")
            } else {
                switch api {
                case .anthropic: request.setValue(credential.secret, forHTTPHeaderField: "x-api-key")
                case .gemini: request.setValue(credential.secret, forHTTPHeaderField: "x-goog-api-key")
                case .xiaomi: request.setValue(credential.secret, forHTTPHeaderField: "api-key")
                default: request.setValue("Bearer \(credential.secret)", forHTTPHeaderField: "Authorization")
                }
            }
        }
        if let project = credential.quotaProject {
            request.setValue(project, forHTTPHeaderField: "x-goog-user-project")
        }
        return request
    }

    private func execute(_ request: URLRequest, purpose: RequestPurpose, limit: Int = 2 * 1024 * 1024) async throws -> Data {
        do {
            let (data, response) = try await transport.send(request, maximumResponseBytes: limit)
            try Task.checkCancellation()
            guard (200...299).contains(response.statusCode) else {
                throw ProviderFailure.http(status: response.statusCode, purpose: purpose, data: data)
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw HubError("\(purpose.title)超时，请稍后重试。", isNetworkFailure: true) }
            throw HubError("\(purpose.title)无法连接服务，请检查网络、代理及渠道地址。", isNetworkFailure: true)
        }
    }

    public func discover(provider: Provider, key: String?) async throws -> [AIModel] {
        if provider.channelType.isSubscription { return try await discoverAccount(provider: provider, key: key) }
        let api = provider.effectiveProtocol
        var cursor: String?
        var cursors = Set<String>()
        var models: [String: AIModel] = [:]
        for _ in 0..<20 {
            try Task.checkCancellation()
            var query: [URLQueryItem] = []
            if api == .gemini {
                query.append(.init(name: "pageSize", value: "1000"))
                if let cursor { query.append(.init(name: "pageToken", value: cursor)) }
            } else if api == .anthropic {
                query.append(.init(name: "limit", value: "1000"))
                if let cursor { query.append(.init(name: "after_id", value: cursor)) }
            }
            var request = try await request(provider: provider, key: key, route: "models", query: query)
            request.timeoutInterval = 20
            let page = try ProtocolAdapter.modelPage(data: await execute(request, purpose: .catalog), protocol: api, provider: provider)
            for model in page.models { models[model.id] = model }
            guard models.count <= 10_000 else { throw HubError("模型目录超过 10000 个条目，已停止读取。") }
            guard let next = page.nextCursor else { return models.values.sorted { $0.id < $1.id } }
            guard cursors.insert(next).inserted else { throw HubError("供应商返回了重复分页标记，模型获取已停止。") }
            cursor = next
        }
        throw HubError("模型目录超过 20 页，未保存不完整结果。")
    }

    public func transcribe(
        provider: Provider, key: String?, model: String,
        audio: Data, filename: String, language: String = "", vocabulary: String = ""
    ) async throws -> String {
        guard !provider.channelType.isSubscription, provider.channelType != .cliProxyAPI else {
            throw HubError("此渠道尚未接入听写接口，请选择语音 API 渠道。")
        }
        let model = try Validation.modelID(model)
        _ = try provider.invocation(modelID: model, task: .transcription)
        let mime = try AudioPolicy.validate(filename: filename, byteCount: audio.count)
        let ext = (filename as NSString).pathExtension.lowercased()
        guard language.isEmpty || (language.count == 2 && language.allSatisfy({ $0.isASCII && $0.isLetter })) else {
            throw HubError("识别语言必须是两位 ISO 639-1 代码，或留空自动识别。")
        }
        guard vocabulary.count <= 2000 else { throw HubError("词汇提示不能超过 2000 字。") }
        if provider.effectiveProtocol == .xiaomi {
            guard ["wav", "mp3"].contains(ext) else {
                throw HubError("小米 ASR 需要 wav 或 mp3；请转换格式后再上传。")
            }
            var request = try await request(provider: provider, key: key, route: "chat/completions")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try ProtocolAdapter.xiaomiSpeechBody(model: model, audio: audio, mime: mime, language: language)
            return try ProtocolAdapter.generationText(data: await execute(request, purpose: .transcription), protocol: .xiaomi)
        }
        guard provider.effectiveProtocol.supportsMultipartSpeech else {
            throw HubError("当前协议未提供语音转写接口，请选择 OpenAI 兼容语音接口或小米 ASR。")
        }
        var form = MultipartForm()
        form.field("model", value: model)
        if !provider.usesSiliconFlowSpeech {
            form.field("response_format", value: "json")
            if !language.isEmpty { form.field("language", value: language) }
            if model.lowercased().hasSuffix("transcribe-diarize") { form.field("chunking_strategy", value: "auto") }
            else if !vocabulary.isEmpty { form.field("prompt", value: vocabulary) }
        }
        form.audio(audio, mime: mime, extension: ext)
        form.finish()
        var request = try await request(provider: provider, key: key, route: "audio/transcriptions")
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.data
        let data = try await execute(request, purpose: .transcription)
        struct Transcript: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Transcript.self, from: data) else {
            throw HubError("语音接口返回格式不兼容（需要 JSON text 字段）。")
        }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw HubError("没有识别到文字，请检查麦克风输入与音频内容后重试。")
        }
        return text
    }

    public func transform(
        provider: Provider, key: String?, model: String, text: String, instruction: String
    ) async throws -> String {
        try await transformDetailed(provider: provider, key: key, model: model, text: text, instruction: instruction).text
    }
    public func transformDetailed(provider: Provider, key: String?, model: String, text: String, instruction: String) async throws -> TextGenerationResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HubError("请先识别或输入文字。")
        }
        guard text.count <= 50_000, instruction.count <= 4_000 else {
            throw HubError("文字或转换指令过长，请分段处理。")
        }
        let model = try Validation.modelID(model)
        let binding = try provider.invocation(modelID: model, task: .textGeneration)
        let options = try PublicReasoningPolicy.options(provider: provider, modelID: model, api: binding.apiProtocol)
        if provider.channelType.isSubscription {
            return try await transformAccount(provider: provider, key: key, model: model, text: text, instruction: instruction)
        }
        let api = binding.apiProtocol
        let route = try ProtocolAdapter.generationRoute(protocol: api, model: model)
        var request = try await request(provider: provider, key: key, route: route, apiOverride: api)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider.textBackend == .swiftAI {
            guard provider.supportsSDKText, let textBackend else { throw HubError("当前渠道未接入 Swift AI SDK 文字后端，请选择内置适配。") }
            return try await textBackend.generateDetailed(api: api, model: model, text: text, instruction: instruction, authorizedRequest: request, options: options)
        }
        request.httpBody = try ReasoningWire.apply(ProtocolAdapter.generationBody(protocol: api, model: model, text: text, instruction: instruction), api: api, options: options)
        let data = try await execute(request, purpose: .textGeneration)
        return .init(text: try ProtocolAdapter.generationText(data: data, protocol: api), usage: TokenUsageParser.parse(data, api: api))
    }

    private func accountRequest(provider: Provider, key: String?, operation: String, model: String? = nil) async throws -> URLRequest {
        let credential = try await credentials.resolve(key, for: provider)
        return try AccountProtocol.request(provider: provider, credential: credential, operation: operation, model: model)
    }

    private func antigravityProject(provider: Provider, key: String?) async throws -> String {
        let resolved = try await credentials.resolve(key, for: provider)
        if let project = resolved.projectID, !project.isEmpty { return project }
        var request = try AccountProtocol.request(provider: provider, credential: resolved, operation: "loadCodeAssist")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": ["ideType": "ANTIGRAVITY"]
        ])
        let project = try AccountProtocol.project(await execute(request, purpose: .accountProject))
        try await credentials.setProject(project, value: key ?? "", for: provider)
        return project
    }

    private func discoverAccount(provider: Provider, key: String?) async throws -> [AIModel] {
        if provider.channelType == .antigravity {
            let credential = try await credentials.resolve(key, for: provider)
            for endpoint in AntigravityEndpoint.allCases {
                var request = try AccountProtocol.request(provider: provider, credential: credential,
                    operation: "fetchAvailableModels", antigravityEndpoint: endpoint)
                request.timeoutInterval = 25
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data("{}".utf8)
                do { return try AccountProtocol.models(await execute(request, purpose: .catalog), channel: .antigravity) }
                catch {
                    guard endpoint == .daily, AntigravityEndpoint.canFallback(error) else { throw error }
                }
            }
            throw HubError("获取模型列表失败。")
        }
        var request = try await accountRequest(provider: provider, key: key, operation: "models")
        request.timeoutInterval = 25
        return try AccountProtocol.models(await execute(request, purpose: .catalog), channel: provider.channelType)
    }

    private func transformAccount(provider: Provider, key: String?, model: String, text: String, instruction: String) async throws -> TextGenerationResult {
        let project = provider.channelType == .antigravity ? try await antigravityProject(provider: provider, key: key) : nil
        let operation = provider.channelType == .codex ? "responses"
            : provider.channelType == .grok ? "chat/completions" : "streamGenerateContent"
        var request = try await accountRequest(provider: provider, key: key, operation: operation, model: model)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try AccountProtocol.generationBody(channel: provider.channelType, model: model, text: text, instruction: instruction, project: project)
        let data = try await execute(request, purpose: .textGeneration, limit: 4 * 1024 * 1024)
        return .init(text: try AccountProtocol.generationText(data, channel: provider.channelType), usage: TokenUsageParser.account(data, channel: provider.channelType))
    }
}
