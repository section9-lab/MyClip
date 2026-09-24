import SwiftUI
import MyClipCore

struct TaskReportsView: View {
    @ObservedObject var model: MyClipModel
    let openTask: (UUID) -> Void
    @State private var period = WorkTaskReportPeriod.day
    @State private var date = Date()
    @State private var sharing = false
    @State private var savedDocument: WorkTaskReportDocument?
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
                    HStack(spacing: 16) { periodPicker; dateControls; Spacer(minLength: 0); actions }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 16) { periodPicker; dateControls }
                        actions.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        periodPicker
                        dateControls
                        actions
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: 1200)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if loading {
                            ProgressView("正在读取报告…").frame(maxWidth: .infinity).padding(60)
                        } else if let loadError {
                            VStack(spacing: 12) {
                                Text("无法读取已保存的报告").font(.headline)
                                Text(loadError).font(.callout).foregroundStyle(.secondary)
                                Button("重试") { Task { await loadDocument() } }
                            }.frame(maxWidth: .infinity).padding(40)
                        } else {
                            ReportPaper(document: document, compact: geometry.size.width < 700)
                        }
                    }
                    .padding(.horizontal, geometry.size.width < 700 ? 16 : 24).padding(.vertical, 16)
                    .frame(maxWidth: 1060).frame(maxWidth: .infinity)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .overlay {
                    GeometryReader { available in
                        if sharing {
                            Color.black.opacity(0.025).contentShape(Rectangle())
                                .onTapGesture { sharing = false }.accessibilityHidden(true)
                            ReportSharePanel(document: document) { sharing = false }
                                .frame(width: min(360, max(1, available.size.width - 32)),
                                       height: min(520, max(1, available.size.height - 32)))
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.1)))
                                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                                .accessibilityAddTraits(.isModal)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                .padding(16)
                        }
                    }
                }
            }
        }
        .task(id: report.document.id) { await loadDocument() }
        .onChange(of: report.document.id) { _ in sharing = false }
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
        }.pickerStyle(.menu).labelsHidden().controlSize(.regular).frame(width: 104)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(String(localized: "参考任务"), systemImage: "sidebar.right") { sharing = false; showingSources = true }
                .disabled(loading || loadError != nil || document.taskIDs.isEmpty)
            Button(String(localized: "分享"), systemImage: "square.and.arrow.up") { sharing.toggle() }
                .disabled(loading || loadError != nil || document.taskIDs.isEmpty)
        }.buttonStyle(ReportToolbarButtonStyle()).fixedSize(horizontal: true, vertical: false)
    }

    private var dateControls: some View {
        HStack(spacing: 10) {
            DatePicker("日期", selection: $date, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.field).labelsHidden().help(report.dateTitle)
            ControlGroup {
                Button(String(localized: "上一期"), systemImage: "chevron.left") { movePeriod(-1) }
                Button(String(localized: "下一期"), systemImage: "chevron.right") { movePeriod(1) }
                    .disabled(report.interval.end > Date())
            }.controlGroupStyle(.navigation).labelStyle(.iconOnly)
            if !report.isCurrent { Button("本期") { date = Date() } }
        }.controlSize(.regular).fixedSize()
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

private struct ReportToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(height: 34)
            .foregroundStyle(.primary)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.08 : hovering && isEnabled ? 0.04 : 0)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(hovering && isEnabled ? 0.18 : 0.1)))
            .clipShape(Capsule()).contentShape(Capsule()).opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
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
    let document: WorkTaskReportDocument
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 8) {
                Text(document.title).font(.system(size: 26, weight: .semibold))
                Text(document.dateTitle).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
            Divider()
            ForEach(document.sections) { section in
                VStack(alignment: .leading, spacing: 20) {
                    Text(section.title).font(.system(size: 18, weight: .semibold))
                    if section.projects.isEmpty { Text("暂无记录。").foregroundStyle(.secondary) }
                    ForEach(section.projects) { project in
                        VStack(alignment: .leading, spacing: 12) {
                            ViewThatFits(in: .horizontal) {
                                HStack { Text(project.name).fontWeight(.semibold); Spacer(); progress(project) }
                                VStack(alignment: .leading, spacing: 5) { Text(project.name).fontWeight(.semibold); progress(project) }
                            }
                            ForEach(project.items) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    ReportStatusIcon(status: item.status)
                                    (Text(item.title).fontWeight(.semibold)
                                     + Text(item.body.isEmpty ? "" : " · " + item.body).foregroundColor(.secondary))
                                        .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                }
                            }
                        }.padding(.bottom, 6)
                    }
                }
            }
        }
        .font(.system(size: 15)).padding(.horizontal, compact ? 24 : 36).padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.09)))
    }

    private func progress(_ project: WorkTaskReportDocument.Project) -> some View {
        Text(project.progress).font(.caption).foregroundStyle(.secondary)
    }
}
