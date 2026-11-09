import SwiftUI
import AppKit
import MyClipCore

struct MyClipRootView: View {
    @ObservedObject var model: MyClipModel
    @State private var searchFocused = false
    @State private var showingOnboarding = false

    var body: some View {
        Group {
            if showingOnboarding {
                CaptureOnboardingView(model: model, onContinue: { showingOnboarding = false }, onCancel: { showingOnboarding = false })
            } else {
                libraryContent
            }
        }
        .buttonStyle(.bordered)
        .menuStyle(.borderedButton)
        .textFieldStyle(.roundedBorder)
        .scrollIndicators(.automatic)
        .frame(minWidth: 840, minHeight: 580)
        .onAppear {
            showingOnboarding = model.showPermissions
            #if DEBUG
            // Permissions are already granted on a development machine, so the preview needs a way in.
            if model.preview && CommandLine.arguments.contains("--onboarding") { showingOnboarding = true }
            #endif
        }
        .onChange(of: model.showPermissions) { if $0 { showingOnboarding = true } }
        .onChange(of: model.page) { _ in
            if !model.search.isEmpty { model.search = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("MyClipShowOnboarding"))) { _ in
            if !model.preview { showingOnboarding = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("MyClipFocusSearch"))) { _ in
            if !showingOnboarding && model.page?.supportsSearch == true { searchFocused = true }
        }
    }

    @ViewBuilder private var settingsButton: some View {
        if #available(macOS 14, *) {
            Button { model.open(.settings) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.accessoryBar)
                .help("设置").accessibilityLabel("设置")
        } else {
            Button { model.open(.settings) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("设置").accessibilityLabel("设置")
        }
    }

    private var captureButton: some View {
        Button {
            if model.showPermissions { showingOnboarding = true }
            else { model.toggleCapture() }
        } label: {
            Label(captureLabel, systemImage: captureSymbol)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(model.preview)
        .help(captureHelp)
        .accessibilityLabel(captureAccessibilityLabel)
        .accessibilityValue(model.captureStatus)
    }

    private var captureLabel: String {
        if model.showPermissions { return String(localized: "权限设置") }
        if !model.preferences.captureEnabled { return String(localized: "采集已暂停") }
        return model.capturing ? String(localized: "采集中") : String(localized: "正在准备采集")
    }

    private var captureSymbol: String {
        if model.showPermissions { return "exclamationmark.triangle" }
        if !model.preferences.captureEnabled { return "pause.circle" }
        return model.capturing ? "record.circle.fill" : "clock"
    }

    private var captureHelp: String { model.captureStatus }

    private var captureAccessibilityLabel: String {
        if model.showPermissions { return String(localized: "设置采集权限…") }
        return model.preferences.captureEnabled ? String(localized: "暂停采集") : String(localized: "继续采集")
    }

    private var libraryContent: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if let page = model.page, page.supportsSearch {
                    LibrarySearchField(text: $model.search, focused: $searchFocused, placeholder: page.searchPlaceholder)
                        .frame(height: 28)
                        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 14)
                }
                List(selection: $model.page) {
                    Section("资料库") {
                        sidebarRow(.memory)
                        sidebarRow(.captures)
                        sidebarRow(.dashboard)
                        sidebarRow(.agents)
                    }
                }
                .listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        captureButton
                        Spacer(minLength: 4)
                        // The footer is a status light for the Agent in use; another one only appears while it finishes a batch.
                        ForEach(ClipAgent.allCases.filter { model.preferences.enabledAgent == $0 || model.state($0).phase == .working || model.state($0).phase == .permission }) { agent in
                            Button { model.open(.agents) } label: {
                                AgentStatusIcon(agent: agent, state: model.state(agent))
                            }.buttonStyle(.borderless).help("\(agent.name) · \(model.state(agent).detail)")
                        }
                        if model.preferences.enabledAgent == nil, !model.agents.values.contains(where: { $0.phase == .working }) {
                            Button { model.open(.agents) } label: { Image(systemName: "person.crop.circle.dashed").font(.system(size: 22)).foregroundStyle(.secondary) }
                                .buttonStyle(.borderless).help("还没有选择整理 Agent")
                        }
                        settingsButton
                    }
                    if model.preview { Text("界面预览 · 示例数据").font(.caption2).foregroundStyle(.orange) }
                }.padding(18)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if let notice = model.notice { noticeBanner(notice) }
                Group {
                    switch model.page ?? .captures {
                    case .dashboard: AnalyticsView(model: model)
                    case .memory: KnowledgeLibraryView(model: model)
                    case .captures: CaptureLibraryView(model: model)
                    case .agents: BackstageView(model: model)
                    case .settings: MyClipSettingsView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(model.page?.title ?? "MyClip")
        }
    }

    /// A failed library load must never look like an empty library. Keep the reason visible with a retry.
    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(notice).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试") { Task { await model.refresh() } }
                .controlSize(.small)
            Button { model.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("关闭")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private func sidebarRow(_ page: LibraryPage) -> some View {
        Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.symbol).font(.system(size: 18, weight: .regular)).foregroundStyle(.blue).frame(width: 24)
        }
        .padding(.vertical, 6).tag(page)
    }
}
