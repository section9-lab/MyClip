import SwiftUI
import AppKit
import Charts
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

private enum MemoryFileSelection: Hashable {
    case entry(UUID)
    case folder(String)
}

private enum MemoryPresentation {
    static func title(_ entry: KnowledgeEntry) -> String {
        switch entry.relativePath {
        case "Memory.md": String(localized: "记忆概览")
        case "Profile.md": String(localized: "关于我")
        case "Now.md": String(localized: "当前关注")
        default: entry.title
        }
    }

    static func folder(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "Memory")
    }

    static func symbol(_ path: String) -> String {
        switch path {
        case "Memory.md": "square.grid.2x2"
        case "Profile.md": "person.crop.circle"
        case "Now.md": "scope"
        case "Wiki": "books.vertical"
        case "Daily": "calendar"
        case "Inbox": "tray"
        default: "folder"
        }
    }
}

private struct MemoryDirectoryView: View {
    @ObservedObject var model: MyClipModel

    var body: some View {
        List(selection: selection) {
            OutlineGroup(MemoryFileNode.tree(model.library), id: \.selection, children: \.children) { node in
                Label {
                    Text(node.name).lineLimit(1)
                } icon: {
                    Image(systemName: node.entry == nil ? "folder" : "doc.text")
                        .foregroundStyle(node.entry == nil ? Color.blue : Color.secondary)
                }
                .padding(.vertical, 3).tag(node.selection).help(node.id)
            }
        }.listStyle(.sidebar).scrollContentBackground(.hidden)
        .contextMenu {
            Button(String(localized: "Memory 根目录"), systemImage: "folder") {
                model.search = ""; model.selectedEntry = nil; model.memoryFolder = ""
            }
            Button(String(localized: "在 Finder 中打开"), systemImage: "arrow.up.forward.square") {
                NSWorkspace.shared.open(model.store.root.appendingPathComponent("Memory"))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 300, maxHeight: .infinity)
        .accessibilityElement(children: .contain).accessibilityLabel("Memory 文件目录")
    }

    private var selection: Binding<MemoryFileSelection?> {
        Binding(get: {
            if let id = model.selectedEntry { return .entry(id) }
            return model.memoryFolder.map { .folder($0) }
        }, set: { value in
            guard let value else { return }
            model.search = ""
            switch value {
            case .entry(let id): model.selectedEntry = id
            case .folder(let path): model.selectedEntry = nil; model.memoryFolder = path
            }
        })
    }
}

private struct KnowledgeLibraryView: View {
    @ObservedObject var model: MyClipModel
    @State private var proposal: MemoryProposal?

    private var selected: KnowledgeEntry? {
        (model.results.entries + model.library.entries).first { $0.id == model.selectedEntry }
    }

