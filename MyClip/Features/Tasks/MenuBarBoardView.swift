import MyClipCore
import SwiftUI

// Vendored Lucide assets keep the menu bar and its popover on the same icon set.
enum MenuBarIcon: String, CaseIterable {
    case paperclip = "LucidePaperclip"
    case board = "LucideColumns3"
    case todo = "LucideCircle"
    case doing = "LucideCircleDot"
    case done = "LucideCircleCheck"
    case waiting = "LucideClock3"
    case open = "LucideArrowUpRight"
    case quit = "LucidePower"

    var image: some View {
        Image(nsImage: NSImage(named: rawValue) ?? NSImage()).renderingMode(.template).resizable().scaledToFit()
            .frame(width: 14, height: 14).accessibilityHidden(true)
    }
}

enum MenuBarBoardLayout {
    static let width: CGFloat = 540
    static let narrowWidth: CGFloat = 520
    static let cardHeight: CGFloat = 96
    static let spacing: CGFloat = 8
    static let columnInset: CGFloat = 8
    static let boardInset: CGFloat = 12
    static let columnHeaderHeight: CGFloat = 26
    static let barHeight: CGFloat = 44
    static let statuses: [WorkTaskStatus] = [.todo, .doing, .done]

    static func size(tasks: [WorkTask], available: NSSize) -> NSSize {
        let rows = min(3, max(1, statuses.map { status in tasks.filter { $0.status == status }.count }.max() ?? 0))
        let boardHeight =
            CGFloat(rows) * cardHeight + CGFloat(rows - 1) * spacing
            + columnHeaderHeight + 2 * columnInset + 2 * boardInset
        return NSSize(
            width: min(width, max(280, available.width - 32)),
            height: min(boardHeight + 2 * barHeight, max(200, available.height - 32)))
    }
}

struct MenuBarBoardView: View {
    @ObservedObject var model: MyClipModel
    let openApplication: () -> Void
    let quitApplication: () -> Void
    let dismiss: () -> Void

    private var tasks: [WorkTask] { model.workTasks.filter { $0.status.isOnBoard } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .scrollIndicators(.hidden)
        .onExitCommand(perform: dismiss)
        .accessibilityLabel("MyClip 看板")
    }

    private var header: some View {
        HStack(spacing: 8) {
            MenuBarIcon.board.image.foregroundStyle(Color.accentColor)
            Text("看板").fontWeight(.medium)
            Text("\(tasks.count) 项").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if model.workTasksLoadError != nil {
                Text("更新失败").foregroundStyle(.secondary)
            } else if let date = model.workTasksUpdatedAt {
                Text("更新于 \(date.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption).padding(.horizontal, 16).frame(height: MenuBarBoardLayout.barHeight)
    }

    @ViewBuilder private var content: some View {
        if !model.workTasksLoaded && model.workTasksLoadError == nil {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("正在加载任务…").font(.callout).foregroundStyle(.secondary)
            }
        } else if tasks.isEmpty {
            VStack(spacing: 8) {
                Text(model.workTasksLoadError == nil ? String(localized: "暂无看板任务") : String(localized: "暂时无法读取看板"))
                    .font(.callout.weight(.medium))
                Text(
                    model.workTasksLoadError == nil
                        ? String(localized: "在应用中新建待办，或让 AI 从 Memory 发现工作。") : String(localized: "请打开应用查看，稍后会自动重试。")
                )
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(24)
        } else {
            GeometryReader { geometry in
                if geometry.size.width >= MenuBarBoardLayout.narrowWidth {
                    HStack(alignment: .top, spacing: MenuBarBoardLayout.spacing) {
                        ForEach(MenuBarBoardLayout.statuses, id: \.self) { status in
                            column(status, scrolls: true)
                        }
                    }.padding(MenuBarBoardLayout.boardInset)
                } else {
                    ScrollView {
                        VStack(spacing: MenuBarBoardLayout.spacing) {
                            ForEach(MenuBarBoardLayout.statuses, id: \.self) { status in
                                column(status, scrolls: false)
                            }
                        }.padding(MenuBarBoardLayout.boardInset)
                    }
                }
            }
        }
    }

    private func column(_ status: WorkTaskStatus, scrolls: Bool) -> some View {
        let items = tasks.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                statusIcon(status).image.foregroundStyle(status.tint)
                Text(status.title).fontWeight(.medium)
                Text(items.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
            }
            .font(.caption).frame(height: MenuBarBoardLayout.columnHeaderHeight)
            if scrolls {
                ScrollView(.vertical) { cards(items, status: status) }
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel("\(status.title)任务，可上下滚动")
            } else {
                cards(items, status: status)
            }
        }
        .padding(MenuBarBoardLayout.columnInset)
        .frame(maxWidth: .infinity, maxHeight: scrolls ? .infinity : nil, alignment: .topLeading)
        .background { TaskBoardColumnBackground(status: status) }
    }

    private func cards(_ items: [WorkTask], status: WorkTaskStatus) -> some View {
        LazyVStack(spacing: MenuBarBoardLayout.spacing) {
            if items.isEmpty {
                Text("暂无\(status.title)任务").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: MenuBarBoardLayout.cardHeight)
            }
            ForEach(items) { task in
                MenuBarTaskCard(task: task)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(action: openApplication) {
                Label {
                    Text("打开应用")
                } icon: {
                    MenuBarIcon.open.image
                }
            }
            .accessibilityIdentifier("menu-bar-open-application")
            Spacer()
            Button(action: quitApplication) {
                Label {
                    Text("退出应用")
                } icon: {
                    MenuBarIcon.quit.image
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("menu-bar-quit-application")
        }
        .buttonStyle(.borderless).controlSize(.small).font(.callout)
        .padding(.horizontal, 16).frame(height: MenuBarBoardLayout.barHeight)
    }

    private func statusIcon(_ status: WorkTaskStatus) -> MenuBarIcon {
        switch status {
        case .doing: .doing
        case .done: .done
        default: .todo
        }
    }

}

private struct MenuBarTaskCard: View {
    let task: WorkTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title).font(.callout.weight(.medium)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !task.waitingReason.isEmpty && task.status != .done {
                HStack(spacing: 4) {
                    MenuBarIcon.waiting.image
                    Text("等待：\(task.waitingReason)").lineLimit(1)
                }.font(.caption2).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(task.projectTitle).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(task.evidence.count) 条依据").fixedSize()
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10).frame(height: MenuBarBoardLayout.cardHeight)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.35)) }
        .help([task.title, task.waitingReason].filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(task.title)，\(task.status.title)，\(task.projectTitle)")
        .accessibilityValue(
            task.waitingReason.isEmpty || task.status == .done
                ? String(localized: "\(task.evidence.count) 条依据") : String(localized: "等待：\(task.waitingReason)"))
    }
}
