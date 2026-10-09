import Foundation

public enum AccountProtocol {
    // Compatible catalog/client protocol revisions, not an assertion of app identity.
    public static let codexCatalogVersion = "0.121.0"
    public static let grokProtocolVersion = "1.0.46"

    public static func request(provider: Provider, credential: ResolvedCredential, operation: String, model: String? = nil, antigravityEndpoint: AntigravityEndpoint = .production) throws -> URLRequest {
        try provider.validateChannel()
        guard provider.channelType.isSubscription else { throw HubError("不是账号登录渠道。") }
        var components = URLComponents(string: provider.channelType == .antigravity ? antigravityEndpoint.baseURL : provider.channelType.defaultURL)!
        if provider.channelType == .antigravity {
            components.path += ":\(operation)"
            if operation == "streamGenerateContent" { components.queryItems = [.init(name: "alt", value: "sse")] }
        } else {
            components.path += "/\(operation)"
            if provider.channelType == .codex, operation == "models" {
                components.queryItems = [.init(name: "client_version", value: codexCatalogVersion)]
            }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(credential.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIHub/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        switch provider.channelType {
        case .codex:
            guard let accountID = credential.accountID, !accountID.isEmpty else { throw HubError("请重新登录 Codex。") }
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("aihub", forHTTPHeaderField: "originator")
            request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        case .grok:
            request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
            request.setValue("aihub", forHTTPHeaderField: "x-grok-client-identifier")
            request.setValue(grokProtocolVersion, forHTTPHeaderField: "x-grok-client-version")
            request.setValue("interactive", forHTTPHeaderField: "x-grok-client-mode")
            request.setValue("authenticate-response", forHTTPHeaderField: "x-authenticateresponse")
            if let model { request.setValue(model, forHTTPHeaderField: "x-grok-model-override") }
        case .antigravity:
            // Catalog operations need only bearer authentication; do not inject
            // legacy enum metadata into headers or the catalog payload.
            request.setValue("AIHub/0.1 antigravity-protocol", forHTTPHeaderField: "User-Agent")
        default: break
        }
        return request
    }

    public static func models(_ data: Data, channel: ChannelType) throws -> [AIModel] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HubError("登录渠道返回了无效的模型列表。")
        }
        let entries: [(String?, [String: Any])]
        if channel == .antigravity, let catalog = json["models"] as? [String: [String: Any]] {
            entries = catalog.map { ($0.key, $0.value) }
        } else if let catalog = json[channel == .grok ? "data" : "models"] as? [[String: Any]] {
            entries = catalog.map { (nil, $0) }
        } else { throw HubError("登录渠道的模型目录格式已变更，请稍后重试。") }
        guard entries.count <= 10_000 else { throw HubError("模型目录过大，已停止读取。") }
        var models: [String: AIModel] = [:]
        for (key, entry) in entries {
            guard let raw = key ?? entry["slug"] as? String ?? entry["id"] as? String ?? entry["name"] as? String else {
                throw HubError("模型目录缺少模型标识。")
            }
            let id = try Validation.modelID(raw)
            let name = entry["display_name"] as? String ?? entry["displayName"] as? String ?? entry["name"] as? String
            models[id] = ModelCatalog.model(id: id, entry: entry, displayName: name)
        }
        return models.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    public static func project(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let project = json["cloudaicompanionProject"] as? String
                ?? (json["cloudaicompanionProject"] as? [String: Any])?["id"] as? String,
              !project.isEmpty else {
            throw HubError("Antigravity 尚未分配账户项目，请先在官方应用完成账号启用后重试。")
        }
        return try Validation.apiKey(project)
    }

    public static func generationBody(channel: ChannelType, model: String, text: String, instruction: String, project: String?) throws -> Data {
        let body: [String: Any]
        switch channel {
        case .codex:
            body = ["model": model, "instructions": instruction.isEmpty ? "You are a helpful assistant." : instruction,
                    "input": [["role": "user", "content": [["type": "input_text", "text": text]]]], "store": false, "stream": true]
        case .grok:
            body = ["model": model, "messages": [["role": "system", "content": instruction], ["role": "user", "content": text]], "stream": true]
        case .antigravity:
            guard let project, !project.isEmpty else { throw HubError("Antigravity 账户项目不可用，请重新登录。") }
            body = ["project": project, "model": model, "requestType": "agent", "userAgent": "aihub",
                    "requestId": "agent-\(UUID().uuidString)",
                    "request": ["contents": [["role": "user", "parts": [["text": text]]]],
                                "systemInstruction": ["role": "user", "parts": [["text": instruction]]],
                                "generationConfig": ["maxOutputTokens": 4096]]]
        default: throw HubError("此渠道不使用订阅调用协议。")
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    public static func generationText(_ data: Data, channel: ChannelType) throws -> String {
        // Some proxies honor streaming=false internally and return one JSON result.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let object = channel == .antigravity ? json["response"] as? [String: Any] ?? json : json
            return try ProtocolAdapter.generationText(data: JSONSerialization.data(withJSONObject: object), protocol: channel.apiProtocol)
        }
        let frames = try SSE.frames(data)
        var text = ""
        var completed = false
        for frame in frames {
            if frame == "[DONE]" { if channel != .codex { completed = true }; continue }
            guard let json = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any] else {
                throw HubError("模型流式响应格式无效。")
            }
            if json["error"] != nil || ["error", "response.failed", "response.incomplete"].contains(json["type"] as? String ?? "") {
                throw HubError("模型响应失败或不完整，请重试。")
            }
            switch channel {
            case .codex:
                if json["type"] as? String == "response.output_text.delta" { text += json["delta"] as? String ?? "" }
                if json["type"] as? String == "response.completed" {
                    if let response = json["response"] as? [String: Any] {
                        if ["failed", "incomplete", "cancelled"].contains(response["status"] as? String ?? "") { throw incomplete() }
                        if let final = try? ProtocolAdapter.generationText(data: JSONSerialization.data(withJSONObject: response), protocol: .openAIResponses) { text = final }
                    }
                    completed = true
                }
            case .grok:
                let choice = (json["choices"] as? [[String: Any]])?.first
                text += (choice?["delta"] as? [String: Any])?["content"] as? String ?? ""
                if let finish = choice?["finish_reason"] as? String {
                    guard finish == "stop" else { throw incomplete() }
                    completed = true
                }
            case .antigravity:
                let response = json["response"] as? [String: Any] ?? json
                let candidate = (response["candidates"] as? [[String: Any]])?.first
                let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                text += parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
                if let finish = candidate?["finishReason"] as? String {
                    guard finish == "STOP" else { throw incomplete() }
                    completed = true
                }
            default: throw HubError("渠道不支持此流式响应。")
            }
        }
        guard completed else { throw incomplete() }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw HubError("模型没有返回文字。") }
        return result
    }
    private static func incomplete() -> HubError { HubError("模型响应中断或被截断，未保存不完整结果，请重试。") }
}

public enum SSE {
    public static func frames(_ data: Data) throws -> [String] {
        guard let content = String(data: data, encoding: .utf8) else { throw HubError("流式响应编码无效。") }
        var result: [String] = [], lines: [String] = []
        for line in content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty {
                if !lines.isEmpty { result.append(lines.joined(separator: "\n")); lines = [] }
            } else if line.hasPrefix("data:") {
                let value = String(line.dropFirst(5))
                lines.append(value.hasPrefix(" ") ? String(value.dropFirst()) : value)
            }
        }
        if !lines.isEmpty { result.append(lines.joined(separator: "\n")) }
        return result
    }
}