    var body: some View {
        HSplitView {
            MemoryDirectoryView(model: model)
            content.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $proposal) { ProposalReviewView(model: model, proposal: $0) }
        .task(id: model.library.entries.first { $0.relativePath == "Memory.md" }?.id) {
            if model.selectedEntry == nil && model.memoryFolder == nil && model.search.isEmpty {
                model.selectedEntry = model.library.entries.first { $0.relativePath == "Memory.md" }?.id
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if !model.proposals.isEmpty {
                HStack {
                    Image(systemName: "pencil.badge.clock").foregroundStyle(.orange)
                    Menu("\(model.proposals.count) 项修改待确认") {
                        ForEach(model.proposals) { item in Button(item.drafts.first?.title ?? String(localized: "修改建议")) { proposal = item } }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                }.padding(.horizontal, 32).padding(.vertical, 12)
                Divider()
            }
            if let entry = selected {
                KnowledgeDetailView(model: model, entry: entry).id(entry.id)
            } else if !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MemoryCollectionView(model: model, title: String(localized: "搜索结果"), entries: model.results.entries)
            } else if let folder = model.memoryFolder {
                MemoryFolderView(model: model, path: folder)
            } else {
                LibraryUnavailableView(String(localized: "选择一篇记忆"), systemImage: "doc.text", description: Text("从边栏选择记忆，查看内容与来源。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct MemoryFileNode: Identifiable {
    let id: String
    let entry: KnowledgeEntry?
    let children: [MemoryFileNode]?
    var name: String { String(id.split(separator: "/").last ?? "") }
    var selection: MemoryFileSelection { entry.map { .entry($0.id) } ?? .folder(id) }

    static func tree(_ library: LibrarySnapshot, at path: String = "") -> [MemoryFileNode] {
        func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
        func nodes(_ path: String) -> [MemoryFileNode] {
            let directories = library.memoryFolders.filter { parent($0) == path }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { folder in
                let children = nodes(folder)
                return MemoryFileNode(id: folder, entry: nil, children: children.isEmpty ? nil : children)
            }
            let files = library.entries.filter { parent($0.relativePath) == path }.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }.map {
                MemoryFileNode(id: $0.relativePath, entry: $0, children: nil)
            }
            return directories + files
        }
        return nodes(path)
    }
}

private struct MemoryFolderView: View {
    @ObservedObject var model: MyClipModel
    let path: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !path.isEmpty {
                    Button {
                        model.memoryFolder = path.split(separator: "/").dropLast().joined(separator: "/")
                    } label: {
                        Label(String(localized: "上一级"), systemImage: "chevron.left")
                    }.buttonStyle(.borderless)
                }
                Text(MemoryPresentation.folder(path)).font(.system(size: 30, weight: .bold))
                let items = MemoryFileNode.tree(model.library, at: path)
                if items.isEmpty {
                    LibraryUnavailableView(String(localized: "文件夹为空"), systemImage: "folder", description: Text("记忆保存到这里后，会显示在目录中。"))
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    VStack(spacing: 0) {
                        ForEach(items) { node in
                            Button {
                                model.selectedEntry = node.entry?.id
                                if node.entry == nil { model.memoryFolder = node.id }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: node.entry == nil ? "folder" : "doc.text")
                                        .font(.system(size: 20)).foregroundStyle(node.entry == nil ? Color.blue : Color.secondary).frame(width: 24)
                                    Text(node.name).foregroundStyle(.primary).lineLimit(2)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }.padding(.vertical, 14).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if node.id != items.last?.id { Divider().padding(.leading, 36) }
                        }
                    }
                }
            }.padding(32).frame(maxWidth: 840).frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct MemoryCollectionView: View {
    @ObservedObject var model: MyClipModel
    let title: String
    let entries: [KnowledgeEntry]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 30, weight: .bold))
                    Text("\(entries.count) 篇记忆").foregroundStyle(.secondary)
                }
                if entries.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: model.search.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                        Text(model.search.isEmpty ? String(localized: "这里还没有记忆") : String(localized: "没有找到相关记忆")).font(.title3.weight(.semibold))
                        Text(model.search.isEmpty ? String(localized: "截图整理后，相关内容会出现在这里。") : String(localized: "试试其他关键词，或从边栏浏览已有内容。"))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 80)
                } else {
                    MemoryEntryList(model: model, entries: entries)
                }
            }.padding(40).frame(maxWidth: 840).frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct MemoryEntryList: View {
    @ObservedObject var model: MyClipModel
    let entries: [KnowledgeEntry]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                Button {
                    model.selectedEntry = entry.id
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: entry.isRootDocument ? MemoryPresentation.symbol(entry.relativePath) : "doc.text")
                            .font(.system(size: 20, weight: .light)).foregroundStyle(.blue).frame(width: 24).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(MemoryPresentation.title(entry)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                            let excerpt = entry.searchExcerpt(query: model.search).text
                            Text(excerpt).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                            Text(entry.updatedAt, format: .dateTime.month().day()).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 4)
                    }.padding(.vertical, 18).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if entry.id != entries.last?.id { Divider().padding(.leading, 38) }
            }
        }
    }
}

private struct KnowledgeDetailView: View {
    @ObservedObject var model: MyClipModel
    @Environment(\.locale) private var locale
    let entry: KnowledgeEntry
    @State private var sources: [ClipCapture] = []
    @State private var source: ClipCapture?
    @State private var editing = false
    @State private var deleting = false
    @State private var moving = false
    @State private var showingInfo = false
    @State private var relations: MemoryRelations?

