import AppKit
import SwiftUI
import MyClipCore
@testable import MyClip

@main
struct TaskBoardScrollTests {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-TaskBoardTests-\(UUID())")
        let model = try MyClipModel(root: root, preview: true)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let statuses: [WorkTaskStatus] = [.todo, .doing, .done]
        for status in statuses {
            for index in 1...9 {
                let id = try await model.store.createWorkTask(
                    title: "\(status.title) \(index)：检查任务看板的长标题换行、独立滚动以及窗口缩小时的展示",
                    project: "MyClip", waitingReason: index == 1 ? "等待确认字段与交付范围" : "")
                try await model.store.setWorkTaskStatus(id, status: status)
            }
        }
        let allTasks = try await model.store.workTasks()
        model.workTasks = allTasks
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 1000),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: TaskDashboardView(model: model))

        func settle() async throws {
            for _ in 0..<6 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
        }
        func columns() -> [NSScrollView] {
            let outer = window.contentView!.subviews.flatMap { scrollViews(in: $0) }
            guard let page = outer.first, let document = page.documentView else { return [] }
            return document.subviews.flatMap { scrollViews(in: $0) }
        }
        func setRows(_ count: Int) async throws {
            model.workTasks = statuses.flatMap { status in allTasks.filter { $0.status == status }.prefix(count) }
            try await settle()
        }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        try await settle()
        check(columns().count == 3, "Each Kanban column has its own scroll view")
        guard columns().count == 3 else { exit(1) }

        try await setRows(1)
        let shortHeight = columns()[0].contentSize.height
        try await setRows(5)
        let fiveRowHeight = columns()[0].contentSize.height
        check(shortHeight < fiveRowHeight, "Short boards do not reserve five empty rows")
        check(columns().allSatisfy { abs($0.documentView!.bounds.height - $0.contentSize.height) < 2 }, "Five complete cards fit in each column")
        for count in [6, 9] {
            try await setRows(count)
            check(columns().allSatisfy { abs($0.contentSize.height - fiveRowHeight) < 2 }, "\(count) tasks keep the same five-row viewport")
            check(columns().allSatisfy { $0.documentView!.bounds.height > $0.contentSize.height }, "\(count) tasks remain reachable by scrolling")
        }
        let scrolling = columns()
        let outer = window.contentView!.subviews.flatMap { scrollViews(in: $0) }.first!
        let outerOffset = outer.documentVisibleRect.origin
        for (index, scroll) in scrolling.enumerated() {
            let offsets = scrolling.map { $0.documentVisibleRect.origin }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.documentView!.bounds.height - scroll.contentSize.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle()
            check(abs(scroll.documentVisibleRect.maxY - scroll.documentView!.bounds.maxY) < 2, "Column \(index + 1) can reveal its final task")
            check(scrolling.enumerated().allSatisfy { $0.offset == index || $0.element.documentVisibleRect.origin == offsets[$0.offset] }, "Column \(index + 1) scrolls independently")
            check(outer.documentVisibleRect.origin == outerOffset, "Column scrolling leaves the page and headings in place")
        }
        try await setRows(1)
        check(columns().allSatisfy { $0.documentVisibleRect.minY < 1 }, "Shrinking a scrolled column keeps its remaining task visible")
        try await setRows(0)
        check(columns().count == 3 && columns().allSatisfy { $0.contentSize.height > 0 }, "Empty columns remain visible as drop targets")
        try await setRows(9)
        for (name, width, dark) in [("wide", 960.0, false), ("narrow", 520.0, false), ("dark", 960.0, true)] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 1000))
            try await settle()
            check(columns().count == 3, "\(name): all three columns remain independently scrollable")
            check(columns().allSatisfy { $0.documentView!.bounds.width <= $0.contentSize.width + 1 }, "\(name): cards fit the column width")
            if let destination = CommandLine.arguments.dropFirst().first, let host = window.contentView,
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let url = URL(fileURLWithPath: destination).appendingPathComponent("native-columns-\(name).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            }
        }
        model.workTaskEvents = try await model.store.workTaskEvents()
        model.showingTaskReports = true
        for (name, width, dark) in [("wide", 960.0, false), ("narrow", 520.0, false), ("dark", 960.0, true)] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 1000))
            try await settle()
            let scrolls = window.contentView!.subviews.flatMap { scrollViews(in: $0) }
            check(scrolls.count == 1 && columns().isEmpty, "\(name): reports replace the board instead of being appended to it")
            check(scrolls.allSatisfy { $0.documentView!.bounds.width <= $0.contentSize.width + 1 }, "\(name): report document fits the reading area")
            if let destination = CommandLine.arguments.dropFirst().first, let host = window.contentView,
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let url = URL(fileURLWithPath: destination).appendingPathComponent("native-report-\(name).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            }
        }
        model.showingTaskReports = false
        try await settle()
        check(columns().count == 3, "Returning from reports restores the three independently scrollable columns")
        print("Task board scrolling checks: \(failures) failure(s)")
        if failures > 0 { exit(1) }
    }
}
