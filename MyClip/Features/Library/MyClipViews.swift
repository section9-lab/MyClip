import SwiftUI
import AppKit
import Charts
import MyClipCore

struct MyClipRootView: View {
    @ObservedObject var model: MyClipModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if model.showPermissions { CaptureOnboardingView(model: model) }
            else { libraryContent }
        }
        .alert("MyClip", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("好", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .frame(minWidth: 840, minHeight: 580)
        .onReceive(NotificationCenter.default.publisher(for: .init("MyClipFocusSearch"))) { _ in
            if !model.showPermissions { searchFocused = true }
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
                        ForEach(ClipAgent.allCases) { agent in
                            Button { model.open(.agents) } label: {
                                AgentStatusIcon(agent: agent, state: model.state(agent))
                            }.buttonStyle(.plain).help("\(agent.name) · \(model.state(agent).detail)")
                        }
                        Spacer()
                        Button { model.open(.settings) } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("设置")
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
                case .agents: AgentLibraryView(model: model)
                case .settings: MyClipSettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(model.page == .dashboard ? "" : model.page?.title ?? "MyClip")
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
        case "Memory.md": "记忆概览"
        case "Profile.md": "关于我"
        case "Now.md": "当前关注"
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
            Button("Memory 根目录", systemImage: "folder") {
                model.search = ""; model.selectedEntry = nil; model.memoryFolder = ""
            }
            Button("在 Finder 中打开", systemImage: "arrow.up.forward.square") {
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
                        ForEach(model.proposals) { item in Button(item.drafts.first?.title ?? "修改建议") { proposal = item } }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                }.padding(.horizontal, 32).padding(.vertical, 12)
                Divider()
            }
            if let entry = selected {
                KnowledgeDetailView(model: model, entry: entry).id(entry.id)
            } else if !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MemoryCollectionView(model: model, title: "搜索结果", entries: model.results.entries)
            } else if let folder = model.memoryFolder {
                MemoryFolderView(model: model, path: folder)
            } else {
                LibraryUnavailableView("选择一篇记忆", systemImage: "doc.text", description: Text("从边栏选择记忆，查看内容与来源。"))
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
                        Label("上一级", systemImage: "chevron.left")
                    }.buttonStyle(.borderless)
                }
                Text(MemoryPresentation.folder(path)).font(.system(size: 30, weight: .bold))
                let items = MemoryFileNode.tree(model.library, at: path)
                if items.isEmpty {
                    LibraryUnavailableView("文件夹为空", systemImage: "folder", description: Text("记忆保存到这里后，会显示在目录中。"))
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
                        Text(model.search.isEmpty ? "这里还没有记忆" : "没有找到相关记忆").font(.title3.weight(.semibold))
                        Text(model.search.isEmpty ? "截图整理后，相关内容会出现在这里。" : "试试其他关键词，或从边栏浏览已有内容。")
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
            Button("返回文件夹", systemImage: "chevron.left") {
                model.search = ""
                model.selectedEntry = nil
                model.memoryFolder = entry.relativePath.split(separator: "/").dropLast().joined(separator: "/")
            }
            Button("编辑 Markdown", systemImage: "square.and.pencil") { editing = true }
            ShareLink(item: entry.fileURL) { Label("导出 Markdown", systemImage: "square.and.arrow.up") }
            Button("文件信息", systemImage: "info.circle") { showingInfo = true }
            Divider()
            Button("显示 Markdown 文件", systemImage: "doc.text") { NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL]) }
            Button("打开 Memory 文件夹", systemImage: "folder") { NSWorkspace.shared.open(model.store.root.appendingPathComponent("Memory")) }
            Divider()
            Button("移动或重命名…", systemImage: "folder") { moving = true }.disabled(entry.isRootDocument)
            Button("删除条目", systemImage: "trash", role: .destructive) { deleting = true }.disabled(entry.isRootDocument)
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
            if !entry.contextSourceIDs.isEmpty { LabeledContent("整理时参考", value: "\(entry.contextSourceIDs.count) 张截图；具体依据见正文引用") }
            LabeledContent("版本", value: "第 \(entry.revision) 版")
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

