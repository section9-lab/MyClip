import SwiftUI
import MyClipCore

struct OnboardingAgentPicker: View {
    @ObservedObject var model: MyClipModel
    @ObservedObject var selection: OnboardingAgentSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ClipAgent.allCases) { agentCard($0) }
            }
            if selection.startAttempted, let agent = selection.selectedAgent {
                let state = model.state(agent)
                if state.phase == .failed {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(agent.name)：\(state.detail)").foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(state.authMethods) { method in
                            Button(method.name) { model.authenticate(agent, method: method) }
                        }
                        if model.hasLoginCommand(agent) {
                            Button("复制 \(agent.name) 登录命令") { model.copyLoginCommand(for: agent) }
                        }
                    }.font(.caption).buttonStyle(.bordered)
                }
            }
        }
    }

    private func agentCard(_ agent: ClipAgent) -> some View {
        let available = model.localAgents[agent] ?? .missing
        let selected = selection.selectedAgent == agent
        return Button {
            selection.select(agent)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    AgentBrandIcon(agent: agent, size: 24)
                    Text(agent.name).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                        .fixedSize()
                }
                Text(available.detail)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).frame(height: 28, alignment: .topLeading)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(selected ? Color.accentColor : nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("onboarding-agent-\(agent.rawValue)")
        .disabled(!available.canSelect || selection.starting)
        .accessibilityLabel("\(agent.name)，\(selected ? String(localized: "默认 Agent") : String(localized: "设为默认 Agent"))，\(available.detail)")
        .help("点击“开始使用”后连接并启用所选 Agent")
    }

}