    var body: some View {
        MemoryScrollView(initialOffset: model.memoryScrollOffsets[entry.id, default: 0], onScroll: { model.memoryScrollOffsets[entry.id] = $0 }) {
            VStack(alignment: .leading, spacing: 28) {
                if entry.relativePath == "Now.md" {
                    if let observed = entry.observedAt {
                        Text("内容依据截至 \(observed.formatted(.dateTime.year().month().day().hour().minute()))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("内容时间尚未确认，请结合来源判断当前状态。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                MemoryMarkdownView(markdown: entry.body, baseURL: entry.fileURL.deletingLastPathComponent(), openMemoryLink: model.openMemoryLink)
                references
            }.padding(32).frame(maxWidth: 840).frame(maxWidth: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .contextMenu { actions }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: "\(entry.id)-\(entry.revision)") {
            do { sources = try await model.store.availableCaptures(ids: entry.sourceIDs); relations = try await model.store.relations(entry.id) }
            catch { model.notice = error.localizedDescription }
        }
        .sheet(item: $source) { CaptureDetailView(model: model, capture: $0) }
        .sheet(isPresented: $editing) { EntryEditor(model: model, entry: entry) }
        .sheet(isPresented: $moving) { MemoryMoveSheet(model: model, entry: entry) }
        .sheet(isPresented: $showingInfo) {
            VStack(spacing: 0) {
                information.environment(\.locale, locale)
                Button("完成") { showingInfo = false }.keyboardShortcut(.cancelAction).padding(.bottom, 20)
            }
        }
        .confirmationDialog("删除“\(entry.title)”？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除条目及其版本", role: .destructive) { model.delete(entry) }
        } message: { Text("来源截图会保留。") }
    }

    private var actions: some View {
        Group {
            Button(String(localized: "返回文件夹"), systemImage: "chevron.left") {
                model.search = ""
                model.selectedEntry = nil
                model.memoryFolder = entry.relativePath.split(separator: "/").dropLast().joined(separator: "/")
            }
            Button(String(localized: "编辑 Markdown"), systemImage: "square.and.pencil") { editing = true }
            ShareLink(item: entry.fileURL) { Label(String(localized: "导出 Markdown"), systemImage: "square.and.arrow.up") }
            Button(String(localized: "文件信息"), systemImage: "info.circle") { showingInfo = true }
            Divider()
            Button(String(localized: "显示 Markdown 文件"), systemImage: "doc.text") { NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL]) }
            Button(String(localized: "打开 Memory 文件夹"), systemImage: "folder") { NSWorkspace.shared.open(model.store.root.appendingPathComponent("Memory")) }
            Divider()
            Button(String(localized: "移动或重命名…"), systemImage: "folder") { moving = true }.disabled(entry.isRootDocument)
            Button(String(localized: "删除条目"), systemImage: "trash", role: .destructive) { deleting = true }.disabled(entry.isRootDocument)
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("文件信息").font(.headline)
            Text(entry.relativePath).textSelection(.enabled)
            LabeledContent("文件更新") { Text(entry.updatedAt, format: .dateTime.year().month().day().hour().minute()) }
            if let observed = entry.observedAt {
                LabeledContent("内容依据截至") { Text(observed, format: .dateTime.year().month().day().hour().minute()) }
            }
            if !entry.contextSourceIDs.isEmpty { LabeledContent("整理时参考", value: String(localized: "\(entry.contextSourceIDs.count) 张截图；具体依据见正文引用")) }
            LabeledContent("版本", value: String(localized: "第 \(entry.revision) 版"))
            if !entry.sourceIDs.isEmpty { LabeledContent("整理", value: entry.agent.name) }
            if let relations, !relations.incoming.isEmpty {
                Divider()
                Text("引用此文件").font(.caption).foregroundStyle(.secondary)
                ForEach(relations.incoming) { item in
                    Button(MemoryPresentation.title(item), systemImage: "link") { showingInfo = false; model.selectedEntry = item.id }.buttonStyle(.link)
                }
            }
        }.font(.callout).padding(20).frame(width: 300)
    }

    @ViewBuilder private var references: some View {
        if let relations, !relations.outgoing.isEmpty || !relations.incoming.isEmpty || !relations.unresolved.isEmpty {
            Divider()
            DisclosureGroup("关联记忆 · \(relations.outgoing.count + relations.incoming.count)") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(relations.outgoing) { item in Button(MemoryPresentation.title(item), systemImage: "link") { model.selectedEntry = item.id }.buttonStyle(.link) }
                    ForEach(relations.incoming) { item in Button("引用自：" + MemoryPresentation.title(item), systemImage: "arrow.turn.up.left") { model.selectedEntry = item.id }.buttonStyle(.link) }
                    ForEach(relations.unresolved, id: \.self) { Text("未解析：" + $0).foregroundStyle(.orange).font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            }.font(.callout).foregroundStyle(.secondary)
        }
        if !entry.sourceIDs.isEmpty {
            DisclosureGroup("来源截图 · \(entry.sourceIDs.count)") {
                VStack(alignment: .leading, spacing: 12) {
                    if sources.count < entry.sourceIDs.count { Text("部分来源记录未包含在当前资料库中。").font(.caption).foregroundStyle(.secondary) }
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(sources) { capture in
                                Button { source = capture } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        CaptureThumbnail(capture: capture).frame(width: 220, height: 134).clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(capture.appName).font(.callout)
                                        Text(capture.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.padding(.bottom, 8)
                    }
                }.padding(.top, 12)
            }.font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct MemoryMoveSheet: View {
    @ObservedObject var model: MyClipModel
    let entry: KnowledgeEntry
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("移动或重命名").font(.title2.bold())
            Text("输入相对于 Memory 的文件路径，已有链接会自动更新。").foregroundStyle(.secondary)
            TextField("例如 Wiki/Projects/MyClip.md", text: $path).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Markdown 文件路径")
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    saving = true
                    Task { if await model.move(entry, to: path) { dismiss() }; saving = false }
                }.keyboardShortcut(.defaultAction).disabled(saving || path.isEmpty || path == entry.relativePath)
            }
        }.padding(24).frame(width: 510)
        .onAppear { path = entry.relativePath }
    }
}

private struct EntryEditor: View {
    @ObservedObject var model: MyClipModel
    let entry: KnowledgeEntry
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var saving = false
    @State private var previewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(entry.fileURL.lastPathComponent, systemImage: "doc.text").font(.headline)
                Spacer()
                Picker("显示模式", selection: $previewing) {
                    Text("编辑").tag(false)
                    Text("预览").tag(true)
                }.pickerStyle(.segmented).frame(width: 160)
            }
            if !entry.isRootDocument { TextField("标题", text: $title).textFieldStyle(.roundedBorder).font(.title3) }
            Group {
                if previewing {
                    ScrollView {
                        MemoryMarkdownView(markdown: bodyText, baseURL: entry.fileURL.deletingLastPathComponent())
                            .padding(24)
                    }
                } else {
                    TextEditor(text: $bodyText).font(.system(size: 14, design: .monospaced))
                        .autocorrectionDisabled().padding(12)
                        .accessibilityLabel("Markdown 源码")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 0.5))
            HStack {
                Text("Markdown · 保存时保留来源与历史版本").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    saving = true
                    Task { if await model.save(entry, title: title, body: bodyText) { dismiss() }; saving = false }
                }.keyboardShortcut("s", modifiers: .command).disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.isEmpty)
            }
        }.padding(24).frame(width: 760, height: 600)
        .onAppear { title = entry.title; bodyText = entry.body }
    }
}

