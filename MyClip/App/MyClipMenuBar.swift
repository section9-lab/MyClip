import AppKit
import Combine
import MyClipCore
import SwiftUI

@MainActor
final class MyClipMenuBarController: NSObject, NSPopoverDelegate {
    private let model: MyClipModel
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    private let terminate: () -> Void
    private var tasksObservation: AnyCancellable?

    init(model: MyClipModel, terminate: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.model = model
        self.terminate = terminate
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(
            rootView: MenuBarBoardView(
                model: model,
                openApplication: { [weak self] in self?.openApplication() },
                quitApplication: { [weak self] in self?.quitApplication() },
                dismiss: { [weak self] in self?.popover.performClose(nil) }))
        host.sizingOptions = []
        popover.contentViewController = host
        tasksObservation = model.$workTasks.sink { [weak self] tasks in
            guard let self, self.popover.isShown else { return }
            self.resizePopover(tasks: tasks)
        }
        guard let button = statusItem.button else { return }
        let icon = NSImage(named: MenuBarIcon.paperclip.rawValue)?.copy() as? NSImage
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true
        button.image = icon
        button.imagePosition = .imageOnly
        button.toolTip = String(localized: "显示 MyClip 看板")
        button.setAccessibilityLabel("MyClip")
        button.setAccessibilityHelp(String(localized: "显示只读看板"))
        button.target = self
        button.action = #selector(togglePopover)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            resizePopover(tasks: model.workTasks)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            button.state = .on
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func resizePopover(tasks: [WorkTask]) {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let size = MenuBarBoardLayout.size(tasks: tasks, available: screen?.visibleFrame.size ?? NSSize(width: 800, height: 600))
        if popover.contentSize != size { popover.contentSize = size }
    }

    private func openApplication() {
        popover.performClose(nil)
        model.showingTaskReports = false
        model.search = ""
        model.open(.dashboard)
    }

    private func quitApplication() {
        popover.performClose(nil)
        terminate()
    }

    func popoverDidClose(_ notification: Notification) { statusItem.button?.state = .off }
}
