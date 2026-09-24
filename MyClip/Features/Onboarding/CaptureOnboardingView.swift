import SwiftUI
import AppKit
import MyClipCore

struct CaptureOnboardingView: View {
    @ObservedObject var model: MyClipModel
    var onContinue: () -> Void = {}

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ScrollView {
                    setup(compact: geometry.size.height < 700)
                        .padding(.horizontal, geometry.size.width < 1000 ? 28 : 48)
                        .padding(.vertical, geometry.size.height < 700 ? 20 : 28)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
                }
                .frame(width: max(400, geometry.size.width * 0.5))
                GeometryReader { artwork in
                    Image("OnboardingArtwork")
                        .resizable().scaledToFill()
                        .frame(width: artwork.size.width, height: artwork.size.height)
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            Text("此刻的灵感，\n明日的线索。")
                                .font(.system(size: 28, weight: .medium)).lineSpacing(6)
                                .foregroundStyle(.white).padding(32)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding([.top, .bottom, .trailing], 14)
                .accessibilityHidden(true)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refreshAgentAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAgentAvailability()
        }
    }

    private func setup(compact: Bool) -> some View {
        VStack(alignment: .center, spacing: 0) {
            Label("MyClip", systemImage: "paperclip")
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, compact ? 16 : 28)
            Text("让工作成为记忆。")
                .font(.system(size: compact ? 28 : 34, weight: .semibold)).tracking(-1)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .center)
            Text("完成两项授权，开始记录工作中的线索。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, compact ? 18 : 24)
            form(compact: compact)
            HStack {
                Button("退出 MyClip") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "开始使用"), systemImage: "arrow.right", action: onContinue)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.screenPermission || !model.accessibilityPermission || model.selectingDefaultAgent != nil)
            }
            .padding(.top, compact ? 18 : 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Agent choice, permissions and language. A boxed variant wraps them in one card so the page reads as a form.
    private func form(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("默认 Agent").fontWeight(.medium)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
            defaultAgentSection.padding(.bottom, compact ? 16 : 20)
            HStack {
                Text("权限设置").fontWeight(.medium)
                Spacer()
                Text("\((model.screenPermission ? 1 : 0) + (model.accessibilityPermission ? 1 : 0)) / 2 已授权")
                    .monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
            permission(String(localized: "屏幕录制"), symbol: "rectangle.on.rectangle", detail: String(localized: "读取\(model.preferences.captureSettings.scope.label)的画面"), allowed: model.screenPermission, action: model.requestScreenPermission)
            Divider()
            permission(String(localized: "辅助功能"), symbol: "cursorarrow.rays", detail: String(localized: "识别焦点窗口与截图触发操作"), allowed: model.accessibilityPermission, action: model.requestAccessibilityPermission)
            Divider()
            permission(String(localized: "文件访问（推荐）"), symbol: "folder", detail: String(localized: "读取桌面与文档中的文件，帮助首次整理知识库内容；不授权也可继续使用"), allowed: model.folderPermission, action: model.requestFolderPermission)
            Divider()
            languageRow
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1))
    }

    private var languageRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe").font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text("语言").font(.system(size: 14, weight: .semibold))
                Text("切换后 MyClip 会重新启动").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            languagePicker
        }.padding(.vertical, 18)
    }

    /// Onboarding is where the language is chosen; it starts on the system language, or English when MyClip does not
    /// ship it. The bundle resolved its language at launch, so a change restarts the app.
    private var languagePicker: some View {
        Picker(String(localized: "语言"), selection: Binding(get: { AppLanguage.current }, set: { selected in
            guard selected != AppLanguage.current, !model.preview else { return }
            AppLanguage.select(selected)
            MyClipAppDelegate.relaunch()
        })) {
            ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private var defaultAgentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ClipAgent.allCases) { agentCard($0) }
            }
            ForEach(ClipAgent.allCases) { agent in
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
                    }.font(.caption).buttonStyle(.borderless)
                }
            }
        }
    }

    private func agentCard(_ agent: ClipAgent) -> some View {
        let available = model.localAgents[agent] ?? .missing
        let state = model.state(agent)
        let selected = model.preferences.enabledAgent == agent
        return Button {
            Task { await model.selectDefaultAgent(agent) }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    AgentBrandIcon(agent: agent, size: 24)
                    Text(agent.name).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if model.selectingDefaultAgent == agent || state.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                }
                Text(state.busy ? state.detail : (state.available ? String(localized: "已连接 · 可自动整理") : available.detail))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).frame(height: 28, alignment: .topLeading)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.18), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!available.canSelect || state.busy || model.selectingDefaultAgent != nil)
        .accessibilityLabel("\(agent.name)，\(selected ? String(localized: "默认 Agent") : String(localized: "设为默认 Agent"))，\(available.detail)")
        .help(available == .commandLine ? String(localized: "选择后安装连接组件并验证登录，成功后设为默认 Agent") : String(localized: "连接成功后设为默认 Agent"))
    }

    private func permission(_ title: String, symbol: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // A permission is only ever revoked in System Settings, so the switch acts on the way in and springs
            // back on the way out.
            Toggle(title, isOn: Binding(get: { allowed }, set: { wanted in if wanted && !allowed { action() } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(allowed ? String(localized: "\(title)已授权") : String(localized: "允许\(title)"))
        }.padding(.vertical, 18)
    }
}