/// One Timeline card: every look at the same window inside `LibraryStore.sceneGap`, newest frame first.
struct CaptureScene: Identifiable {
    let id: String
    let frames: [ClipCapture]
    var latest: ClipCapture { frames[0] }
    var earliest: ClipCapture { frames[frames.count - 1] }
    var imageCount: Int { Set(frames.map(\.imageID)).count }

    /// Folds consecutive captures by scene; a filter on the trigger event shows every occurrence instead.
    static func fold(_ captures: [ClipCapture], folding: Bool) -> [CaptureScene] {
        guard folding else { return captures.map { CaptureScene(id: $0.id.uuidString, frames: [$0]) } }
        var order: [String] = []
        var frames: [String: [ClipCapture]] = [:]
        for capture in captures {
            if frames[capture.sceneID] == nil { order.append(capture.sceneID) }
            frames[capture.sceneID, default: []].append(capture)
        }
        return order.map { CaptureScene(id: $0, frames: frames[$0]!) }
    }
}

private struct CaptureLibraryView: View {
    @ObservedObject var model: MyClipModel
    @Environment(\.locale) private var locale
    @State private var source: CaptureScene?
    @State private var showDateFilter = false
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var endDate = Calendar.current.startOfDay(for: Date())
    var captures: [ClipCapture] { model.results.captures }
    var folding: Bool { model.captureFilter.event == .all }
    var scenes: [CaptureScene] { CaptureScene.fold(captures, folding: folding) }
    var days: [Date] { Array(Set(scenes.map { Calendar.current.startOfDay(for: $0.latest.date) })).sorted(by: >) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ViewThatFits(in: .horizontal) {
                    HStack { resultSummary; Spacer(minLength: 20); filterControls }
                    VStack(alignment: .leading, spacing: 12) {
                        filterControls.frame(maxWidth: .infinity, alignment: .trailing)
                        resultSummary
                    }
                }
                if captures.isEmpty {
                    if model.captureFilter.isActive {
                        LibraryEmptyView(symbol: "line.3.horizontal.decrease", title: String(localized: "没有符合条件的截图"), detail: String(localized: "试试其他应用、日期或触发事件，或清除筛选条件。"), action: String(localized: "清除筛选")) { model.captureFilter = CaptureFilter() }
                    } else if !model.search.isEmpty {
                        LibraryEmptyView(symbol: "magnifyingglass", title: String(localized: "没有找到相关截图"), detail: String(localized: "试试其他关键词，或清除搜索查看全部截图。"), action: String(localized: "清除搜索")) { model.search = "" }
                    } else {
                        LibraryEmptyView(symbol: model.capturing ? "record.circle" : "macwindow", title: model.capturing ? String(localized: "等待第一张截图") : String(localized: "等待自动采集"), detail: model.preferences.captureSettings.description, action: String(localized: "查看采集设置")) { model.open(.settings) }
                    }
                } else {
                    ForEach(days, id: \.self) { day in
                        Text(day, format: .dateTime.year().month().day().weekday()).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 20)], alignment: .leading, spacing: 26) {
                        ForEach(scenes.filter { Calendar.current.isDate($0.latest.date, inSameDayAs: day) }) { scene in
                            let capture = scene.latest
                            Button { source = scene } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    CaptureThumbnail(capture: capture).frame(height: 166).clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(alignment: .topTrailing) {
                                            if scene.frames.count > 1 {
                                                Text("×\(scene.frames.count)").font(.caption.weight(.semibold)).monospacedDigit()
                                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                                    .background(.thinMaterial, in: Capsule()).padding(8)
                                                    .accessibilityLabel("\(scene.frames.count) 次出现")
                                            }
                                        }
                                    HStack {
                                        Text(capture.appName).font(.headline)
                                        Spacer()
                                        if scene.frames.count > 1 {
                                            Text("\(scene.earliest.date.formatted(.dateTime.hour().minute())) – \(capture.date.formatted(.dateTime.hour().minute()))")
                                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                        } else {
                                            Text(capture.date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(capture.windowTitle.isEmpty ? String(localized: "未命名窗口") : capture.windowTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    HStack {
                                        Text(capture.date, format: .dateTime.month().day()).font(.caption2).foregroundStyle(.tertiary)
                                        if scene.frames.count > 1 {
                                            Text("· \(scene.imageCount) 张不同画面").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Label(capture.reason.label, systemImage: capture.reason.systemImage)
                                            .labelStyle(.iconOnly).font(.caption).foregroundStyle(.secondary)
                                            .help(capture.reason.label)
                                    }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("\(capture.appName)，\(scene.frames.count) 次出现，\(capture.windowTitle)")
                        }
                    }
                    }
                }
            }.padding(36).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
        .sheet(item: $source) { CaptureDetailView(model: model, frames: $0.frames) }
    }

    private var resultSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if folding, scenes.count < captures.count {
                Text("\(scenes.count) 个画面 · \(captures.count) 次出现")
            } else {
                Text(model.search.isEmpty && !model.captureFilter.isActive ? String(localized: "\(model.library.imageCount) 张独立图片") : String(localized: "\(model.results.captureCount) 条结果"))
            }
            if model.results.captureCount > captures.count { Text("显示最近 \(captures.count) 条记录") }
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
    }

