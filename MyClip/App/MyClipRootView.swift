import SwiftUI
import AppKit
import MyClipCore

struct MyClipRootView: View {
    @ObservedObject var model: MyClipModel
    @FocusState private var searchFocused: Bool
    @State private var showingOnboarding = false

    var body: some View {
        Group {
            if model.showPermissions || showingOnboarding {
                CaptureOnboardingView(model: model) { showingOnboarding = false }
            }
            else { libraryContent }
        }
        .alert("MyClip", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("好", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .frame(minWidth: 840, minHeight: 580)
        .onAppear {
            showingOnboarding = model.showPermissions
            #if DEBUG
            // Permissions are already granted on a development machine, so the preview needs a way in.
            if model.preview && CommandLine.arguments.contains("--onboarding") { showingOnboarding = true }
            #endif
        }
        .onChange(of: model.showPermissions) { if $0 { showingOnboarding = true } }
        .onReceive(NotificationCenter.default.publisher(for: .init("MyClipShowOnboarding"))) { _ in
            if !model.preview { showingOnboarding = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("MyClipFocusSearch"))) { _ in
            if !model.showPermissions && !showingOnboarding { searchFocused = true }
        }
    }

    /// The footer gear behaves like an accessory-bar control: it highlights on hover and press, and stays lit while the
    /// Settings page is showing. Turning the toggle off does nothing; the page only changes through the sidebar.
    @ViewBuilder private var settingsButton: some View {
        let showingSettings = Binding(get: { model.page == .settings }, set: { if $0 { model.open(.settings) } })
        if #available(macOS 14, *) {
            Toggle(isOn: showingSettings) { Image(systemName: "gearshape") }
                .toggleStyle(.button).buttonStyle(.accessoryBar)
                .help("设置").accessibilityLabel("设置")
        } else {
            Button { model.open(.settings) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("设置").accessibilityLabel("设置")
        }
    }

    private var libraryContent: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索任务、记忆与截图", text: $model.search).textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onExitCommand {
                            if model.search.isEmpty { searchFocused = false }
                            else { model.search = "" }
                        }
                    if !model.search.isEmpty {
                        Button { model.search = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索").accessibilityLabel("清除搜索")
                    }
                }
                .padding(9).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 14)
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
                        // The footer is a status light for the Agent in use; another one only appears while it finishes a batch.
                        ForEach(ClipAgent.allCases.filter { model.preferences.enabledAgent == $0 || model.state($0).phase == .working || model.state($0).phase == .permission }) { agent in
                            Button { model.open(.agents) } label: {
                                AgentStatusIcon(agent: agent, state: model.state(agent))
                            }.buttonStyle(.plain).help("\(agent.name) · \(model.state(agent).detail)")
                        }
                        if model.preferences.enabledAgent == nil, !model.agents.values.contains(where: { $0.phase == .working }) {
                            Button { model.open(.agents) } label: { Image(systemName: "person.crop.circle.dashed").font(.system(size: 22)).foregroundStyle(.secondary) }
                                .buttonStyle(.plain).help("还没有选择整理 Agent")
                        }
                        Spacer()
                        settingsButton
                    }
                    if model.preview { Text("界面预览 · 示例数据").font(.caption2).foregroundStyle(.orange) }
                }.padding(18)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
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
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(model.page?.title ?? "MyClip")
        }
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
