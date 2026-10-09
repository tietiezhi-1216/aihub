import Foundation
import Testing
@testable import AIHubCore

struct EndpointAudioTests {
    @Test(arguments: [
        ("https://api.openai.com", "https://api.openai.com/v1/models"),
        ("https://api.openai.com/v1/", "https://api.openai.com/v1/models"),
        ("https://api.groq.com/openai/v1", "https://api.groq.com/openai/v1/models"),
        ("https://example.com/proxy/v2/", "https://example.com/proxy/v2/models"),
        ("http://127.0.0.1:8080/v1", "http://127.0.0.1:8080/v1/models"),
        ("http://localhost:8080", "http://localhost:8080/v1/models")
    ])
    func routesPreserveVersionAndProxyPaths(_ raw: String, _ expected: String) throws {
        #expect(try Endpoint(raw).url(for: "models").absoluteString == expected)
        #expect(try !Endpoint(raw).url(for: "audio/transcriptions").absoluteString.contains("v1/v1"))
    }

    @Test(arguments: [
        "http://example.com/v1", "http://localhost.evil.com", "ftp://example.com",
        "https://user:pass@example.com", "https://example.com?key=secret", "https://example.com#frag",
        "api.openai.com", "https://", "https://example.com/v1/models",
        "https://example.com/v1/audio/transcriptions", "https://exa mple.com/v1", "http://0.0.0.0:8000"
    ])
    func rejectsUnsafeOrAmbiguousURL(_ url: String) { #expect(throws: HubError.self) { try Endpoint(url) } }

    @Test func ipv6Loopback() throws {
        #expect(try Endpoint("http://[::1]:8000/v1").url(for: "models").host != nil)
    }

    @Test func audioBounds() throws {
        #expect(try AudioPolicy.validate(filename: "voice.M4A", byteCount: 100) == "audio/mp4")
        #expect(throws: HubError.self) { try AudioPolicy.validate(filename: "voice.txt", byteCount: 100) }
        #expect(throws: HubError.self) { try AudioPolicy.validate(filename: "voice.wav", byteCount: 0) }
        #expect(throws: HubError.self) { try AudioPolicy.validate(filename: "voice.wav", byteCount: AudioPolicy.maximumBytes + 1) }
        #expect(try AudioPolicy.validate(filename: "voice.mp3", byteCount: AudioPolicy.maximumBytes) == "audio/mpeg")
    }

    @Test func multipartContainsExactAudioBytesAndFinalBoundary() throws {
        var form = MultipartForm(boundary: "test-boundary")
        let audio = Data([0, 255, 1, 13, 10, 42])
        form.field("model", value: "whisper-1")
        form.audio(audio, mime: "audio/wav", extension: "wav")
        form.finish()
        let expectedPrefix = Data(("--test-boundary\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n" +
            "--test-boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n" +
            "Content-Type: audio/wav\r\n\r\n").utf8)
        #expect(form.data.starts(with: expectedPrefix))
        #expect(form.data.range(of: audio) != nil)
        #expect(form.data.suffix(Data("\r\n--test-boundary--\r\n".utf8).count) == Data("\r\n--test-boundary--\r\n".utf8))
        #expect(form.contentType == "multipart/form-data; boundary=test-boundary")
    }
}
