import MyClipCore

/// Owns the ACP client/event-task bookkeeping for each agent. `MyClipModel` still owns
/// `ClipAgentState` (`agents[agent]`) and `permissions` — this type only knows about the
/// live process/connection, not what the app thinks that agent's state is.
@MainActor
final class AgentSessionCoordinator {
    /// Set by the owner after its own `init` completes, mirroring `FocusedCaptureService.onCapture`'s pattern.
    var onEvent: (ACPEvent, ClipAgent) -> Void = { _, _ in }
    private var clients: [ClipAgent: ACPClient] = [:]
    private var eventTasks: [ClipAgent: Task<Void, Never>] = [:]

    func client(_ agent: ClipAgent) -> ACPClient? { clients[agent] }

    func open(_ agent: ClipAgent, command: ACPCommand) async throws -> (ACPClient, ACPHandshake) {
        let client = ACPClient()
        clients[agent] = client
        eventTasks[agent] = Task { [weak self] in
            for await event in client.events {
                guard let self, !Task.isCancelled else { return }
                self.onEvent(event, agent)
            }
        }
        let handshake = try await client.connect(command: command)
        return (client, handshake)
    }

    @discardableResult
    func teardown(_ agent: ClipAgent) async -> ACPClient? {
        eventTasks[agent]?.cancel()
        eventTasks[agent] = nil
        let client = clients.removeValue(forKey: agent)
        await client?.close()
        return client
    }

    func isCurrent(_ client: ACPClient, for agent: ClipAgent) -> Bool {
        clients[agent] === client
    }

    /// Fire-and-forget teardown for app shutdown: cancels event loops and closes whatever
    /// clients are running, without waiting for the closes to finish.
    func stopAll() async {
        eventTasks.values.forEach { $0.cancel() }
        let running = Array(clients.values)
        for client in running { await client.close() }
    }
}