    private var filterControls: some View {
        HStack(spacing: 8) {
            Picker("应用", selection: $model.captureFilter.appName) {
                Text("全部应用").tag(String?.none)
                ForEach(model.library.captureAppNames, id: \.self) { Text($0).tag(Optional($0)) }
            }.labelsHidden().frame(width: 150, alignment: .trailing).help("按应用筛选").accessibilityLabel("应用筛选")
            Button {
                startDate = model.captureFilter.dateRange?.lowerBound ?? Calendar.current.startOfDay(for: Date())
                endDate = model.captureFilter.dateRange?.upperBound ?? startDate
                showDateFilter = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(dateFilterLabel).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.caption2)
                }.frame(maxWidth: 170)
            }
            .help(model.captureFilter.dateRange.map { "\($0.lowerBound.formatted(.dateTime.year().month().day().locale(locale))) – \($0.upperBound.formatted(.dateTime.year().month().day().locale(locale)))" } ?? String(localized: "按日期筛选"))
            .accessibilityLabel("日期筛选：\(dateFilterLabel)")
            .popover(isPresented: $showDateFilter, arrowEdge: .bottom) { dateFilterEditor }
            Picker("触发事件", selection: $model.captureFilter.event) {
                ForEach(CaptureFilter.Event.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden().frame(width: 100, alignment: .trailing).help("按触发事件筛选").accessibilityLabel("触发事件筛选")
            if model.captureFilter.isActive {
                Button { model.captureFilter = CaptureFilter() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).help("清除筛选").accessibilityLabel("清除筛选")
            }
        }
    }