private struct CaptureLibraryView: View {
    @ObservedObject var model: MyClipModel
    @Environment(\.locale) private var locale
    @State private var source: ClipCapture?
    @State private var showDateFilter = false
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var endDate = Calendar.current.startOfDay(for: Date())
    var captures: [ClipCapture] { model.results.captures }
    var days: [Date] { Array(Set(captures.map { Calendar.current.startOfDay(for: $0.date) })).sorted(by: >) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                pageHeading(LibraryPage.captures.title, subtitle: "记录工作画面，随时回到信息的来源。")
                HStack(spacing: 10) {
                    Image(systemName: model.capturing ? "record.circle" : "pause.circle").foregroundStyle(model.capturing ? .green : .secondary)
                    Text(model.captureStatus).font(.subheadline)
                    Spacer()
                    Text(model.preferences.captureSettings.scope.label).font(.caption).foregroundStyle(.secondary)
                }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                ViewThatFits(in: .horizontal) {
                    HStack { resultSummary; Spacer(minLength: 20); filterControls }
                    VStack(alignment: .leading, spacing: 12) {
                        filterControls.frame(maxWidth: .infinity, alignment: .trailing)
                        resultSummary
                    }
                }
                if captures.isEmpty {
                    if model.captureFilter.isActive {
                        LibraryEmptyView(symbol: "line.3.horizontal.decrease", title: "没有符合条件的截图", detail: "试试其他应用、日期或触发事件，或清除筛选条件。", action: "清除筛选") { model.captureFilter = CaptureFilter() }
                    } else if !model.search.isEmpty {
                        LibraryEmptyView(symbol: "magnifyingglass", title: "没有找到相关截图", detail: "试试其他关键词，或清除搜索查看全部截图。", action: "清除搜索") { model.search = "" }
                    } else {
                        LibraryEmptyView(symbol: model.capturing ? "record.circle" : "macwindow", title: model.capturing ? "等待第一张截图" : "等待自动采集", detail: model.preferences.captureSettings.description, action: "查看采集设置") { model.open(.settings) }
                    }
                } else {
                    ForEach(days, id: \.self) { day in
                        Text(day, format: .dateTime.year().month().day().weekday()).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 20)], alignment: .leading, spacing: 26) {
                        ForEach(captures.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }) { capture in
                            Button { source = capture } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    CaptureThumbnail(capture: capture).frame(height: 166).clipShape(RoundedRectangle(cornerRadius: 12))
                                    HStack {
                                        Text(capture.appName).font(.headline)
                                        Spacer()
                                        Text(capture.date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(capture.windowTitle.isEmpty ? "未命名窗口" : capture.windowTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    HStack {
                                        Text(capture.date, format: .dateTime.month().day()).font(.caption2).foregroundStyle(.tertiary)
                                        Spacer()
                                        Label(capture.reason.label, systemImage: capture.reason.systemImage)
                                            .labelStyle(.iconOnly).font(.caption).foregroundStyle(.secondary)
                                            .help(capture.reason.label)
                                    }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    }
                }
            }.padding(36).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
        .sheet(item: $source) { CaptureDetailView(model: model, capture: $0) }
    }

    private var resultSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.search.isEmpty && !model.captureFilter.isActive ? "\(model.library.imageCount) 张独立图片" : "\(model.results.captureCount) 条结果")
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
            .help(model.captureFilter.dateRange.map { "\($0.lowerBound.formatted(.dateTime.year().month().day().locale(locale))) – \($0.upperBound.formatted(.dateTime.year().month().day().locale(locale)))" } ?? "按日期筛选")
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
        guard let range = model.captureFilter.dateRange else { return "全部日期" }
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
                Button("应用") { model.captureFilter.dateRange = startDate...endDate; showDateFilter = false }
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
            else { Label("图片已过期", systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: capture.imageID) { image = NSImage(contentsOf: capture.imageURL) }
        .accessibilityLabel("\(capture.appName) 的窗口截图")
    }
}

