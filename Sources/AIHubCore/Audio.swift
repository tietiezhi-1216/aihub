import Foundation

public enum AudioPolicy {
    public static let maximumBytes = 24 * 1024 * 1024
    public static let maximumRecordingSeconds: TimeInterval = 600
    public static let mimeTypes: [String: String] = [
        "m4a": "audio/mp4", "mp4": "audio/mp4", "mp3": "audio/mpeg",
        "mpeg": "audio/mpeg", "mpga": "audio/mpeg", "wav": "audio/wav",
        "flac": "audio/flac", "ogg": "audio/ogg", "webm": "audio/webm"
    ]

    public static func validate(filename: String, byteCount: Int) throws -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard let mime = mimeTypes[ext] else {
            throw HubError("不支持此音频格式。请使用 m4a、mp3、wav、flac、ogg 或 webm。")
        }
        guard byteCount > 0 else { throw HubError("音频文件为空，请重新录音或导入。") }
        guard byteCount <= maximumBytes else {
            throw HubError("音频超过 24 MB。请先分段或压缩后再导入。")
        }
        return mime
    }
}

public struct MultipartForm: Sendable {
    public let boundary: String
    public private(set) var data = Data()
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public init(boundary: String = "AIHub-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public mutating func field(_ name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    public mutating func audio(_ bytes: Data, mime: String, extension ext: String) {
        append("--\(boundary)\r\n")
        // Do not transmit the user's original filename or allow header injection.
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        data.append(bytes)
        append("\r\n")
    }

    public mutating func finish() { append("--\(boundary)--\r\n") }
    private mutating func append(_ string: String) { data.append(Data(string.utf8)) }
}
