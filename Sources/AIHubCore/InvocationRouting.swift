import Foundation

extension Provider {
    public func offeringIdentity(_ model: ModelOffering) -> OfferingIdentity {
        .init(connectionID: id, remoteModelID: model.id)
    }
    /// Executable tasks are the intersection of model description and shipped adapters.
    /// No arbitrary metadata URLs, auth schemes, account selection, or fallback.
    public func binding(for model: ModelOffering, task: ModelTask) -> InvocationBinding? {
        if task == .textGeneration { guard model.supportsTextOutput else { return nil } }
        else { guard model.tasks.contains(task) else { return nil } }
        if channelType.isSubscription {
            return task == .textGeneration ? .init(task: task, apiProtocol: channelType.apiProtocol,
                evidence: .init(.channelRule, source: channelType.title)) : nil
        }
        guard task == .textGeneration || task == .transcription else { return nil }
        if task == .transcription {
            guard channelType != .cliProxyAPI, effectiveProtocol.supportsMultipartSpeech || effectiveProtocol == .xiaomi else { return nil }
        }
        if !model.metadata.bindings.isEmpty {
            let candidates = model.metadata.bindings.filter { $0.task == task && permits($0.apiProtocol, for: task) }
            return candidates.first { $0.evidence.origin == .user } ?? candidates.first { $0.apiProtocol == effectiveProtocol } ?? candidates.first
        }
        if task == .textGeneration, effectiveProtocol == .gemini,
           !model.generationMethods.isEmpty, !model.generationMethods.contains("generateContent") { return nil }
        return .init(task: task, apiProtocol: effectiveProtocol, evidence: .init(.channelRule, source: "AIHub 接口适配"))
    }
    public func invocation(modelID: String, task: ModelTask) throws -> InvocationBinding {
        // Explicit callers may supply a manual ID before discovering a catalog.
        let model = models.first { $0.id == modelID } ?? ModelOffering(id: modelID,
            capability: task == .transcription ? .transcription : .chat, source: .manual)
        guard model.isAvailable != false, let binding = binding(for: model, task: task) else {
            throw HubError("此模型的当前渠道尚未接入所选任务接口。")
        }
        return binding
    }
    private func permits(_ api: APIProtocol, for task: ModelTask) -> Bool {
        if task == .transcription { return api == effectiveProtocol }
        // Chat/Responses share the same authorized OpenAI-style API-key boundary.
        // Metadata cannot switch an Anthropic/Google key into a different auth scheme.
        if [.openAIChat, .openAIResponses].contains(effectiveProtocol) {
            return [.openAIChat, .openAIResponses].contains(api)
        }
        return api == effectiveProtocol
    }
}

extension ModelOffering {
    public func hasSameExecutionDescription(as other: ModelOffering) -> Bool {
        var a = metadata.reasoning, b = other.metadata.reasoning
        a.evidence = nil; b.evidence = nil
        return a == b && metadata.limits == other.metadata.limits && tasks == other.tasks && generationMethods == other.generationMethods &&
            inputModalities == other.inputModalities && outputModalities == other.outputModalities &&
            metadata.bindings.map { "\($0.task.rawValue):\($0.apiProtocol.rawValue)" } ==
            other.metadata.bindings.map { "\($0.task.rawValue):\($0.apiProtocol.rawValue)" }
    }
}
