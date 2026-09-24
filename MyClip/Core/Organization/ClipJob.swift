import Foundation

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
