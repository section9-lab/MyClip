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

/// A queue row's icon: the Agent for a batch; a moon for a dream, which reorganizes all of memory, with its Agent as a badge.
struct JobIcon: View {
    let job: ClipJob
    var size: CGFloat = 28
    var body: some View {
        if job.kind == .dream {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "moon.stars.fill").font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: size, height: size).background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: size * 0.3))
                AgentBrandIcon(agent: job.agent, size: size * 0.5).offset(x: size * 0.2, y: size * 0.2)
            }.padding(.trailing, size * 0.2).accessibilityHidden(true)
        } else {
            AgentBrandIcon(agent: job.agent, size: size)
        }
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
