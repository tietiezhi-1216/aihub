import AVFoundation
import Foundation
import AIHubCore

private final class ConversionReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var failure = false
    var failed: Bool { lock.withLock { failure } }
    func markFailed() { lock.withLock { failure = true } }
}

enum SpeechAudio {
    static func wavForXiaomi(_ url: URL) throws -> Data {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw HubError("无法解码此音频，请使用 wav、mp3 或 m4a 文件。") }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
            throw HubError("无法将录音转换为小米 ASR 所需的 WAV 格式。")
        }
        var pcm = Data()
        let readState = ConversionReadState()
        var finished = false
        while !finished {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                guard file.framePosition < file.length else { inputStatus.pointee = .endOfStream; return nil }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: requested) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: buffer)
                    inputStatus.pointee = .haveData
                    return buffer
                } catch {
                    readState.markFailed()
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            guard conversionError == nil, !readState.failed, status != .error else {
                throw HubError("音频格式转换失败，请重新录音或使用 WAV 文件。")
            }
            if let samples = output.floatChannelData?[0] {
                for index in 0..<Int(output.frameLength) {
                    let sample = samples[index].isFinite ? samples[index] : 0
                    let value = Int16(max(-1, min(1, sample)) * 32767)
                    var little = value.littleEndian
                    withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
                }
            }
            guard pcm.count <= 7 * 1024 * 1024 - 44 else {
                throw HubError("小米 ASR 转换后的音频超过 7 MB，请缩短录音后重试。")
            }
            finished = status == .endOfStream
            if output.frameLength == 0, status != .endOfStream {
                throw HubError("音频转换未产生有效数据。")
            }
        }
        guard !pcm.isEmpty else { throw HubError("音频为空。") }
        var wav = Data("RIFF".utf8)
        append(UInt32(pcm.count + 36), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt32(16_000), to: &wav)
        append(UInt32(32_000), to: &wav)
        append(UInt16(2), to: &wav)
        append(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        append(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
