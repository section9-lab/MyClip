import SwiftUI
import AppKit
import MyClipCore

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

struct KnowledgeLibraryView: View {
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

struct MemoryFileNode: Identifiable {
    let id: String
    let entry: KnowledgeEntry?
    let children: [MemoryFileNode]?
    var name: String { String(id.split(separator: "/").last ?? "") }
    fileprivate var selection: MemoryFileSelection { entry.map { .entry($0.id) } ?? .folder(id) }

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
