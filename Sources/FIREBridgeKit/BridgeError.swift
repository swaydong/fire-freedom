import Foundation

public enum FIREBridgeError: LocalizedError, Equatable {
    case codexNotFound(searchedPaths: [String])
    case codexAuthenticationRequired(details: String)
    case processLaunchFailed(String)
    case processExited(status: Int32, details: String)
    case appServerDisconnected(String)
    case appServerProtocolError(String)
    case appServerRejected(code: Int?, message: String)
    case invalidStructuredOutput(String)
    case threadNotFound(reportID: UUID)
    case pairingRejected(String)
    case keychainFailure(status: Int32)
    case invalidMessage(String)

    public var errorDescription: String? {
        switch self {
        case let .codexNotFound(paths):
            return "未找到 Codex。已检查：\(paths.joined(separator: "、"))"
        case let .codexAuthenticationRequired(details):
            return "Codex 必须使用 ChatGPT 账号登录。\(details)"
        case let .processLaunchFailed(details):
            return "无法启动 Codex App Server：\(details)"
        case let .processExited(status, details):
            return "Codex App Server 已退出（\(status)）：\(details)"
        case let .appServerDisconnected(details):
            return "Codex App Server 连接已中断：\(details)"
        case let .appServerProtocolError(details):
            return "Codex App Server 返回了无法识别的数据：\(details)"
        case let .appServerRejected(code, message):
            if let code {
                return "Codex 请求失败（\(code)）：\(message)"
            }
            return "Codex 请求失败：\(message)"
        case let .invalidStructuredOutput(details):
            return "Codex 输出不符合约定格式：\(details)"
        case let .threadNotFound(reportID):
            return "没有找到报告 \(reportID.uuidString) 对应的 Codex 会话。"
        case let .pairingRejected(details):
            return "设备配对失败：\(details)"
        case let .keychainFailure(status):
            return "无法访问配对凭据（Keychain 状态码 \(status)）。"
        case let .invalidMessage(details):
            return "收到无效的桥接消息：\(details)"
        }
    }
}
