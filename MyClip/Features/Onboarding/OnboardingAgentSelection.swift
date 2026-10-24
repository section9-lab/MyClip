import Combine
import MyClipCore

/// A draft owned by one onboarding view. Selecting a card never changes the active Agent.
@MainActor
final class OnboardingAgentSelection: ObservableObject {
    @Published private(set) var selectedAgent: ClipAgent?
    @Published private(set) var starting = false
    @Published private(set) var startAttempted = false
    private var restored = false

    func restore(_ agent: ClipAgent?) {
        guard !restored else { return }
        restored = true
        selectedAgent = agent
    }

    func select(_ agent: ClipAgent) {
        guard !starting else { return }
        selectedAgent = selectedAgent == agent ? nil : agent
        startAttempted = false
    }

    func start(using model: MyClipModel) async -> Bool {
        guard !starting else { return false }
        starting = true
        startAttempted = true
        defer { starting = false }
        guard let selectedAgent, !model.preview else { return true }
        await model.selectDefaultAgent(selectedAgent)
        return model.preferences.enabledAgent == selectedAgent && model.state(selectedAgent).available
    }
}