struct CaptureDetailView: View {
    @ObservedObject var model: MyClipModel
    let capture: ClipCapture
    @Environment(\.dismiss) private var dismiss
    @State private var showText = false
    @State private var extractedText: String?
    @State private var textError: String?
    @State private var recognizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(capture.appName).font(.title2.bold())
                    Text(capture.windowTitle).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
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
                Button("显示原图", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([capture.imageURL]) }
                    .disabled(!FileManager.default.fileExists(atPath: capture.imageURL.path))
                Button("按图片重新整理") { model.enqueue(capture); dismiss() }
                    .help("将原图交给 Agent，适合图表、布局等 OCR 无法保留的内容")
                    .disabled(!model.canStartOrganization || !FileManager.default.fileExists(atPath: capture.imageURL.path))
                    .help(model.preferences.enabledAgent.map { "使用已启用的 \($0.name) 整理" } ?? "请先连接并启用 Agent")
            }
        }.padding(24).frame(minWidth: 640, idealWidth: 840, maxWidth: 1000, minHeight: 500, idealHeight: 680, maxHeight: 800)
        .task(id: capture.imageID) { await recognizeText() }
    }

    private var textDocument: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("提取的文字", systemImage: "doc.text").font(.headline)
                Spacer()
                Button("复制文字", systemImage: "doc.on.doc") {
                    guard let extractedText else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(extractedText, forType: .string)
                }.disabled(extractedText?.isEmpty != false)
                Button("打开文档", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(capture.textURL) }
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
                LibraryUnavailableView("未识别到文字", systemImage: "doc.text", description: Text("已为这张截图保存空白文档。"))
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

