import Foundation

public enum RequestPurpose: String, Sendable {
    case catalog, accountProject, transcription, textGeneration
    public var title: String {
        switch self {
        case .catalog: "获取模型列表"
        case .accountProject: "读取账户项目"
        case .transcription: "语音识别"
        case .textGeneration: "文字生成"
        }
    }
}

public enum ProviderFailure {
    public static func http(status: Int, purpose: RequestPurpose, data: Data) -> HubError {
        let detail: String
        switch status {
        case 300...399: detail = "服务要求重定向，为保护凭据已拒绝，请检查渠道地址。"
        case 401: detail = "认证失败，请检查凭据或重新登录。"
        case 403: detail = "访问被拒绝，请在官方服务检查账户资格、验证状态和权限。"
        case 404: detail = purpose == .catalog ? "模型目录接口不存在，请检查渠道协议；也可手动添加模型。" : "接口或模型不存在，请检查渠道协议和模型 ID。"
        case 413: detail = purpose == .transcription ? "音频超过服务限制，请缩短或压缩音频。" : "请求超过服务大小限制。"
        case 429: detail = "请求受限或额度不足，请稍后重试并检查账户额度。"
        case 400, 422:
            switch purpose {
            case .catalog: detail = "服务不接受模型目录请求参数，请检查渠道适配。"
            case .accountProject: detail = "服务不接受账户初始化参数，请检查登录渠道适配。"
            case .transcription: detail = "服务不接受音频或转写参数，请检查识别模型和文件格式。"
            case .textGeneration: detail = "服务不接受文字生成参数，请检查模型和协议。"
            }
        case 500...599: detail = "服务暂不可用，请稍后重试。"
        default: detail = "服务返回错误。"
        }
        // Never display upstream free-form messages, URLs, or error descriptions.
        // Only map known RPC reasons/field names into fixed, non-sensitive hints.
        let hint = safeHint(data)
        return HubError("\(purpose.title)失败（HTTP \(status)）：\(hint ?? detail)", statusCode: status)
    }
    private static func safeHint(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        let details = error["details"] as? [[String: Any]] ?? []
        if details.contains(where: { $0["reason"] as? String == "VALIDATION_REQUIRED" }) {
            return "账号需要验证，请在官方应用完成验证后重试。"
        }
        if (error["message"] as? String)?.contains("User location is not supported") == true {
            return "服务不支持当前地区，请检查官方服务的地区限制。"
        }
        let allowed = Set(["metadata", "metadata.ideType", "metadata.platform", "metadata.pluginType", "project", "model"])
        let fields = details.flatMap { $0["fieldViolations"] as? [[String: Any]] ?? [] }.compactMap { $0["field"] as? String }.filter { allowed.contains($0) }
        guard !fields.isEmpty else { return nil }
        return "服务拒绝参数字段：\(Set(fields).sorted().joined(separator: "、"))。"
    }
}

public enum AntigravityEndpoint: String, CaseIterable, Sendable {
    case daily, production
    public var baseURL: String {
        self == .daily ? "https://daily-cloudcode-pa.googleapis.com/v1internal" : ChannelType.antigravity.defaultURL
    }
    public static func canFallback(_ error: any Error) -> Bool {
        guard let error = error as? HubError else { return false }
        // Never change regions/endpoints to bypass account, location or quota restrictions.
        return error.isNetworkFailure || error.statusCode == 404 || error.statusCode.map { (500...599).contains($0) } == true
    }
}
