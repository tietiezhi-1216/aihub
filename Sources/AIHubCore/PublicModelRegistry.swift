import Foundation
import Darwin

public struct PublicModelRecord: Codable, Equatable, Sendable {
    public var identity: ModelIdentity
    public var name: String
    public var input: [ModelModality]
    public var output: [ModelModality]
    public var metadata: ModelMetadata
    public var price: PriceSchedule?
}
public struct PublicModelRegistry: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var sourceLicense = Self.license
    public static let license = """
    MIT License

    Copyright (c) 2025 models.dev

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
    public var records: [PublicModelRecord]
    public init(fetchedAt: Date, records: [PublicModelRecord]) { self.fetchedAt = fetchedAt; self.records = records }
    public static func parse(_ data: Data, at date: Date = Date()) throws -> Self {
        guard data.count <= 24 * 1024 * 1024,
              let providers = try? JSONSerialization.jsonObject(with: data) as? [String: Any], providers.count <= 1000 else {
            throw HubError("公共模型目录格式无效或过大，旧缓存未修改。")
        }
        let evidence = MetadataEvidence(.publicCatalog, source: "https://models.dev/api.json", at: date)
        var records: [PublicModelRecord] = []
        for namespace in providers.keys.sorted() {
            guard ModelCatalog.safeControl(namespace), let provider = providers[namespace] as? [String: Any],
                  let models = provider["models"] as? [String: [String: Any]] else { continue }
            for id in models.keys.sorted() {
                guard let entry = models[id], let validID = try? Validation.modelID(id), validID == id,
                      let name = ModelCatalog.safeText(entry["name"] as? String, maximum: 256) else { continue }
                let modalities = entry["modalities"] as? [String: Any] ?? [:]
                let input = ModelCatalog.modalities(modalities["input"]), output = ModelCatalog.modalities(modalities["output"])
                var metadata = ModelMetadata()
                let explicitType = entry["type"] as? String
                let classified = ["transcription": ModelCapability.transcription, "asr": .transcription, "tts": .speechSynthesis, "speech": .speechSynthesis, "embedding": .embedding, "image": .image, "video": .video][explicitType ?? ""] ?? ModelClassifier.classify(id)
                if output.contains(.text), ![.transcription, .embedding, .rerank, .speechSynthesis].contains(classified) {
                    metadata.tasks = [.textGeneration]
                } else { metadata.tasks = ModelTask.inferred(from: classified) }
                if output.contains(.image) { metadata.tasks.append(.imageGeneration) }
                if output.contains(.video) { metadata.tasks.append(.videoGeneration) }
                if output == [.audio] && !metadata.tasks.contains(.speechSynthesis) { metadata.tasks.append(.audioGeneration) }
                metadata.tasks = Array(Set(metadata.tasks)).sorted { $0.rawValue < $1.rawValue }
                metadata.evidence["tasks"] = evidence
                let limit = entry["limit"] as? [String: Any] ?? [:]
                metadata.limits = .init(context: ModelCatalog.positiveInt(limit["context"]), input: ModelCatalog.positiveInt(limit["input"]), output: ModelCatalog.positiveInt(limit["output"]))
                var reasoning = ModelCatalog.reasoning(entry: entry, evidence: evidence)
                for option in (entry["reasoning_options"] as? [[String: Any]] ?? []).prefix(16) {
                    switch option["type"] as? String {
                    case "toggle": reasoning.modes = ["enabled", "disabled"]
                    case "effort": reasoning.efforts = ModelCatalog.controlValues(option["values"])
                    case "budget_tokens":
                        reasoning.supportsBudget = true
                        reasoning.minimumBudget = ModelCatalog.nonnegativeInt(option["min"])
                        reasoning.allowsAutomaticBudget = option["min"] as? Int == -1 ? true : nil
                        reasoning.maximumBudget = ModelCatalog.nonnegativeInt(option["max"])
                    default: break
                    }
                }
                if reasoning.support == .unsupported { reasoning = ReasoningSpec(); reasoning.support = .unsupported }
                reasoning.evidence = reasoning.support == .unknown ? nil : evidence
                metadata.reasoning = reasoning
                records.append(.init(identity: .init(namespace: namespace, modelID: validID), name: name,
                    input: input, output: output, metadata: metadata, price: PriceCatalog.publicCatalog(entry["cost"], at: date)))
                guard records.count <= 50_000 else { throw HubError("公共模型目录超过条目上限，旧缓存未修改。") }
            }
        }
        guard !records.isEmpty else { throw HubError("公共模型目录没有可用元数据，旧缓存未修改。") }
        return .init(fetchedAt: date, records: records)
    }
    /// Exact official-service namespace+ID only. Never apply Google API facts to Antigravity,
    /// or infer gateway model identity merely from an OpenAI-compatible protocol/name.
    public func enrich(_ incoming: [ModelOffering], for provider: Provider) -> [ModelOffering] {
        guard let namespace = Self.namespace(for: provider) else { return incoming }
        let lookup = Dictionary(uniqueKeysWithValues: records.filter { $0.identity.namespace == namespace }.map { ($0.identity.modelID, $0) })
        return incoming.map { original in
            guard let record = lookup[original.id] else { return original }
            var model = original
            let evidence = MetadataEvidence(.publicCatalog, source: "https://models.dev/api.json", at: fetchedAt)
            let developer = ["openai": "OpenAI", "anthropic": "Anthropic", "google": "Google", "deepseek": "DeepSeek", "xai": "xAI", "mistral": "Mistral"][namespace].map { ModelDeveloper(id: namespace, name: $0) }
            model.definition = .init(identity: record.identity, developer: developer, name: record.name, evidence: evidence)
            if model.inputModalities.isEmpty || model.metadata.evidence["inputModalities"]?.origin == .publicCatalog { model.inputModalities = record.input; model.metadata.evidence["inputModalities"] = evidence }
            if model.outputModalities.isEmpty || model.metadata.evidence["outputModalities"]?.origin == .publicCatalog { model.outputModalities = record.output; model.metadata.evidence["outputModalities"] = evidence }
            if !model.userClassified, model.metadata.evidence["tasks"]?.origin != .service {
                model.metadata.tasks = record.metadata.tasks; model.metadata.evidence["tasks"] = evidence
                if model.capability == .unknown, model.metadata.tasks.contains(.textGeneration) { model.capability = .chat }
            }
            if model.metadata.reasoning.support == .unknown || model.metadata.reasoning.evidence?.origin == .publicCatalog { model.metadata.reasoning = record.metadata.reasoning }
            if model.metadata.limits.context == nil || model.metadata.evidence["limits.context"]?.origin == .publicCatalog {
                model.metadata.limits.context = record.metadata.limits.context; model.metadata.evidence["limits.context"] = evidence
            }
            if model.metadata.limits.input == nil || model.metadata.evidence["limits.input"]?.origin == .publicCatalog {
                model.metadata.limits.input = record.metadata.limits.input; model.metadata.evidence["limits.input"] = evidence
            }
            if model.metadata.limits.output == nil || model.metadata.evidence["limits.output"]?.origin == .publicCatalog {
                model.metadata.limits.output = record.metadata.limits.output; model.metadata.evidence["limits.output"] = evidence
            }
            if model.price == nil || model.price?.evidence.origin == .publicCatalog { model.price = record.price }
            return model
        }
    }
    public static func namespace(for provider: Provider) -> String? {
        guard !provider.channelType.isSubscription, provider.channelType != .cliProxyAPI else { return nil }
        switch URLComponents(string: provider.baseURL)?.host?.lowercased() {
        case "api.openai.com": return "openai"
        case "api.anthropic.com": return "anthropic"
        case "generativelanguage.googleapis.com": return "google"
        case "api.groq.com": return "groq"
        case "api.siliconflow.cn", "api.siliconflow.com": return "siliconflow"
        case "api.deepseek.com": return "deepseek"
        case "api.x.ai": return "xai"
        case "api.mistral.ai": return "mistral"
        default: return nil
        }
    }
}

public struct PublicRegistryClient: Sendable {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = SecureHTTPTransport()) { self.transport = transport }
    public func fetch() async throws -> PublicModelRegistry {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://models.dev/api.json")!)
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Intentionally no vault, Authorization, model IDs, audio or user text.
        do {
            let (data, response) = try await transport.send(request, maximumResponseBytes: 24 * 1024 * 1024)
            try Task.checkCancellation()
            guard response.statusCode == 200 else { throw HubError("公共目录更新失败（HTTP \(response.statusCode)），旧缓存未修改。") }
            return try PublicModelRegistry.parse(data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as HubError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw HubError("无法更新公共目录，请检查网络；旧缓存未修改。")
        }
    }
}
public struct PublicRegistryCache: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public static func applicationDefault() throws -> Self {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return .init(fileURL: directory.appendingPathComponent("AIHub/model-metadata.json"))
    }
    public func load() throws -> PublicModelRegistry? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 24 * 1024 * 1024 else { throw HubError("公共目录缓存过大。") }
        let value = try JSONDecoder().decode(PublicModelRegistry.self, from: Data(contentsOf: fileURL))
        guard value.records.count <= 50_000, Set(value.records.map(\.identity)).count == value.records.count else { throw HubError("公共目录缓存包含重复条目。") }
        for record in value.records {
            guard ModelCatalog.safeControl(record.identity.namespace), ModelCatalog.safeText(record.name, maximum: 256) != nil else { throw HubError("公共目录缓存身份无效。") }
            var model = ModelOffering(id: record.identity.modelID)
            model.metadata = record.metadata; model.price = record.price
            model.inputModalities = record.input; model.outputModalities = record.output
            try model.validateMetadata()
        }
        return value
    }
    public func save(_ registry: PublicModelRegistry) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(registry)
        guard data.count <= 24 * 1024 * 1024 else { throw HubError("公共目录缓存过大。") }
        let temporary = directory.appendingPathComponent(".metadata-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, fileURL.path) == 0 else { throw HubError("公共目录缓存保存失败。") }
    }
}