    private var dateFilterLabel: String {
        guard let range = model.captureFilter.dateRange else { return String(localized: "全部日期") }
        let format: Date.FormatStyle = Calendar.current.isDate(range.lowerBound, equalTo: range.upperBound, toGranularity: .year)
            ? .dateTime.month().day() : .dateTime.year().month().day()
        let start = range.lowerBound.formatted(format.locale(locale))
        return Calendar.current.isDate(range.lowerBound, inSameDayAs: range.upperBound) ? start : "\(start) – \(range.upperBound.formatted(format.locale(locale)))"
    }

    private var dateFilterEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("日期范围").font(.headline)
            DatePicker("开始日期", selection: $startDate, in: ...endDate, displayedComponents: .date)
            DatePicker("结束日期", selection: $endDate, in: startDate..., displayedComponents: .date)
            HStack {
                Button("全部日期") { model.captureFilter.dateRange = nil; showDateFilter = false }
                Spacer()
                // "确定" rather than "应用": the same word labels the app filter above, and one catalog key cannot mean both.
                Button("确定") { model.captureFilter.dateRange = startDate...endDate; showDateFilter = false }
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 300)
    }
}

private struct CaptureThumbnail: View {
    let capture: ClipCapture
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Label(String(localized: "图片已过期"), systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: capture.imageID) { image = NSImage(contentsOf: capture.imageURL) }
        .accessibilityLabel("\(capture.appName) 的窗口截图")
    }
}

struct CaptureDetailView: View {
    @ObservedObject var model: MyClipModel
    /// Newest first; a single element for an unfolded capture.
    let frames: [ClipCapture]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var showText = false
    @State private var extractedText: String?
    @State private var textError: String?
    @State private var recognizing = false

    init(model: MyClipModel, frames: [ClipCapture]) {
        self.model = model
        self.frames = frames
    }

    init(model: MyClipModel, capture: ClipCapture) { self.init(model: model, frames: [capture]) }

