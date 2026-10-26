import Foundation

public struct AgentAccountContext: Sendable {
    public let provider: ClipAgent
    public let scope: URL
    public let allowKeychainInteraction: Bool
    public init(provider: ClipAgent, scope: URL, allowKeychainInteraction: Bool = false) {
        self.provider = provider; self.scope = scope; self.allowKeychainInteraction = allowKeychainInteraction
    }
}

public struct AgentAccountInfo: Sendable {
    public let account: String
    public let accountID: String
    public let plan: String
    public let organization: String
    public let creditsUsed: Double?
    public let creditsTotal: Double?
    public let creditsRemaining: Double?
}

public protocol AgentAccountStorage: Sendable {
    func read() async throws -> Data?
    func save(_ data: Data) async throws
}

public actor AgentAccountKeychain: AgentAccountStorage {
    private let secrets: KeychainDataStore
    private let account: String
    private let allowInteraction: Bool
    public init(context: AgentAccountContext) {
        secrets = KeychainDataStore(service: "cc.vibevibe.myclip.agents." + CloudMemoryDocument.hash(context.scope.standardizedFileURL.path))
        account = context.provider.rawValue
        allowInteraction = context.allowKeychainInteraction
    }
    public func read() throws -> Data? { try secrets.read(account, allowInteraction: allowInteraction) }
    public func save(_ data: Data) throws { try secrets.save(data, for: account) }
}

public enum SubscriptionAgentCommand {
    public static func allowsAuthorization(_ url: URL, provider: ClipAgent) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, let host = url.host else { return false }
        switch provider {
        case .qwenwork: return host == "gateway.qwenwork.cn"
        case .workbuddy: return host == "www.workbuddy.cn" || host == "workbuddy.cn"
        default: return false
        }
    }
    /// Source controlled bridge resources are read directly from MyClipCore's bundle.
    public static func make(provider: ClipAgent, node: URL, engine: ACPCommand, runtimeRoot: URL) -> ACPCommand? {
        guard provider == .qwenwork || provider == .workbuddy,
              let resource = Bundle.module.url(forResource: "agent", withExtension: "mjs", subdirectory: "Resources/SubscriptionAgent") else { return nil }
        var command = ACPCommand(executable: node,
            arguments: [resource.path, provider.rawValue, runtimeRoot.appendingPathComponent("Accounts/" + provider.rawValue).path,
                        engine.executable.path] + engine.arguments, environment: engine.environment)
        command.accountContext = AgentAccountContext(provider: provider, scope: runtimeRoot.deletingLastPathComponent())
        return command
    }
}