private struct AgentLibraryView: View {
    @ObservedObject var model: MyClipModel
    @State private var selectedJob: ClipJob?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                pageHeading("熟悉的 Agent，接着工作。", subtitle: "连接并启用一个 Agent，以 Full 权限自动整理，无需逐次授权。")
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(ClipAgent.allCases) { agent in agentCard(agent) }
                        claudeDesktopCard
                        comingSoonCard("Cursor", symbol: "cursorarrow")
                        comingSoonCard("OpenCode", symbol: "terminal")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .fillingHorizontalViewport(minWidth: 5 * 190 + 4 * 16)
                }
                ForEach(model.permissions) { permission in PermissionRequestView(model: model, permission: permission) }
                tokenUsageSection
                HStack {
                    Text("整理任务").font(.title2.bold())
                    Spacer()
                    Button("立即整理", action: model.organizeNow).disabled(!model.canOrganizeNow)
                    Button(model.processingPaused ? "继续队列" : "暂停队列", systemImage: model.processingPaused ? "play" : "pause") { model.processingPaused.toggle() }.buttonStyle(.borderless)
                }.padding(.top, 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(model.organizationStatus(at: context.date)).foregroundStyle(.secondary)
                }
                Text((model.preferences.enabledAgent.map { "当前启用 \($0.name)，切换后对等待中的截图生效；当前批次会先完成。" }
                    ?? "尚未启用 Agent。截图会继续保存，连接并启用后开始整理。")
                    + "\n按时间顺序，每批最多 8 张图片和 32 条 OCR 文本，文本合计最多 12,000 字符。自动整理间隔至少 3 分钟。"
                    + "\n回车和手动截图使用图片；鼠标事件优先使用 OCR，文字不可用或过长时使用原图。每批独立整理，详情保存在执行记录中。"
                    + "\n连续 5 分钟无新进度会停止等待；单批最长 15 分钟。")
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = model.library.queue.pauseReason {
                    Label(reason, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if model.library.jobs.isEmpty {
                    Text(model.library.queue.pendingCount > 0 ? "截图已保存，开始整理后会在这里显示进度。" : "截图开始后，整理进度会出现在这里。")
                        .foregroundStyle(.secondary).padding(.vertical, 20)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.library.jobs.prefix(30)) { job in
                            HStack(alignment: .top, spacing: 13) {
                                Button { selectedJob = job } label: {
                                    HStack(alignment: .top, spacing: 13) {
                                        AgentBrandIcon(agent: job.agent, size: 30)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("\(job.sourceIDs.count) 条记录 · \(jobLabel(job.state))").font(.subheadline.weight(.medium))
                                            if let error = job.error { Text(error).font(.caption).foregroundStyle(.orange) }
                                            else if job.state == .running {
                                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                                    Text(model.organizationActivity(at: context.date)).font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                            if let usage = model.tokenUsage.jobs[job.id] {
                                                Text("Token \(tokenCount(usage.totalTokens)) · \(usageDetails(usage))")
                                                    .font(.caption).foregroundStyle(.secondary)
                                                if usage.calls > usage.reportedCalls {
                                                    Text("\(usage.calls - usage.reportedCalls) 次请求未回传用量")
                                                        .font(.caption).foregroundStyle(.secondary)
                                                }
                                            } else {
                                                Text(job.state == .running ? "Token：等待本次回传" : "Token：未记录")
                                                    .font(.caption).foregroundStyle(.tertiary)
                                            }
                                            Text(job.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).help("查看执行记录、工具调用与费用")
                                    .accessibilityLabel("查看 \(job.sourceIDs.count) 条记录的执行详情，\(jobLabel(job.state))")
                                if job.state == .failed || job.state == .cancelled {
                                    Button("重试") { model.retry(job) }.disabled(!model.canRetry(job))
                                        .help("请先连接并启用 \(job.agent.name)，重试会继续使用原 Agent")
                                }
                                if job.state == .running || job.state == .queued { Button("取消") { model.cancel(job) } }
                            }.padding(.vertical, 16).overlay(alignment: .bottom) { Divider().padding(.leading, 43) }
                        }
                    }
                }
            }.padding(36).frame(maxWidth: 950).frame(maxWidth: .infinity)
        }
        .sheet(item: $selectedJob) { ExecutionDetailView(model: model, job: $0) }
    }

    private var tokenUsageSection: some View {
        let usage = model.tokenUsage.total
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Token 用量").font(.title2.bold())
                Spacer()
                Text("累计已记录").font(.caption).foregroundStyle(.secondary)
                Text(tokenCount(usage.totalTokens)).font(.title2.monospacedDigit().bold())
            }
            Text(usageDetails(usage)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 28) {
                ForEach(ClipAgent.allCases) { agent in
                    HStack(spacing: 8) {
                        AgentBrandIcon(agent: agent, size: 20)
                        Text(agent.name)
                        Text(tokenCount(model.tokenUsage.agents[agent]?.totalTokens)).monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                Text("\(usage.reportedCalls) / \(usage.calls) 次请求已回传").foregroundStyle(.secondary)
            }.font(.caption)
            Text("含截图整理、任务识别和重试；按 Agent 回传统计，任务结束后更新。旧任务和未回传的用量不计入。缓存明细为已回传部分。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tokenCount(_ value: Int?) -> String { value?.formatted() ?? "未记录" }

    private func usageDetails(_ usage: TokenUsageSummary) -> String {
        "输入 \(tokenCount(usage.inputTokens)) · 输出 \(tokenCount(usage.outputTokens)) · 缓存读取 \(tokenCount(usage.cachedReadTokens)) · 缓存写入 \(tokenCount(usage.cachedWriteTokens))"
    }

    private func agentCard(_ agent: ClipAgent) -> some View {
        let state = model.state(agent)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                AgentBrandIcon(agent: agent, size: 44)
                Spacer(minLength: 0)
                if model.preferences.enabledAgent == agent {
                    Text("已启用").font(.caption).foregroundStyle(.blue).padding(.horizontal, 7).padding(.vertical, 3).background(.blue.opacity(0.08), in: Capsule())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(agent == .codex ? "Codex / ChatGPT" : "Claude Code（命令行）").font(.headline)
                Text(state.detail).font(.caption).foregroundStyle(state.phase == .failed ? .orange : .secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Full 权限 · 自动授权", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("默认允许 Agent 读取和修改文件、运行工具及访问网络，无需逐次确认。")
            }
            Text(agent == .codex ? "使用 Codex 的现有登录" : "使用 Claude Code 的现有登录和网络设置")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if agent == .claude, model.isInstalled(agent) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("首次使用时，先完成 Claude Code 登录。").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("复制登录命令") { model.copyClaudeLoginCommand() }.buttonStyle(.borderless)
                }.font(.caption)
            }
            if !state.available && !state.authMethods.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("登录方式").font(.caption).foregroundStyle(.secondary)
                    ForEach(state.authMethods) { method in
                        Button(method.name) { model.authenticate(agent, method: method) }.disabled(state.busy)
                    }
                }.controlSize(.small)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if state.busy { ProgressView().controlSize(.small) }
                else if !state.available && !model.isInstalled(agent) {
                    Button("安装连接组件") { model.install(agent) }.buttonStyle(.borderedProminent).disabled(model.preview || model.agents.values.contains(where: { $0.phase == .installing }))
                } else {
                    Button(state.available ? "已就绪" : "连接") { model.connect(agent) }.disabled(state.available || model.preview)
                }
                Spacer(minLength: 0)
                if model.preferences.enabledAgent == agent {
                    Button("停用") { model.disableAgent() }.buttonStyle(.borderless).disabled(model.preview)
                        .help("停止分配新任务，当前任务会继续完成")
                } else {
                    Button("启用") { model.enable(agent) }.buttonStyle(.borderedProminent)
                        .disabled(model.preview || !state.available)
                        .help(state.available ? "将后续任务切换到 \(agent.name)" : "请先连接，确认 Agent 可用")
                }
            }.controlSize(.small)
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(agent == .codex ? "Codex / ChatGPT" : "Claude Code（命令行）")
    }

    private var claudeDesktopCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            AgentBrandIcon(agent: .claude, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude Desktop").font(.headline)
                Text("桌面端 · MCP 记忆访问").font(.caption).foregroundStyle(.secondary)
            }
            Text("在 Chat 和本地 Code 会话中搜索、阅读 MyClip 记忆。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("后台自动整理请启用 Claude Code（命令行）。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("打开应用", systemImage: "arrow.up.right.square", action: model.openClaudeDesktop)
                .buttonStyle(.borderless).disabled(model.preview)
                .help("打开 Claude Desktop")
            Button("配置 MCP") {
                model.preferences.mcpClients.insert(.claudeDesktop)
                model.open(.settings)
            }.controlSize(.small)
                .help("在设置中配置 Claude Desktop 的 MyClip 记忆访问")
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude Desktop（桌面端）")
    }

    private func comingSoonCard(_ name: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 28, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.headline)
                Text("Coming soon").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct PermissionRequestView: View {
    @ObservedObject var model: MyClipModel
    let permission: ClipPermission
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(permission.agent.name) 需要确认", systemImage: "hand.raised").font(.headline)
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

private struct MyClipSettingsView: View {
    @ObservedObject var model: MyClipModel
    @State private var showMCPHelp = false
    var body: some View {
        @ObservedObject var preferences = model.preferences
        Form {
            Section {
                Picker("采集范围", selection: $preferences.captureSettings.scope) {
                    ForEach(CaptureScope.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("鼠标触发") {
                    Menu {
                        ForEach(MouseCaptureTrigger.allCases) { option in
                            Toggle(option.label, isOn: Binding(get: { preferences.captureSettings.mouseTriggers.contains(option) }, set: { selected in
                                if selected { preferences.captureSettings.mouseTriggers.insert(option) }
                                else { preferences.captureSettings.mouseTriggers.remove(option) }
                            }))
                        }
                    } label: { Text(preferences.captureSettings.mouseSummary) }
                        .fixedSize()
                        .accessibilityLabel("鼠标触发")
                        .accessibilityValue(preferences.captureSettings.mouseSummary)
                }
                Picker("键盘触发", selection: $preferences.captureSettings.keyboard) {
                    ForEach(KeyboardCaptureMode.allCases) { Text($0.label).tag($0) }
                }
            } header: { Text("截图") } footer: {
                Text("应用打开后自动采集，退出应用后停止。全屏仅记录焦点窗口所在的显示器。鼠标两项可独立勾选；键盘忽略长按回车。MyClip、锁屏和排除的应用不会被记录。")
            }
            .onChange(of: preferences.captureSettings) { _ in model.applyCaptureSettings() }
            Section("排除应用") {
                TextEditor(text: $preferences.excludedApps).font(.system(.caption, design: .monospaced)).frame(height: 78)
                    .onChange(of: preferences.excludedApps) { _ in model.applyCaptureSettings() }
                Text("每行一个应用的 Bundle ID。").font(.caption).foregroundStyle(.secondary)
                Menu("添加正在运行的应用") {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier!) {
                            let id = app.bundleIdentifier!
                            if !preferences.excludedApps.components(separatedBy: "\n").contains(id) { preferences.excludedApps += "\n" + id }
                        }
                    }
                }
            }
            Section {
                Toggle("自动整理新截图", isOn: $preferences.autoOrganize)
                LabeledContent("已启用 Agent", value: preferences.enabledAgent?.name ?? "未启用")
            } header: { Text("记忆整理") }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("启用 MyClip MCP 服务").font(.headline)
                        Button { showMCPHelp = true } label: {
                            Label("如何让 Agent 使用记忆？", systemImage: "questionmark.circle").font(.caption)
                        }.buttonStyle(.borderless)
                            .popover(isPresented: $showMCPHelp, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("让 Agent 读取你的 Memory").font(.headline)
                                    Text("选择你使用的 Agent，再点击“一键开启”。完成后重启客户端或新建会话，就可以让它搜索和阅读 MyClip 里的记忆。")
                                    Text("例如：请通过 MyClip 查找我最近的项目记录。")
                                    Text("关闭开关后，MCP 记忆查询会立即暂停；再次开启即可恢复。").foregroundStyle(.secondary)
                                }.font(.callout).padding(20).frame(width: 340)
                            }
                    }.padding(.vertical, 4)
                    Spacer()
                    Toggle("启用 MyClip MCP 服务", isOn: Binding(get: { model.mcpEnabled }, set: { model.setMCPEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }.disabled(model.configuringMCP)
                HStack {
                    Text("使用记忆的 Agent")
                    Spacer()
                    Menu {
                        ForEach(MCPClient.allCases) { client in
                            Toggle(isOn: Binding(get: { preferences.mcpClients.contains(client) }, set: { selected in
                                if selected { preferences.mcpClients.insert(client) }
                                else { preferences.mcpClients.remove(client) }
                            })) { mcpClientLabel(client) }
                        }
                    } label: {
                        Text(preferences.mcpClients.isEmpty ? "选择 Agent" : "已选择 \(preferences.mcpClients.count) 个 Agent")
                    }.fixedSize()
                        .accessibilityLabel("选择使用 Memory 的 Agent")
                        .accessibilityValue(MCPClient.allCases.filter { preferences.mcpClients.contains($0) }.map(\.name).joined(separator: "、"))
                    if model.configuringMCP { ProgressView().controlSize(.small) }
                    Button(model.configuringMCP ? "正在开启…" : "一键开启") { model.configureMCP() }
                        .buttonStyle(.borderedProminent)
                        .disabled(preferences.mcpClients.isEmpty || model.preview)
                        .help(model.preview ? "预览模式不写入客户端配置" : "为所选 Agent 配置 MyClip 记忆访问")
                }.disabled(!model.mcpEnabled || model.configuringMCP)
                ForEach(MCPClient.allCases.filter { preferences.mcpClients.contains($0) }) { client in
                    if let result = model.mcpSetupResults[client] {
                        switch result {
                        case .configured:
                            LabeledContent(client.name) {
                                Label(model.mcpEnabled ? "已配置" : "已配置 · 访问已暂停", systemImage: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                        case .failed(let message):
                            VStack(alignment: .leading, spacing: 5) {
                                Label("\(client.name) 配置失败", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if preferences.mcpClients.contains(.claudeDesktop) {
                    Text("Claude Desktop 配置完成后，请完全退出并重新打开应用，在 Chat 或本地 Code 会话中使用 MyClip 记忆。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("MCP 已完成的查询", value: model.statistics.mcpReads.formatted())
            } header: { Text("MCP 记忆访问") } footer: {
                Text(model.mcpEnabled ? "配置完成后，请重启客户端或新建会话。Agent 实际读取 Memory 后，查询次数才会增加。" : "MCP 已关闭，Agent 暂时无法通过 MCP 读取 Memory。已保存的连接配置会保留。")
            }
            Section("存储") {
                Picker("原始截图保留", selection: $preferences.retentionDays) {
                    Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90); Text("一直保留").tag(0)
                }
                LabeledContent("位置") { Button("打开本地资料库", systemImage: "folder") { NSWorkspace.shared.open(model.store.root) } }
                Button("重建搜索索引", systemImage: "arrow.clockwise") { model.rebuildIndex() }
                Text("Memory 和来源信息独立保存。原图和识别文本过期后，记忆仍然可用；等待整理的截图会继续保留。").font(.caption).foregroundStyle(.secondary)
            }
            Section("关于 MyClip") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("截图，成为记忆。").font(.headline)
                    Text("MyClip 根据你的操作自动截图，并交给已启用的 Agent 整理成可搜索的记忆。随时回顾工作内容，追溯信息来源。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 4)
                LabeledContent("版本", value: appVersion)
                Button("退出 MyClip", systemImage: "power") { NSApp.terminate(nil) }
            }
        }.formStyle(.grouped).frame(maxWidth: 850).frame(maxWidth: .infinity)
    }

    private func mcpClientLabel(_ client: MCPClient) -> some View {
        Label {
            Text(client.name)
        } icon: {
            switch client {
            case .codex: Image("CodexIcon").resizable().scaledToFit().frame(width: 16, height: 16)
            case .claudeCode, .claudeDesktop: Image("ClaudeIcon").resizable().scaledToFit().frame(width: 16, height: 16)
            case .cursor: Image(systemName: "cube.fill")
            case .openCode: Image(systemName: "terminal")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

private struct CaptureOnboardingView: View {
    @ObservedObject var model: MyClipModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "macwindow").font(.system(size: 42, weight: .light)).foregroundStyle(.blue)
                Text("欢迎使用 MyClip").font(.largeTitle.bold())
                Text("截图，成为记忆。完成权限设置，开始记录工作画面。").font(.subheadline)
                Text(model.preferences.captureSettings.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("需要允许以下两项权限才能使用 MyClip。全部授权后会自动进入应用并开始采集。").font(.subheadline)
                permission("屏幕录制", detail: "读取\(model.preferences.captureSettings.scope.label)的画面", allowed: model.screenPermission, action: model.requestScreenPermission)
                permission("辅助功能", detail: "识别焦点窗口和回车按键", allowed: model.accessibilityPermission, action: model.requestAccessibilityPermission)
                if !model.screenPermission {
                    Text("请在系统设置的“隐私与安全 → 录屏与系统录音”中开启 MyClip。如果开关已开启但此处仍未通过，请退出并重新打开 MyClip。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.preferences.autoOrganize {
                    Text(model.preferences.enabledAgent.map { "自动整理已开启：新截图会交给 \($0.name) 处理。你可以在设置中关闭。" }
                        ?? "自动整理已开启：新截图先进入等待队列，连接并启用 Agent 后开始整理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("退出 MyClip") { NSApp.terminate(nil) }
                    Spacer()
                    Button("刷新权限状态") { model.refreshPermissions() }.buttonStyle(.borderedProminent)
                }
            }.padding(36).frame(maxWidth: 580).frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }

    private func permission(_ title: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if allowed { Label("已允许", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else { Button("允许", action: action).accessibilityLabel("允许\(title)") }
        }.padding(15).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
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

private func pageHeading(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.5)
        Text(subtitle).font(.body).foregroundStyle(.secondary).lineSpacing(4)
    }.frame(maxWidth: .infinity, alignment: .leading)
}

private func jobLabel(_ state: ClipJobState) -> String {
    switch state {
    case .queued: "等待整理"
    case .running: "整理中"
    case .completed: "已完成"
    case .failed: "未完成"
    case .cancelled: "已取消"
    }
}
