import SwiftUI
import AppKit

// MARK: - Top-level controller: one NSPanel per screen

@MainActor
final class CursorCompanionController {
    private var screenMonitors: [ScreenCompanionMonitor] = []
    private var mouseMonitor: Any?
    private var pollingTimer: Timer?

    func install() {
        rebuildMonitors()

        // Primary: global mouse event monitor
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateAllMonitors() }
        }

        // Fallback: 60 fps polling (catches missed events + keeps lerp ticking)
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateAllMonitors() }
        }

        updateAllMonitors()

        // Rebuild when displays are plugged/unplugged
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildMonitors() }
        }
    }

    func uninstall() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        pollingTimer?.invalidate()
        pollingTimer = nil
        screenMonitors.forEach { $0.teardown() }
        screenMonitors.removeAll()
        NotificationCenter.default.removeObserver(self)
    }

    private func rebuildMonitors() {
        screenMonitors.forEach { $0.teardown() }
        screenMonitors = NSScreen.screens.map { screen in
            let m = ScreenCompanionMonitor(screen: screen)
            m.start()
            return m
        }
    }

    private func updateAllMonitors() {
        let mouse = NSEvent.mouseLocation
        let activeID = NSScreen.screens.first {
            NSMouseInRect(mouse, $0.frame, false)
        }.map { ObjectIdentifier($0) }

        for monitor in screenMonitors {
            monitor.update(mouseLocation: mouse, isActive: ObjectIdentifier(monitor.screen) == activeID)
        }
    }
}

// MARK: - Per-screen monitor: owns one NSPanel + one model

@MainActor
final class ScreenCompanionMonitor {
    let screen: NSScreen
    private var panel: NSPanel?
    private let model = CursorCompanionModel()
    private var localMouseMonitor: Any?

    init(screen: NSScreen) {
        self.screen = screen
    }

    func start() {
        let frame = screen.frame
        model.screenSize = frame.size

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        let hostingController = NSHostingController(
            rootView: CursorCompanionView(model: model)
        )
        hostingController.view.frame = frame
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        panel.contentView = hostingController.view
        panel.orderFrontRegardless()
        self.panel = panel

        // Local monitor as backup
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleLocalMouse(event: event)
            return event
        }

        model.startAnimations()
    }

    func teardown() {
        model.stopAnimations()
        if let m = localMouseMonitor {
            NSEvent.removeMonitor(m)
            localMouseMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    /// Called every poll tick / mouse event from the top-level controller.
    func update(mouseLocation: NSPoint, isActive: Bool) {
        let sf = screen.frame

        // Convert global AppKit coords → this panel's local SwiftUI coords.
        // X: distance from screen left edge
        // Y: distance from screen top edge (SwiftUI Y-down)
        let localX = mouseLocation.x - sf.origin.x
        let localY = sf.height - (mouseLocation.y - sf.origin.y)
        model.setTarget(x: localX, y: localY)

        // When cursor first enters this screen, snap instantly (no lerp lag)
        if isActive && !model.wasActive {
            model.snapToTarget()
        }
        model.wasActive = isActive
    }

    private func handleLocalMouse(event: NSEvent) {
        guard let win = event.window else { return }
        let globalPoint = win.convertPoint(toScreen: event.locationInWindow)
        let sf = screen.frame
        model.setTarget(
            x: globalPoint.x - sf.origin.x,
            y: sf.height - (globalPoint.y - sf.origin.y)
        )
    }
}
