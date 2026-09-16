import AppKit
import SwiftUI
import MyClipCore

struct AgentBrandIcon: View {
    let agent: ClipAgent
    var size: CGFloat = 30
    var body: some View {
        AgentCharacterIcon(agent: agent, state: .init(), size: size, animated: false)
    }
}

struct AgentStatusIcon: View {
    let agent: ClipAgent
    let state: ClipAgentState
    var body: some View {
        AgentCharacterIcon(agent: agent, state: state, size: 32).padding(2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(agent.name)
            .accessibilityValue(state.detail)
    }
}

struct AgentCharacterIcon: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let agent: ClipAgent
    let state: ClipAgentState
    var size: CGFloat = 32
    var animated = true
    var interactive = false

    func makeNSView(context: Context) -> AgentCharacterView { AgentCharacterView(agent: agent) }
    func updateNSView(_ view: AgentCharacterView, context: Context) {
        view.configure(state: state, animated: animated, interactive: interactive, reduceMotion: reduceMotion)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentCharacterView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}