    private var capture: ClipCapture { frames[min(index, frames.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(capture.appName).font(.title2.bold())
                    Text(capture.windowTitle).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if frames.count > 1 {
                    HStack(spacing: 6) {
                        Button { index = min(frames.count - 1, index + 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(index >= frames.count - 1).help("更早一次").keyboardShortcut(.leftArrow, modifiers: [])
                        Text("第 \(frames.count - index) / \(frames.count) 次").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(index == 0).help("更晚一次").keyboardShortcut(.rightArrow, modifiers: [])
                    }.buttonStyle(.borderless)
                }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if frames.count > 1 { frameStrip }
            if !model.library.entries.filter({ $0.sourceIDs.contains(capture.id) }).isEmpty {
                HStack {
                    Text("关联记忆").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.library.entries.filter { $0.sourceIDs.contains(capture.id) }) { entry in
                        Button(entry.title) { dismiss(); model.open(.memory); Task { @MainActor in model.selectedEntry = entry.id } }.buttonStyle(.borderless)
                    }
                }
            }
            Picker("截图附件", selection: $showText) {
                Text("截图").tag(false)
                Text("OCR 文档").tag(true)
            }.pickerStyle(.segmented).frame(width: 220)
            if showText {
                textDocument
            } else {
                CaptureThumbnail(capture: capture).frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(capture.date, format: .dateTime.year().month().day().hour().minute().second())
                    HStack(spacing: 5) {
                        Text("\(capture.width) × \(capture.height) ·")
                        Label(capture.reason.label, systemImage: capture.reason.systemImage)
                    }.foregroundStyle(.secondary)
                }.font(.caption)
                Spacer()
                Button(String(localized: "显示原图"), systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([capture.imageURL]) }
                    .disabled(!FileManager.default.fileExists(atPath: capture.imageURL.path))
                Button("按图片重新整理") { model.enqueue(capture); dismiss() }
                    .help("将原图交给 Agent，适合图表、布局等 OCR 无法保留的内容")
                    .disabled(!model.canStartOrganization || !FileManager.default.fileExists(atPath: capture.imageURL.path))
                    .help(model.preferences.enabledAgent.map { String(localized: "使用已启用的 \($0.name) 整理") } ?? String(localized: "请先连接并启用 Agent"))
            }
        }.padding(24).frame(minWidth: 640, idealWidth: 840, maxWidth: 1000, minHeight: 500, idealHeight: 680, maxHeight: 800)
        .task(id: capture.imageID) { await recognizeText() }
    }

    /// Every look at the window, oldest on the left.
    private var frameStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(frames.enumerated().reversed()), id: \.element.id) { position, frame in
                        Button { index = position } label: {
                            VStack(spacing: 4) {
                                CaptureThumbnail(capture: frame).frame(width: 96, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(position == index ? Color.accentColor : .clear, lineWidth: 2))
                                Text(frame.date, format: .dateTime.hour().minute().second()).font(.caption2).monospacedDigit()
                                    .foregroundStyle(position == index ? .primary : .secondary)
                            }
                        }.buttonStyle(.plain).id(frame.id)
                            .help(position + 1 < frames.count && frame.imageID == frames[position + 1].imageID ? String(localized: "与前一次画面相同") : frame.reason.label)
                    }
                }.padding(.vertical, 2)
            }
            .onChange(of: index) { proxy.scrollTo(frames[$0].id) }
            .onAppear { proxy.scrollTo(frames[index].id) }
        }.frame(height: 84)
    }

    private var textDocument: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(String(localized: "提取的文字"), systemImage: "doc.text").font(.headline)
                Spacer()
                Button(String(localized: "复制文字"), systemImage: "doc.on.doc") {
                    guard let extractedText else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(extractedText, forType: .string)
                }.disabled(extractedText?.isEmpty != false)
                Button(String(localized: "打开文档"), systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(capture.textURL) }
                    .disabled(extractedText == nil)
            }
            Divider()
            if recognizing {
                ProgressView("正在提取文字…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let textError {
                VStack(spacing: 12) {
                    Text(textError).foregroundStyle(.secondary)
                    Button("重试") { Task { await recognizeText() } }
                        .disabled(!FileManager.default.fileExists(atPath: capture.imageURL.path))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let extractedText, !extractedText.isEmpty {
                ScrollView {
                    Text(verbatim: extractedText).font(.system(size: 14)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                LibraryUnavailableView(String(localized: "未识别到文字"), systemImage: "doc.text", description: Text("已为这张截图保存空白文档。"))
            }
            Text("文字在本机提取，与原图一同保存和到期清理。").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func recognizeText() async {
        recognizing = true
        textError = nil
        extractedText = nil
        defer { recognizing = false }
        do { extractedText = try await model.store.recognizeImageText(id: capture.imageID) }
        catch is CancellationError { return }
        catch { textError = error.localizedDescription }
    }
}

struct PermissionRequestView: View {
    @ObservedObject var model: MyClipModel
    let permission: ClipPermission
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "\(permission.agent.name) 需要确认"), systemImage: "hand.raised").font(.headline)
            Text(permission.request.title).font(.subheadline)
            ForEach(permission.request.options) { option in
                Button(option.name) { model.resolve(permission, optionID: option.id) }.focusable()
                    .onActivationKey { model.resolve(permission, optionID: option.id) }
            }
            Button("取消此次请求", role: .cancel) { model.resolve(permission, optionID: nil) }.buttonStyle(.borderless).focusable()
                .onActivationKey { model.resolve(permission, optionID: nil) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CaptureOnboardingView: View {
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

private struct LibraryEmptyView: View {
    let symbol: String
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void
    var body: some View {
        VStack(spacing: 17) {
            Image(systemName: symbol).font(.system(size: 54, weight: .ultraLight)).foregroundStyle(.blue).padding(.bottom, 8)
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5).frame(maxWidth: 360)
            Button(action, action: perform).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 5)
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

