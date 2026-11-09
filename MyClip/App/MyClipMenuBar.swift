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
    private var captureObservation: AnyCancellable?

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
        captureObservation = Publishers.CombineLatest4(
            model.$capturing, model.preferences.$captureEnabled,
            model.$screenPermission, model.$accessibilityPermission
        ).sink { [weak self] capturing, enabled, screen, accessibility in
            self?.updateStatusDescription(capturing: capturing, enabled: enabled, hasPermissions: screen && accessibility)
        }
        guard let button = statusItem.button else { return }
        // The menu bar always shows the application icon; capture state stays in the tooltip and
        // accessibility description instead of replacing the icon with a runtime symbol.
        let source = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
        let image = (source?.copy() as? NSImage) ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = false
        button.image = image
        button.imagePosition = .imageOnly
        updateStatusDescription(capturing: model.capturing, enabled: model.preferences.captureEnabled, hasPermissions: !model.showPermissions)
        button.setAccessibilityHelp(String(localized: "显示 MyClip 看板"))
        button.target = self
        button.action = #selector(togglePopover)
    }

    private func updateStatusDescription(capturing: Bool, enabled: Bool, hasPermissions: Bool) {
        guard let button = statusItem.button else { return }
        let status: String
        if !hasPermissions {
            status = String(localized: "采集权限已关闭，请在设置中恢复")
        } else if enabled && capturing {
            status = String(localized: "采集中")
        } else {
            status = String(localized: "采集已暂停")
        }
        button.toolTip = "MyClip · \(status)"
        button.setAccessibilityLabel("MyClip, \(status)")
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
