import Foundation

public enum LibraryError: Error, LocalizedError, Sendable {
    case invalidImage
    case database(String)
    case invalidResult(String)
    /// An agent run left files the vault cannot keep; they went back to their last good revision and the batch runs again.
    case rolledBack(String)
    case missingSource
    case textRecognitionFailed
    case conflict
    /// The agent ended its turn without finishing the batch (for example on a cancelled or truncated run).
    case agentStopped

    public var errorDescription: String? {
        switch self {
        case .invalidImage: String(localized: "无法读取截图。")
        case .database(let message): String(localized: "资料库错误：\(message)")
        case .invalidResult(let message): String(localized: "整理结果无效：\(message)")
        case .rolledBack(let files): String(localized: "已恢复上一版：\(files)。其余改动已保存，将先拆分过长页面再重新整理本批。")
        case .missingSource: String(localized: "来源截图已过期或不可用。")
        case .textRecognitionFailed: String(localized: "OCR 文字提取失败，请重试。")
        case .conflict: String(localized: "这条知识已更新，请重新整理后再保存。")
        case .agentStopped: String(localized: "Agent 在完成前停止，请重试。")
        }
    }
}

public struct LibrarySnapshot: Sendable {
    public var captures: [ClipCapture] = []
    public var captureCount = 0
    public var captureAppNames: [String] = []
    public var entries: [KnowledgeEntry] = []
    public var memoryFolders: [String] = []
    public var jobs: [ClipJob] = []
    public var queue = OrganizationQueue()
    public var imageCount = 0
    /// Memory files on disk that failed validation and keep their last good index, as "path（reason）".
    public var invalidMemoryFiles: [String] = []

    public init() {}
}
