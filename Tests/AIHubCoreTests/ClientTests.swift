import Foundation
import Testing
@testable import AIHubCore

actor StubTransport: HTTPTransport {
    let status: Int
    let body: Data
    let delay: Duration?
    var requests: [URLRequest] = []
    init(status: Int = 200, body: String, delay: Duration? = nil) {
        self.status = status
        self.body = Data(body.utf8)
        self.delay = delay
    }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let delay { try await Task.sleep(for: delay) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

struct ClientTests {
    func provider(_ kind: ProviderKind = .openAI) -> Provider {
        Provider(name: "Test", kind: kind, baseURL: kind == .compatible ? "http://localhost:8080/v1" : kind.defaultURL)
    }

    @Test func discoveryDeduplicatesAndAuthenticates() async throws {
        let transport = StubTransport(body: #"{"data":[{"id":"whisper-1"},{"id":"gpt-4o"},{"id":"whisper-1"}]}"#)
        let models = try await AIClient(transport: transport).discover(provider: provider(), key: "fake-key")
        #expect(models.map(\.id) == ["gpt-4o", "whisper-1"])
        #expect(models.last?.capability == .transcription)
        #expect(models.allSatisfy { $0.verifiedAt == nil })
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-key")
    }

    @Test func missingKeyFailsBeforeNetwork() async {
        let transport = StubTransport(body: #"{"data":[]}"#)
        await #expect(throws: HubError.self) {
            try await AIClient(transport: transport).discover(provider: provider(), key: nil)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func keylessCompatibleService() async throws {
        let transport = StubTransport(body: #"{"data":[]}"#)
        var local = provider(.compatible)
        local.requiresAPIKey = false
        #expect(try await AIClient(transport: transport).discover(provider: local, key: nil).isEmpty)
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test(arguments: ["{}", "[]", "not json", #"{"data":[{"name":"model"}]}"#])
    func malformedDiscoveryDoesNotLookSuccessful(_ body: String) async {
        let transport = StubTransport(body: body)
        await #expect(throws: HubError.self) {
            try await AIClient(transport: transport).discover(provider: provider(), key: "fake")
        }
    }

    @Test func transcriptionRequestAndResponse() async throws {
        let transport = StubTransport(body: #"{"text":"  你好，世界。\n "}"#)
        let result = try await AIClient(transport: transport).transcribe(
            provider: provider(.groq), key: "fake", model: "whisper-large-v3-turbo",
            audio: Data("audio bytes".utf8), filename: "private-original-name.wav",
            language: "zh", vocabulary: "AIHub"
        )
        #expect(result == "你好，世界。")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"language\"\r\n\r\nzh"))
        #expect(body.contains("name=\"prompt\"\r\n\r\nAIHub"))
        #expect(body.contains("filename=\"audio.wav\""))
        #expect(!body.contains("private-original-name"))
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.contains("boundary=") == true)
    }

    @Test func siliconFlowOnlyReceivesDocumentedFields() async throws {
        let transport = StubTransport(body: #"{"text":"测试"}"#)
        _ = try await AIClient(transport: transport).transcribe(
            provider: provider(.siliconFlow), key: "fake", model: "FunAudioLLM/SenseVoiceSmall",
            audio: Data([1, 2, 3]), filename: "voice.m4a", language: "zh", vocabulary: "AIHub"
        )
        let body = String(decoding: try #require(await transport.requests.first?.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"model\""))
        #expect(body.contains("name=\"file\""))
        #expect(!body.contains("name=\"prompt\""))
        #expect(!body.contains("name=\"language\""))
        #expect(!body.contains("name=\"response_format\""))
    }

    @Test(arguments: [#"{"text":""}"#, #"{"text":"  "}"#, #"{"result":"wrong"}"#, "plain transcript"])
    func badTranscriptionResponse(_ body: String) async {
        await #expect(throws: HubError.self) {
            try await AIClient(transport: StubTransport(body: body)).transcribe(
                provider: provider(), key: "fake", model: "whisper-1",
                audio: Data([1]), filename: "audio.m4a"
            )
        }
    }

    @Test(arguments: [301, 401, 403, 404, 413, 429, 500])
    func errorsNeverEchoServerSecrets(_ status: Int) async {
        let transport = StubTransport(status: status, body: #"{"error":"fake-secret private transcript"}"#)
        do {
            _ = try await AIClient(transport: transport).discover(provider: provider(), key: "fake")
            Issue.record("Expected HTTP error")
        } catch {
            #expect(!error.localizedDescription.contains("fake-secret"))
            #expect(!error.localizedDescription.contains("private transcript"))
        }
    }

    @Test func cancellationPropagates() async throws {
        let transport = StubTransport(body: #"{"data":[]}"#, delay: .seconds(5))
        let client = AIClient(transport: transport)
        let task = Task { try await client.discover(provider: provider(), key: "fake") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func transformationUsesChatProtocol() async throws {
        let transport = StubTransport(body: #"{"choices":[{"message":{"content":"整理后的文字"}}]}"#)
        let result = try await AIClient(transport: transport).transform(
            provider: provider(), key: "fake", model: "gpt-4o-mini", text: "原文字", instruction: "整理"
        )
        #expect(result == "整理后的文字")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/v1/chat/completions")
        let json = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        let messages = json?["messages"] as? [[String: String]]
        #expect(messages?.first?["role"] == "system")
        #expect(messages?.last?["content"] == "原文字")
        #expect(json?["temperature"] == nil)
    }

    @Test func emptyInputDoesNotSend() async {
        let transport = StubTransport(body: "{}")
        await #expect(throws: HubError.self) {
            try await AIClient(transport: transport).transform(
                provider: provider(), key: "fake", model: "gpt-4o", text: " ", instruction: "整理"
            )
        }
        #expect(await transport.requests.isEmpty)
    }
}
