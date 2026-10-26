import AppKit
import MyClipCore
import SQLite3
import SwiftUI

@main
struct MenuBarBoardTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = MenuBarTestAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        Task {
            do {
                try await runChecks()
                exit(0)
            } catch {
                print("Menu bar checks failed: \(error)")
                exit(1)
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor static func runChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-MenuBarTests-\(UUID())")
        let model = try MyClipModel(root: root, preview: true)
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: root)
        }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            fflush(stdout)
            if !condition { failures += 1 }
        }
        // Load the same upstream SVGs Xcode compiles into template image assets.
        for icon in MenuBarIcon.allCases {
            let directory = URL(fileURLWithPath: "MyClip/Assets.xcassets/\(icon.rawValue).imageset")
            let file = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first {
                $0.pathExtension == "svg"
            }
            let image = file.flatMap { NSImage(contentsOf: $0) }
            check(image?.setName(icon.rawValue) == true, "Lucide asset \(icon.rawValue) is readable")
        }

        let host = NSHostingView(rootView: MenuBarBoardView(model: model, openApplication: {}, quitApplication: {}, dismiss: {}))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: MenuBarBoardLayout.size(tasks: [], available: NSSize(width: 1000, height: 800))),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<6 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        func click(in content: NSView, at point: NSPoint) {
            guard let target = content.window else { return }
            let location = content.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        func snapshot(_ name: String) throws {
            guard let destination = CommandLine.arguments.dropFirst().first,
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
            else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: destination).appendingPathComponent("menu-board-\(name).png"))
        }

        try await settle()
        check(!model.workTasksLoaded && model.workTasksLoadError == nil, "The board starts in a loading state")
        try snapshot("loading")
        await model.refresh()
        try await settle()
        check(model.workTasksLoaded && model.workTasksUpdatedAt != nil, "Initial refresh resolves an empty board with an update time")
        try snapshot("empty")

        for status in MenuBarBoardLayout.statuses {
            for index in 1...9 {
                let id = try await model.store.createWorkTask(
                    title: "\(status.title) \(index)：检查长标题换行与只读看板独立滚动", project: "MyClip",
                    waitingReason: index == 1 ? "客户确认字段" : "")
                try await model.store.setWorkTaskStatus(id, status: status)
            }
        }
        let ignored = try await model.store.createWorkTask(title: "IGNORED TASK", project: "hidden")
        try await model.store.setWorkTaskStatus(ignored, status: .ignored)
        await model.refresh()
        model.search = "a query that matches no task"
        let original = model.workTasks.map { ($0.id, $0.status) }
        window.setContentSize(MenuBarBoardLayout.size(tasks: model.workTasks, available: NSSize(width: 1000, height: 800)))
        try await settle()
        check(scrollViews(in: host).count == 3, "All three states have independent scrolling")
        check(
            scrollViews(in: host).allSatisfy { ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height },
            "The board remains bounded with nine tasks in each column")
        for (index, scroll) in scrollViews(in: host).enumerated() {
            let others = scrollViews(in: host).map { $0.documentVisibleRect.origin }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scroll.documentView!.bounds.height - scroll.contentSize.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle()
            check(scroll.documentVisibleRect.maxY >= scroll.documentView!.bounds.maxY - 2, "Column \(index + 1) reveals its last task")
            check(
                scrollViews(in: host).enumerated().allSatisfy {
                    $0.offset == index || $0.element.documentVisibleRect.origin == others[$0.offset]
                }, "Column \(index + 1) does not move other columns")
        }
        for scroll in scrollViews(in: host) {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        for (name, width, dark) in [("light", MenuBarBoardLayout.width, false), ("dark", MenuBarBoardLayout.width, true), ("narrow", 360.0, false)] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 458))
            try await settle()
            let scrolls = scrollViews(in: host)
            check(scrolls.count == (width < MenuBarBoardLayout.narrowWidth ? 1 : 3), "\(name): the board uses the expected responsive layout")
            check(
                scrolls.allSatisfy { ($0.documentView?.bounds.width ?? 0) <= $0.contentSize.width + 1 },
                "\(name): cards fit without horizontal overflow")
            try snapshot(name)
        }
        window.setContentSize(NSSize(width: MenuBarBoardLayout.width, height: 458))

        var database: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("Library.sqlite").path, &database) == SQLITE_OK, let database else {
            throw LibraryError.database("Could not open the isolated test database")
        }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, "ALTER TABLE work_tasks RENAME TO unavailable_tasks", nil, nil, nil)
        await model.refresh()
        try await settle()
        check(model.workTasksLoadError != nil && model.workTasksLoaded, "Read failure is reported without replacing a loaded board")
        check(model.workTasks.map(\.id) == original.map(\.0), "Read failure preserves the cached tasks")
        try snapshot("cached-error")
        model.workTasks = []
        try await settle()
        try snapshot("error")
        sqlite3_exec(database, "ALTER TABLE unavailable_tasks RENAME TO work_tasks", nil, nil, nil)
        await model.refresh()
        try await settle()
        check(model.workTasksLoadError == nil && model.workTasks.count == original.count, "The next normal refresh recovers the board")

        var opens = 0
        var quits = 0
        model.onOpenWindow = { opens += 1 }
        let controller = MyClipMenuBarController(model: model, terminate: { quits += 1 })
        defer {
            controller.popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(controller.statusItem)
        }
        try await settle()
        controller.statusItem.button?.performClick(nil)
        try await settle()
        check(controller.popover.isShown && opens == 0, "Clicking the real status button shows the board without opening the application")
        check(controller.statusItem.button?.state == .on, "The menu bar icon reflects the open popover")
        controller.statusItem.button?.performClick(nil)
        try await settle()
        check(
            !controller.popover.isShown && opens == 0 && controller.statusItem.button?.state == .off,
            "Clicking again dismisses the board without opening a window")
        controller.statusItem.button?.performClick(nil)
        try await settle()
        if let content = controller.popover.contentViewController?.view {
            let y = content.isFlipped ? content.bounds.height - MenuBarBoardLayout.barHeight / 2 : MenuBarBoardLayout.barHeight / 2
            click(in: content, at: NSPoint(x: 56, y: y))
            try await settle()
            check(
                opens == 1 && model.page == .dashboard && model.search.isEmpty && !controller.popover.isShown,
                "Only Open Application opens the full Kanban and dismisses the popover")
        } else {
            check(false, "Popover content exists")
        }
        controller.statusItem.button?.performClick(nil)
        try await settle()
        if let content = controller.popover.contentViewController?.view {
            let y = content.isFlipped ? content.bounds.height - MenuBarBoardLayout.barHeight / 2 : MenuBarBoardLayout.barHeight / 2
            click(in: content, at: NSPoint(x: content.bounds.width - 56, y: y))
            try await settle()
            check(
                quits == 1 && !controller.popover.isShown && opens == 1, "Quit Application invokes termination and does not open a window")
        }
        check(
            zip(model.workTasks, original).allSatisfy { $0.id == $1.0 && $0.status == $1.1 },
            "Browsing and footer actions never change task status")
        controller.statusItem.button?.performClick(nil)
        try await settle()
        if let popupWindow = controller.popover.contentViewController?.view.window,
            let escape = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: popupWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)
        {
            popupWindow.sendEvent(escape)
            try await settle()
            check(!controller.popover.isShown && opens == 1, "Escape dismisses the board without opening a window")
        }
        if CommandLine.arguments.contains("--inspect") {
            controller.statusItem.button?.performClick(nil)
            print("Inspection ready")
            fflush(stdout)
            try await Task.sleep(for: .seconds(45))
        }
        print("Menu bar board checks: \(failures) failure(s)")
        if failures > 0 { exit(1) }
    }
}

@MainActor
private final class MenuBarTestAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
