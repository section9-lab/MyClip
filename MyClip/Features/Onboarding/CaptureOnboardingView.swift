import SwiftUI
import AppKit
import MyClipCore

struct CaptureOnboardingView: View {
    @ObservedObject var model: MyClipModel
    var onContinue: () -> Void = {}
    @State private var showingPermissions = true
    @StateObject private var selection = OnboardingAgentSelection()

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
        .onAppear {
            model.refreshAgentAvailability()
            selection.restore(model.preferences.enabledAgent)
        }
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
            Text("第 \(showingPermissions ? 1 : 2) 步，共 2 步")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .padding(.bottom, 10)
            Text(showingPermissions ? String(localized: "权限与语言") : String(localized: "选择整理 Agent"))
                .font(.system(size: compact ? 28 : 34, weight: .semibold)).tracking(-1)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(showingPermissions ? String(localized: "完成两项授权，开始记录工作中的线索。") : String(localized: "选择 Agent 整理工作记录，也可以稍后设置。"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, compact ? 18 : 24)
            form
            HStack {
                if !showingPermissions {
                    Button("上一步") { showingPermissions = true }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("onboarding-back")
                        .disabled(selection.starting)
                } else {
                    Button("退出 MyClip") { NSApp.terminate(nil) }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(showingPermissions ? String(localized: "下一步") : String(localized: "开始使用"), systemImage: "arrow.right") {
                    if showingPermissions { showingPermissions = false }
                    else { startUsing() }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(showingPermissions ? "onboarding-next" : "onboarding-start")
                .disabled(!model.screenPermission || !model.accessibilityPermission || selection.starting)
                if selection.starting { ProgressView().controlSize(.small).accessibilityLabel("正在准备 Agent") }
            }
            .padding(.top, compact ? 18 : 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Each step keeps its own controls together; navigation preserves the model's choices and permission state.
    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingPermissions {
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
            } else {
                Text("默认 Agent").fontWeight(.medium)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
                OnboardingAgentPicker(model: model, selection: selection)
            }
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

    private func startUsing() {
        Task { @MainActor in
            if await selection.start(using: model) { onContinue() }
        }
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
            // The switch reflects the OS permission; either tap opens the relevant authorization flow.
            Toggle(title, isOn: Binding(get: { allowed }, set: { _ in action() }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(allowed ? String(localized: "\(title)已授权") : String(localized: "允许\(title)"))
        }.padding(.vertical, 18)
    }
}
