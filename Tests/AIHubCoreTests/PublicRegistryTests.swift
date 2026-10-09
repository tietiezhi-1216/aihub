import Foundation
import Testing
@testable import AIHubCore

private actor RegistryTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let body: String
    let status: Int
    let delay: Bool
    init(_ body: String, status: Int = 200, delay: Bool = false) { self.body = body; self.status = status; self.delay = delay }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if delay { try await Task.sleep(for: .seconds(30)) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
struct PublicRegistryTests {
    static let fixture = #"{"openai":{"api":"https://malicious.example","env":["PRIVATE_KEY"],"models":{"gpt-test":{"name":"GPT Test","reasoning":true,"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["low","high"]},{"type":"budget_tokens","min":32,"max":1024}],"modalities":{"input":["text","image"],"output":["text"]},"limit":{"context":65536},"cost":{"input":2,"output":8},"provider":{"body":{"model":"different-route","Authorization":"PRIVATE"}}}}}}"#
    @Test func registryReadsCapabilitiesButNotNetworkOrCredentialInstructions() throws {
        let registry = try PublicModelRegistry.parse(Data(Self.fixture.utf8))
        let record = try #require(registry.records.first)
        #expect(record.metadata.reasoning.efforts == ["low", "high"])
        #expect(record.metadata.reasoning.modes == ["enabled", "disabled"] && record.metadata.reasoning.minimumBudget == 32)
        #expect(record.metadata.bindings.isEmpty && record.metadata.evidence["tasks"]?.origin == .publicCatalog)
        let text = String(decoding: try JSONEncoder().encode(registry), as: UTF8.self)
        #expect(!text.contains("PRIVATE") && !text.contains("malicious.example") && !text.contains("different-route"))
    }
    @Test func metadataFetchUsesOnePublicGETWithoutAnyUserDataOrCredentials() async throws {
        let transport = RegistryTransport(Self.fixture)
        let registry = try await PublicRegistryClient(transport: transport).fetch()
        #expect(registry.records.count == 1)
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://models.dev/api.json" && request.httpMethod == "GET")
        #expect(request.httpBody == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
    }
    @Test(arguments: [301, 401, 429, 500]) func failuresAreSanitizedAndNotRetried(_ status: Int) async {
        let transport = RegistryTransport("PRIVATE_SECRET", status: status)
        do {
            _ = try await PublicRegistryClient(transport: transport).fetch()
            Issue.record("Expected failure")
        } catch { #expect(!error.localizedDescription.contains("PRIVATE_SECRET")) }
        #expect(await transport.requests.count == 1)
    }
    @Test func cancellationDoesNotCommitOrRetry() async throws {
        let transport = RegistryTransport(Self.fixture, delay: true)
        let task = Task { try await PublicRegistryClient(transport: transport).fetch() }
        for _ in 0..<1000 { if await !transport.requests.isEmpty { break }; await Task.yield() }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {} catch { Issue.record("Expected CancellationError") }
        #expect(await transport.requests.count == 1)
    }
    @Test func cacheRoundtripIsAtomicBoundedAndDoesNotContainRequestData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PublicRegistryCache(fileURL: directory.appendingPathComponent("metadata.json"))
        let registry = try PublicModelRegistry.parse(Data(Self.fixture.utf8))
        try cache.save(registry)
        #expect(try cache.load() == registry)
        let permissions = try FileManager.default.attributesOfItem(atPath: cache.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(!(try String(contentsOf: cache.fileURL, encoding: .utf8)).contains("PRIVATE"))
        let blocked = PublicRegistryCache(fileURL: cache.fileURL.appendingPathComponent("child.json"))
        #expect(throws: (any Error).self) { try blocked.save(registry) }
        #expect(try cache.load() == registry)
    }
    @Test func malformedEmptyAndOversizedPayloadsCannotReplaceCatalog() {
        for body in ["not json", "{}", #"{"openai":{"models":{}}}"#] {
            #expect(throws: HubError.self) { try PublicModelRegistry.parse(Data(body.utf8)) }
        }
        #expect(throws: HubError.self) { try PublicModelRegistry.parse(Data(count: 24 * 1024 * 1024 + 1)) }
    }
    @Test func refreshUpdatesReferenceFieldsWithoutOverwritingServiceFields() throws {
        var registry = try PublicModelRegistry.parse(Data(Self.fixture.utf8))
        let provider = Provider(name: "OpenAI", baseURL: "https://api.openai.com/v1")
        var model = ModelCatalog.model(id: "gpt-test", entry: ["input_modalities": ["text"], "context_length": 100])
        model = registry.enrich([model], for: provider)[0]
        registry.records[0].metadata.reasoning.efforts = ["medium"]
        registry.records[0].metadata.limits.context = 9999
        registry.records[0].input = [.video]
        let updated = registry.enrich([model], for: provider)[0]
        #expect(updated.metadata.reasoning.efforts == ["medium"])
        #expect(updated.metadata.limits.context == 100 && updated.inputModalities == [.text])
    }
}
