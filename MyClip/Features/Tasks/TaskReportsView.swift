import SwiftUI
import MyClipCore

struct TaskReportsView: View {
    @ObservedObject var model: MyClipModel
    let openTask: (UUID) -> Void
    @State private var period = WorkTaskReportPeriod.day
    @State private var date = Date()
    @State private var copied = false
    @State private var sharing = false
    @State private var savedDocument: WorkTaskReportDocument?
    @State private var editingDocument: WorkTaskReportDocument?
    @State private var loading = true
    @State private var loadError: String?
    @State private var showingSources = false
    @State private var selectedSource: UUID?

    private var report: WorkTaskReport {
        WorkTaskReport(period: period, containing: date, tasks: model.workTasks, events: model.workTaskEvents)
    }
    private var document: WorkTaskReportDocument {
        savedDocument?.id == report.document.id ? savedDocument! : report.document
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { periodPicker; dateControls; Spacer(minLength: 0); actions }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { periodPicker; Spacer(minLength: 20); actions }
                        dateControls
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 18).frame(maxWidth: 1200)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label(savedDocument?.id == document.id ? String(localized: "已保存草稿") : String(localized: "草稿"), systemImage: "doc.badge.ellipsis")
                            Spacer()
                            Button(String(localized: "参考任务"), systemImage: "sidebar.right") { showingSources = true }
                                .buttonStyle(.plain).disabled(document.taskIDs.isEmpty || loading)
                        }.font(.callout).foregroundStyle(.secondary)
                        if loading {
                            ProgressView("正在读取报告…").frame(maxWidth: .infinity).padding(60)
                        } else if let loadError {
                            VStack(spacing: 12) {
                                Text("无法读取已保存的报告").font(.headline)
                                Text(loadError).font(.callout).foregroundStyle(.secondary)
                                Button("重试") { Task { await loadDocument() } }
                            }.frame(maxWidth: .infinity).padding(40)
                        } else {
                            ReportPaper(document: .constant(document), compact: geometry.size.width < 700)
                        }
                    }
                    .padding(geometry.size.width < 700 ? 20 : 32).frame(maxWidth: 1060).frame(maxWidth: .infinity)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
        .task(id: report.document.id) { await loadDocument() }
        .onChange(of: document.markdown) { _ in copied = false }
        .sheet(item: $editingDocument) { document in
            ReportEditor(store: model.store, document: document) { savedDocument = $0 }
        }
        .sheet(isPresented: $showingSources, onDismiss: {
            if let selectedSource { openTask(selectedSource); self.selectedSource = nil }
        }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("参考任务").font(.title2.weight(.semibold))
                    Spacer()
                    Button("关闭") { showingSources = false }.keyboardShortcut(.cancelAction)
                }
                Text("查看任务详情、来源依据与状态记录。任务详情显示当前进度。")
                    .font(.callout).foregroundStyle(.secondary)
                List(model.workTasks.filter { document.taskIDs.contains($0.id) }) { task in
                    Button {
                        selectedSource = task.id
                        showingSources = false
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            ReportStatusIcon(status: task.status)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(task.title).foregroundStyle(.primary)
                                Text("\(task.projectTitle) · \(task.status.title)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.inset)
            }.padding(24).frame(width: 620, height: 470)
        }
    }

    private var periodPicker: some View {
        Picker("报告周期", selection: $period) {
            ForEach(WorkTaskReportPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(String(localized: "编辑"), systemImage: "square.and.pencil") { editingDocument = document }
                .disabled(loading || loadError != nil || document.taskIDs.isEmpty)
            Button(String(localized: "分享"), systemImage: "square.and.arrow.up") { sharing = true }
                .disabled(loading || loadError != nil || document.taskIDs.isEmpty)
                .popover(isPresented: $sharing, arrowEdge: .bottom) {
                    ReportSharePanel(document: document) { sharing = false }
                }
            Button(copied ? String(localized: "已复制") : String(localized: "复制报告"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(document.markdown, forType: .string)
            }.buttonStyle(.borderedProminent).disabled(loading || loadError != nil || document.taskIDs.isEmpty)
        }.controlSize(.small).fixedSize(horizontal: true, vertical: false)
    }

    private var dateControls: some View {
        HStack(spacing: 10) {
            Button(String(localized: "上一期"), systemImage: "chevron.left") { movePeriod(-1) }.labelStyle(.iconOnly)
            Label(report.dateTitle, systemImage: "calendar").font(.callout).foregroundStyle(.secondary)
            Button(String(localized: "下一期"), systemImage: "chevron.right") { movePeriod(1) }
                .labelStyle(.iconOnly).disabled(report.interval.end > Date())
            if !report.isCurrent { Button("本期") { date = Date() } }
        }.buttonStyle(.borderless).fixedSize()
    }

    @MainActor private func loadDocument() async {
        loading = true
        loadError = nil
        do {
            let saved = try await model.store.savedWorkTaskReport(for: report)
            guard !Task.isCancelled else { return }
            savedDocument = saved
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func movePeriod(_ offset: Int) {
        if let next = Calendar.current.date(byAdding: period.component, value: offset, to: report.interval.start) { date = next }
    }

}

struct ReportStatusIcon: View {
    let status: WorkTaskStatus
    var body: some View {
        Image(systemName: status == .done ? "checkmark.circle.fill" : status == .doing ? "circle.lefthalf.filled" : "circle")
            .font(.system(size: 15)).foregroundStyle(status.tint)
            .frame(width: 18, height: 22).accessibilityLabel(status.title)
    }
}

private struct ReportPaper: View {
    @Binding var document: WorkTaskReportDocument
    var editing = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(spacing: 12) {
                Text(document.title).font(.system(size: 28, weight: .semibold))
                Text(document.dateTitle).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.top, 4).padding(.bottom, 6)
            Divider()
            ForEach($document.sections) { $section in
                VStack(alignment: .leading, spacing: 20) {
                    if editing {
                        TextField("大纲标题", text: $section.title).font(.system(size: 18, weight: .semibold))
                    } else {
                        Text(section.title).font(.system(size: 18, weight: .semibold))
                    }
                    if section.projects.isEmpty { Text("暂无记录。").foregroundStyle(.secondary) }
                    ForEach($section.projects) { $project in
                        VStack(alignment: .leading, spacing: 12) {
                            ViewThatFits(in: .horizontal) {
                                HStack { Text(project.name).fontWeight(.semibold); Spacer(); progress(project) }
                                VStack(alignment: .leading, spacing: 5) { Text(project.name).fontWeight(.semibold); progress(project) }
                            }
                            ForEach($project.items) { $item in
                                HStack(alignment: .top, spacing: 10) {
                                    ReportStatusIcon(status: item.status)
                                    if editing {
                                        VStack(alignment: .leading, spacing: 6) {
                                            TextField("事项标题", text: $item.title, axis: .vertical).fontWeight(.semibold)
                                            TextField("补充成果、进展或下一步安排", text: $item.body, axis: .vertical)
                                                .foregroundStyle(.secondary)
                                        }.textFieldStyle(.roundedBorder)
                                    } else {
                                        (Text(item.title).fontWeight(.semibold)
                                         + Text(item.body.isEmpty ? "" : " · " + item.body).foregroundColor(.secondary))
                                            .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                    }
                                }
                            }
                        }.padding(.bottom, 6)
                    }
                }
            }
        }
        .font(.system(size: 15)).padding(compact ? 24 : 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.09)))
    }

    private func progress(_ project: WorkTaskReportDocument.Project) -> some View {
        Text(project.progress).font(.caption).foregroundStyle(.secondary)
    }
}

private struct ReportEditor: View {
    let store: LibraryStore
    @State var document: WorkTaskReportDocument
    let saved: (WorkTaskReportDocument) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑\(document.title)").font(.headline)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? String(localized: "正在保存…") : String(localized: "保存")) {
                    saving = true
                    Task {
                        do { try await store.saveWorkTaskReport(document); saved(document); dismiss() }
                        catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving)
            }.padding(20)
            Divider()
            if let error { Text("保存失败：\(error)").foregroundStyle(.red).padding(12) }
            ScrollView { ReportPaper(document: $document, editing: true).padding(24) }
                .background(Color(nsColor: .underPageBackgroundColor)).disabled(saving)
        }.frame(width: 820, height: 680).interactiveDismissDisabled(saving)
    }
}
