import AVFoundation
import Foundation
import Testing
import AIHubCore
@testable import AIHub

struct SpeechAudioTests {
    @Test func convertsStereo48kToMono16kWAVWithoutChangingOriginal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AIHub-convert-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for channel in 0..<2 {
            for frame in 0..<48_000 {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.2
            }
        }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }
        let original = try Data(contentsOf: url)
        let wav = try SpeechAudio.wavForXiaomi(url)
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav.subdata(in: 8..<12) == Data("WAVE".utf8))
        #expect(wav.subdata(in: 22..<24) == Data([1, 0]))
        #expect(wav.subdata(in: 24..<28) == Data([0x80, 0x3e, 0, 0]))
        #expect(wav.subdata(in: 34..<36) == Data([16, 0]))
        #expect(abs(wav.count - 32_044) < 256)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func rejectsUndecodableAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AIHub-invalid-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("invalid audio".utf8).write(to: url)
        #expect(throws: HubError.self) { try SpeechAudio.wavForXiaomi(url) }
    }
}
