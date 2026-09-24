import Foundation

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
