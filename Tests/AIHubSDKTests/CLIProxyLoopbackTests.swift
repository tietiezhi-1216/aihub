import Foundation
import Testing
import AIHubCore
import AIHubSDK

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AIHUB_CLI_PROXY_TEST_URL"] != nil))
struct CLIProxyLoopbackTests {
    var base: String { ProcessInfo.processInfo.environment["AIHUB_CLI_PROXY_TEST_URL"]! }
    func provider() -> Provider {
        var provider = Provider(name: "Local proxy integration", baseURL: "")
        provider.selectChannel(.cliProxyAPI); provider.baseURL = base
        return provider
    }
    @Test func verifiedHelperAndSwiftSDKUseRealLoopbackHTTP() async throws {
        let transport = SecureHTTPTransport()
        let client = AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport))
        let provider = provider()
        let models = try await client.discover(provider: provider, key: "aihub-local-test-key")
        #expect(models.contains { $0.id == "aihub-mock-text" })
        #expect(models.contains { $0.id == "aihub-mock-image" })
        #expect(models.allSatisfy { $0.verifiedAt == nil })
        #expect(try await client.transform(provider: provider, key: "aihub-local-test-key", model: "aihub-mock-text", text: "模拟原文", instruction: "整理") == "模拟代理完成")
        do {
            _ = try await client.transform(provider: provider, key: "aihub-local-test-key", model: "aihub-mock-429", text: "模拟原文", instruction: "整理")
            Issue.record("Expected quota failure")
        } catch {
            #expect((error as? HubError)?.statusCode == 429)
            #expect(!error.localizedDescription.contains("mock-private-error"))
        }
        await #expect(throws: HubError.self) { try await client.discover(provider: provider, key: "wrong-local-key") }
    }
}
