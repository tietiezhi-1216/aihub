import AVFoundation
import Foundation
import Observation
import AIHubCore

@MainActor @Observable
final class Recorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var isRequestingPermission = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0
    private(set) var fileURL: URL?
    var error: String?
    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIHub-recordings")

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    func start() async throws {
        guard !isRecording, !isRequestingPermission else { return }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard granted else { throw HubError("麦克风未授权。请在系统设置 → 隐私与安全性 → 麦克风中允许 AIHub。") }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw HubError("未找到麦克风，请连接输入设备并检查系统声音设置。")
        }
        discard()
        error = nil
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("\(UUID().uuidString).m4a")
        let audio = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ])
        audio.delegate = self
        audio.isMeteringEnabled = true
        guard audio.prepareToRecord(), audio.record() else {
            try? FileManager.default.removeItem(at: url)
            throw HubError("录音启动失败，请检查输入设备是否被其他应用占用。")
        }
        recorder = audio
        fileURL = url
        elapsed = 0
        isRecording = true
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.isRecording, let recorder = self.recorder else { break }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                self.level = max(0, min(1, Double((recorder.averagePower(forChannel: 0) + 55) / 55)))
                if self.elapsed >= AudioPolicy.maximumRecordingSeconds {
                    self.stop()
                    self.error = "已到 10 分钟上限，录音已停止并保留。点击「转文字」继续。"
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        elapsed = recorder?.currentTime ?? elapsed
        isRecording = false
        recorder?.stop()
        meterTask?.cancel()
        meterTask = nil
        level = 0
    }

    func discard() {
        stop()
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        elapsed = 0
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.fileURL == url, self.isRecording else { return }
            self.stop()
            self.error = flag ? "录音已结束，音频已保留。" : "录音意外结束，请检查音频或重新录制。"
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.fileURL == url else { return }
            self.stop()
            self.error = "录音编码失败，请重新录制。"
        }
    }

    static func cleanStaleRecordings() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIHub-recordings")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        // Only remove this app's expired recordings, never imported source files.
        for file in files where file.pathExtension == "m4a" {
            if let date = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
               date < Date().addingTimeInterval(-86_400) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
