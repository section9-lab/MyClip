import Foundation

public enum ClipAgent: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claude
    case opencode
    case cursor

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        case .cursor: "Cursor"
        }
    }
    /// The program that speaks ACP on stdio. Codex and Claude need a connector; OpenCode's own CLI is the server.
    public var executableName: String {
        switch self {
        case .codex: "codex-acp"
        case .claude: "claude-agent-acp"
        case .opencode: "opencode"
        case .cursor: "cursor-agent"
        }
    }
    public var acpArguments: [String] { self == .opencode || self == .cursor ? ["acp"] : [] }
    /// The user-facing command line, used for discovery and login instructions.
    public var cliName: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .opencode: "opencode"
        case .cursor: "cursor-agent"
        }
    }
    /// npm connector to install; nil when the CLI itself speaks ACP.
    public var package: String? {
        switch self {
        case .codex: "@agentclientprotocol/codex-acp@1.12.0"
        case .claude: "@agentclientprotocol/claude-agent-acp@0.78.0"
        case .opencode, .cursor: nil
        }
    }
    /// Session mode that lets the Agent read, write and run tools without asking.
    public var fullAccessModeID: String {
        switch self {
        case .codex: "agent-full-access"
        case .claude: "bypassPermissions"
        case .opencode: "build"
        case .cursor: "agent"
        }
    }
}

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

public struct CaptureContext: Sendable {
    public var id: UUID
    public var appName: String
    public var bundleID: String
    public var windowTitle: String
    public var windowID: UInt32
    public var reason: CaptureReason
    public var date: Date

    public init(id: UUID = UUID(), appName: String, bundleID: String, windowTitle: String, windowID: UInt32, reason: CaptureReason, date: Date = Date()) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.reason = reason
        self.date = date
    }
}

public struct ClipCapture: Identifiable, Sendable {
    public let id: UUID
    public let appName: String
    public let bundleID: String
    public let windowTitle: String
    public let windowID: UInt32
    public let reason: CaptureReason
    public let date: Date
    public let imageID: String
    public let imageURL: URL
    public let width: Int
    public let height: Int
    /// Consecutive captures of one window within `LibraryStore.sceneGap` share a scene; the Timeline folds them.
    public var sceneID: String
    public var textURL: URL { imageURL.deletingPathExtension().appendingPathExtension("txt") }

    public init(id: UUID, appName: String, bundleID: String, windowTitle: String, windowID: UInt32, reason: CaptureReason, date: Date,
                imageID: String, imageURL: URL, width: Int, height: Int, sceneID: String? = nil) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.reason = reason
        self.date = date
        self.imageID = imageID
        self.imageURL = imageURL
        self.width = width
        self.height = height
        self.sceneID = sceneID ?? id.uuidString
    }
}

public enum KnowledgeKind: String, Codable, CaseIterable, Sendable {
    case wiki
    case memory
}

public struct KnowledgeDraft: Codable, Sendable {
    public var entryID: UUID?
    public var expectedRevision: Int?
    public var kind: KnowledgeKind
    public var title: String
    public var body: String
    public var sourceIDs: [UUID]
    public var path: String?

    public init(entryID: UUID? = nil, expectedRevision: Int? = nil, kind: KnowledgeKind, title: String, body: String, sourceIDs: [UUID], path: String? = nil) {
        self.entryID = entryID
        self.expectedRevision = expectedRevision
        self.kind = kind
        self.title = title
        self.body = body
        self.sourceIDs = sourceIDs
        self.path = path
    }
}

public struct KnowledgeEntry: Identifiable, Sendable {
    public let id: UUID
    public let kind: KnowledgeKind
    public let title: String
    public let body: String
    public let revision: Int
    public let updatedAt: Date
    public let agent: ClipAgent
    public let sourceIDs: [UUID]
    public let fileURL: URL
    public let relativePath: String
    public var contextSourceIDs: [UUID] = []
    public var observedAt: Date? = nil
    /// Search terms declared in the file's `aliases:` metadata.
    public var aliases: [String] = []
    public var isRootDocument: Bool { MemoryLayout.rootFiles.contains(relativePath) }
}

public enum ClipJobState: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

/// A batch turns new screenshots into memory; a dream reorganizes the memory that already exists.
public enum ClipJobKind: String, Sendable { case batch, dream }

public struct ClipJob: Identifiable, Sendable {
    public let id: UUID
    public let agent: ClipAgent
    public let state: ClipJobState
    public let createdAt: Date
    public let sourceIDs: [UUID]
    public let error: String?
    /// Runs so far, counting the first one. Zero until the batch is claimed.
    public var attempts = 0
    /// Earliest automatic re-run after a transient failure; nil once claimed or when waiting for the user.
    public var retryAt: Date?
    public var kind: ClipJobKind = .batch
    /// The pages a dream was given, fixed when it was queued.
    public var dreamPlan: ConsolidationPlan?

    public init(id: UUID, agent: ClipAgent, state: ClipJobState, createdAt: Date, sourceIDs: [UUID], error: String?,
                attempts: Int = 0, retryAt: Date? = nil) {
        self.id = id
        self.agent = agent
        self.state = state
        self.createdAt = createdAt
        self.sourceIDs = sourceIDs
        self.error = error
        self.attempts = attempts
        self.retryAt = retryAt
    }

    /// A queued batch that already ran and is waiting for its automatic retry.
    public var isAwaitingRetry: Bool { state == .queued && attempts > 0 }
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
