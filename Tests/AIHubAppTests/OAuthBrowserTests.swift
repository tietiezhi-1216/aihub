import Foundation
import Testing
@testable import AIHub

@MainActor
struct OAuthBrowserTests {
    @Test(arguments: ["127.0.0.1", "localhost"])
    func realLoopbackCallbackCompletesWithoutOpeningBrowser(_ host: String) async throws {
        var requestTask: Task<Void, Never>?
        let receiver = try LoopbackOAuthReceiver(host: host, timeoutSeconds: 3, openURL: { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = query.first { $0.name == "redirect_uri" }!.value!
            let state = query.first { $0.name == "state" }!.value!
            var callback = URLComponents(string: redirect)!
            callback.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "mock-code")]
            let target = callback.url!
            requestTask = Task {
                do {
                    let (_, response) = try await URLSession.shared.data(from: target)
                    #expect((response as? HTTPURLResponse)?.statusCode == 200)
                } catch { Issue.record("Local callback failed: \(error.localizedDescription)") }
            }
            return true
        })
        let code = try await receiver.authorize { redirect in
            var url = URLComponents(string: "https://example.invalid/authorize")!
            url.queryItems = [.init(name: "redirect_uri", value: redirect), .init(name: "state", value: receiver.state)]
            return url.url!
        }
        #expect(code == "mock-code")
        await requestTask?.value
    }
    @Test func cancellationClosesPendingListener() async throws {
        let receiver = try LoopbackOAuthReceiver(timeoutSeconds: 3, openURL: { _ in true })
        let task = Task { try await receiver.authorize { _ in URL(string: "https://example.invalid")! } }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func stalledLoginTimesOut() async throws {
        let receiver = try LoopbackOAuthReceiver(timeoutSeconds: 0.05, openURL: { _ in true })
        do {
            _ = try await receiver.authorize { _ in URL(string: "https://example.invalid")! }
            Issue.record("Expected timeout")
        } catch { #expect(error.localizedDescription.contains("超时")) }
    }
}
