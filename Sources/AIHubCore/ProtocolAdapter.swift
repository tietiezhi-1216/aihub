import Foundation

public enum ProtocolAdapter {
    public static func modelPage(data: Data, protocol api: APIProtocol, provider: Provider? = nil) throws -> ModelPage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HubError("响应不是有效的模型列表。")
        }
        let entries: [[String: Any]]
        let next: String?
        if api == .gemini {
            guard let models = json["models"] as? [[String: Any]] else {
                throw HubError("Gemini 模型列表缺少 models 字段。")
            }
            entries = models
            next = json["nextPageToken"] as? String
        } else {
            guard let models = json["data"] as? [[String: Any]] else {
                throw HubError("模型列表缺少 data 字段。请检查协议或手动添加模型。")
            }
            entries = models
            if api == .anthropic, json["has_more"] as? Bool == true {
                guard let cursor = json["last_id"] as? String, !cursor.isEmpty else {
                    throw HubError("模型列表分页信息不完整。")
                }
                next = cursor
            } else { next = nil }
        }
        if let next {
            guard next.utf8.count <= 4096, !next.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw HubError("模型列表分页标记无效。")
            }
        }
        let models = try entries.map { entry -> AIModel in
            guard let raw = entry[api == .gemini ? "name" : "id"] as? String else {
                throw HubError("模型列表中缺少模型 ID。")
            }
            let id = try Validation.modelID(api == .gemini && raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw)
            let display = entry[api == .gemini ? "displayName" : "display_name"] as? String
            return ModelCatalog.model(id: id, entry: entry, displayName: display,
                priceCurrency: URLComponents(string: provider?.baseURL ?? "")?.host == "openrouter.ai" ? "USD" : nil, fetchedAt: Date())
        }
        return ModelPage(models: models, nextCursor: next?.isEmpty == true ? nil : next)
    }

    public static func generationRoute(protocol api: APIProtocol, model: String) throws -> String {
        switch api {
        case .automatic, .openAIChat, .xiaomi: "chat/completions"
        case .openAIResponses: "responses"
        case .anthropic: "messages"
        case .gemini: "models/\(try geminiModel(model)):generateContent"
        }
    }

    public static func geminiModel(_ raw: String) throws -> String {
        let id = raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw
        guard !id.isEmpty, id.utf8.count <= 256,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }),
              id != ".", id != ".." else {
            throw HubError("Gemini 模型 ID 格式无效。")
        }
        return id
    }

    public static func generationBody(protocol api: APIProtocol, model: String, text: String, instruction: String) throws -> Data {
        let body: [String: Any]
        switch api {
        case .automatic, .openAIChat, .xiaomi:
            body = ["model": model, "messages": [["role": "system", "content": instruction],
                                                ["role": "user", "content": text]], "stream": false]
        case .openAIResponses:
            body = ["model": model, "instructions": instruction, "input": text, "store": false, "stream": false]
        case .anthropic:
            body = ["model": model, "system": instruction, "max_tokens": 4096,
                    "messages": [["role": "user", "content": text]], "stream": false]
        case .gemini:
            body = ["systemInstruction": ["parts": [["text": instruction]]],
                    "contents": [["role": "user", "parts": [["text": text]]]],
                    "generationConfig": ["maxOutputTokens": 4096]]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    public static func generationText(data: Data, protocol api: APIProtocol) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HubError("模型返回了无效的 JSON。")
        }
        let text: String
        switch api {
        case .automatic, .openAIChat, .xiaomi:
            let choice = (json["choices"] as? [[String: Any]])?.first
            if choice?["finish_reason"] as? String == "length" { throw truncated() }
            let content = (choice?["message"] as? [String: Any])?["content"]
            if let string = content as? String { text = string }
            else {
                text = (content as? [[String: Any]] ?? []).compactMap {
                    $0["text"] as? String ?? $0["transcript"] as? String
                }.joined()
            }
        case .openAIResponses:
            if json["status"] as? String == "incomplete" { throw truncated() }
            text = (json["output"] as? [[String: Any]] ?? []).filter {
                $0["type"] as? String == "message" && $0["role"] as? String == "assistant"
            }.flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter {
                $0["type"] as? String == "output_text"
            }.compactMap { $0["text"] as? String }.joined()
        case .anthropic:
            if json["stop_reason"] as? String == "max_tokens" { throw truncated() }
            text = (json["content"] as? [[String: Any]] ?? []).filter {
                $0["type"] as? String == "text"
            }.compactMap { $0["text"] as? String }.joined()
        case .gemini:
            let candidate = (json["candidates"] as? [[String: Any]])?.first
            if candidate?["finishReason"] as? String == "MAX_TOKENS" { throw truncated() }
            text = ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [])
                .filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw HubError("模型未返回有效文字，请检查模型、权限及请求协议。") }
        return result
    }

    private static func truncated() -> HubError { HubError("模型输出被截断，请缩短输入后重试。") }

    public static func xiaomiSpeechBody(model: String, audio: Data, mime: String, language: String) throws -> Data {
        guard audio.count <= 7 * 1024 * 1024 else {
            throw HubError("小米 ASR 音频过大，请缩短或压缩为 7 MB 以内。")
        }
        guard ["", "zh", "en"].contains(language) else {
            throw HubError("小米 ASR 当前只支持自动识别、中文和英文。")
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": [["type": "input_audio", "input_audio": [
                "data": "data:\(mime);base64,\(audio.base64EncodedString())"
            ]]]]],
            "asr_options": ["language": language.isEmpty ? "auto" : language],
            "stream": false
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }
}
