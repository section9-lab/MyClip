import Foundation
import AppKit

enum AgentBridgeState: String, Codable, Equatable {
    case initializing
    case waiting
    case running
    case draining
    case done
}

enum AgentBridgeEventKind: String, Codable, Equatable {
    case bridgeReady
    case turnStarted
    case contextCaptured
    case routed
    case processStarted
    case processFinished
    case turnCompleted
    case turnFailed
    case turnAborted
    case turnDetached
    case userMessage
    case replay
    case error
}

struct AgentBridgeEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let seq: Int
    let turnID: UUID?
    let kind: AgentBridgeEventKind
    let createdAt: Date
    let message: String
    let payload: [String: String]

    init(
        seq: Int,
        turnID: UUID?,
        kind: AgentBridgeEventKind,
        message: String,
        payload: [String: String] = [:]
    ) {
        self.id = UUID()
        self.seq = seq
        self.turnID = turnID
        self.kind = kind
        self.createdAt = Date()
        self.message = message
        self.payload = payload
    }
}

struct AgentBridgeContext: Codable, Equatable {
    let frontmostApplicationName: String?
    let frontmostBundleIdentifier: String?
    let projectPath: String?
    let screenshotPath: String?
    let capturedAt: Date

    @MainActor
    static func capture(projectPath: String?, screenshotURL: URL?) -> AgentBridgeContext {
        let app = NSWorkspace.shared.frontmostApplication
        return AgentBridgeContext(
            frontmostApplicationName: app?.localizedName,
            frontmostBundleIdentifier: app?.bundleIdentifier,
            projectPath: projectPath,
            screenshotPath: screenshotURL?.path,
            capturedAt: Date()
        )
    }
}

struct AgentBridgeStartConfig: Codable, Equatable {
    let turnID: UUID
    let text: String
    let screenshotPath: String?
    let selectedTool: AIToolType?
    let enabledTools: [AIToolType]
    let selectedSession: AgentSession
    let forcedTarget: AgentTarget?
    let context: AgentBridgeContext
}

struct AgentBridgeRoute: Equatable {
    let target: AgentTarget
    let reason: String
}

struct AgentBridgeControlResult: Equatable {
    let message: String
    let route: AgentBridgeRoute?
}

struct AgentBridgeRouteError: Error, Equatable {
    let message: String
}

struct AgentBridgeRunResult: Equatable {
    let turnID: UUID
    let request: AgentDeliveryRequest?
    let exitCode: Int32
    let output: String
    let route: AgentBridgeRoute?
}

struct AgentBridgeMeta: Codable, Equatable {
    let state: AgentBridgeState
    let activeTurnID: UUID?
    let lastSeq: Int
    let updatedAt: Date
}
