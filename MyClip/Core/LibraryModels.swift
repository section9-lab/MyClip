import Foundation

public enum ClipAgent: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claude

    public var id: String { rawValue }
    public var name: String { self == .codex ? "Codex" : "Claude" }
    public var executableName: String { self == .codex ? "codex-acp" : "claude-agent-acp" }
    public var package: String {
        self == .codex ? "@agentclientprotocol/codex-acp@1.12.0" : "@agentclientprotocol/claude-agent-acp@0.78.0"
    }
}

public enum LibraryError: Error, LocalizedError, Sendable {
    case invalidImage
    case database(String)
    case invalidResult(String)
    case missingSource
    case conflict

    public var errorDescription: String? {
        switch self {
        case .invalidImage: "无法读取截图。"
        case .database(let message): "资料库错误：\(message)"
        case .invalidResult(let message): "整理结果无效：\(message)"
        case .missingSource: "来源截图已过期或不可用。"
        case .conflict: "这条知识已更新，请重新整理后再保存。"
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

public struct KnowledgeResponse: Codable, Sendable {
    public var entries: [KnowledgeDraft]
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
    public var isRootDocument: Bool { MemoryLayout.rootFiles.contains(relativePath) }
}

public enum ClipJobState: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public struct ClipJob: Identifiable, Sendable {
    public let id: UUID
    public let agent: ClipAgent
    public let state: ClipJobState
    public let createdAt: Date
    public let sourceIDs: [UUID]
    public let error: String?
}

public struct LibrarySnapshot: Sendable {
    public var captures: [ClipCapture] = []
    public var entries: [KnowledgeEntry] = []
    public var memoryFolders: [String] = []
    public var jobs: [ClipJob] = []
    public var queue = OrganizationQueue()
    public var imageCount = 0

    public init() {}
}
