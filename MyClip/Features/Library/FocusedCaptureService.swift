import AppKit
import ApplicationServices
import ScreenCaptureKit
import MyClipCore

@MainActor
final class FocusedCaptureService {
    private var settings = CaptureSettings()
    private var excludedBundleIDs: Set<String> = []
    var onCapture: ((CapturedImage, CaptureContext) async -> Void)?
    var onStatus: ((String) -> Void)?
    private var trigger = CaptureTrigger()
    private var monitors: [Any] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var enabled = false
    private var suspended = false
    private var screenLocked = false
    private var busy = false
    private var generation = 0
    private var pendingCaptures: [(CaptureReason, Focus, Int)] = []
    private var lastPointer = NSEvent.mouseLocation
    private var keyboardFocus: Focus?
    /// Reading one window fires the idle triggers every few seconds; a second look inside the cooldown adds nothing.
    private var lastWindowCapture: [String: TimeInterval] = [:]
    static let mouseCooldown: TimeInterval = 8

    var hasScreenPermission: Bool { CGPreflightScreenCaptureAccess() }
    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }
    var isRunning: Bool { enabled }

    func configure(settings: CaptureSettings, excludedBundleIDs: Set<String>) {
        guard self.settings != settings || self.excludedBundleIDs != excludedBundleIDs else { return }
        self.settings = settings
        self.excludedBundleIDs = excludedBundleIDs
        trigger.settings = settings
        trigger.reset()
        keyboardFocus = nil
        generation += 1
        pendingCaptures.removeAll()
        lastPointer = NSEvent.mouseLocation
    }

    func requestScreenPermission() {
        if !CGRequestScreenCaptureAccess() { PermissionCoordinator.openScreenCaptureSettings() }
    }

    func requestAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() -> Bool {
        guard hasScreenPermission, hasAccessibilityPermission else { return false }
        stop()
        enabled = true
        suspended = false
        screenLocked = false
        lastPointer = NSEvent.mouseLocation
        let activityMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                                   .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                   .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: activityMask, handler: { [weak self] event in
            let type = event.type
            guard type != .scrollWheel || event.scrollingDeltaY != 0 else { return }
            let time = event.timestamp
            let clickCount = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown ? event.clickCount : 1
            Task { @MainActor in self?.activity(type: type, at: time, clickCount: clickCount) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let code = event.keyCode
            let isRepeat = event.isARepeat
            let isShortcut = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            Task { @MainActor in self?.keyDown(code: code, isRepeat: isRepeat, isShortcut: isShortcut) }
        }) { monitors.append(monitor) }
        let poller = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer = poller
        RunLoop.main.add(poller, forMode: .common)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.keyboardFocus = nil
                self?.trigger.resetKeyboard()
            }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspend(true) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspend(false) }
            })
        }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setScreenLocked(locked) }
            })
        }
        guard monitors.count == 2 else { stop(); onStatus?("无法启动输入监听，请重新开启辅助功能权限后重启 MyClip"); return false }
        onStatus?("采集已开启，等待其他应用中的活动")
        return true
    }

    func stop() {
        enabled = false
        generation += 1
        pendingCaptures.removeAll()
        trigger.reset()
        keyboardFocus = nil
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        lockObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        lockObservers.removeAll()
        onStatus?("采集已暂停")
    }

    private func setScreenLocked(_ value: Bool) {
        screenLocked = value
        generation += 1
        pendingCaptures.removeAll()
        trigger.reset()
        keyboardFocus = nil
        lastPointer = NSEvent.mouseLocation
        onStatus?(value ? "屏幕已锁定，等待解锁" : "等待应用中的活动")
    }

    private func suspend(_ value: Bool) {
        suspended = value
        generation += 1
        pendingCaptures.removeAll()
        trigger.reset()
        keyboardFocus = nil
        lastPointer = NSEvent.mouseLocation
        onStatus?(value ? "屏幕休眠，等待恢复" : "等待应用中的活动")
    }

    private func activity(type: NSEvent.EventType, at time: TimeInterval, clickCount: Int) {
        guard enabled, !suspended, !screenLocked else { return }
        switch type {
        case .scrollWheel:
            guard settings.mouseTriggers.contains(.scroll) else { return }
            trigger.scroll(at: time)
            onStatus?("已检测到上下滚动，停止 2 秒后截图")
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard settings.mouseTriggers.contains(.click) else { return }
            updatePointer(at: time)
            trigger.press(at: time, clickCount: clickCount)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            updateKeyboardFocus()
            guard settings.mouseTriggers.contains(.click) else { return }
            updatePointer(at: time)
            guard trigger.click(at: time, doubleClickInterval: NSEvent.doubleClickInterval) else { return }
            onStatus?("已检测到静止 1 秒后的点击，等待单击或双击结束后截图")
        default:
            guard settings.mouseTriggers.contains(.click) else { return }
            lastPointer = NSEvent.mouseLocation
            trigger.activity(at: time)
        }
    }

    private func updateKeyboardFocus() {
        let current = focus()
        if let current, let previous = keyboardFocus,
           current.app.processIdentifier == previous.app.processIdentifier, CFEqual(current.window, previous.window) {
            return
        }
        trigger.resetKeyboard()
        keyboardFocus = current
    }

    private func keyDown(code: UInt16, isRepeat: Bool, isShortcut: Bool) {
        guard enabled, !suspended, !screenLocked else { return }
        updateKeyboardFocus()
        guard keyboardFocus != nil, let reason = trigger.keyDown(keyCode: code, isRepeat: isRepeat, isShortcut: isShortcut) else { return }
        lastPointer = NSEvent.mouseLocation
        onStatus?("已检测到回车，正在读取截图")
        capture(reason: reason)
    }

    private func poll() {
        guard enabled, !suspended, !screenLocked else { return }
        guard hasScreenPermission, hasAccessibilityPermission else {
            stop()
            onStatus?("采集权限已关闭，请在设置中恢复")
            return
        }
        let time = ProcessInfo.processInfo.systemUptime
        updatePointer(at: time)
        if let reason = trigger.poll(at: time) { capture(reason: reason) }
    }

    // Pointer position also covers applications that consume global move events.
    private func updatePointer(at time: TimeInterval) {
        let pointer = NSEvent.mouseLocation
        if pointer != lastPointer {
            lastPointer = pointer
            trigger.activity(at: time)
        }
    }

    private struct Focus {
        let app: NSRunningApplication
        let window: AXUIElement
        let frame: CGRect
        let title: String
    }

    private static func windowKey(_ focus: Focus) -> String { "\(focus.app.processIdentifier)|\(focus.title)" }

    private func focus() -> Focus? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleIdentifier,
              !excludedBundleIDs.contains(bundleID),
              !["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"].contains(bundleID) else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?, titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size), size.width > 1, size.height > 1 else { return nil }
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
        return Focus(app: app, window: window, frame: CGRect(origin: point, size: size), title: titleValue as? String ?? "")
    }

    private func stillFocused(_ previous: Focus) -> Bool {
        guard let current = focus() else { return false }
        return current.app.processIdentifier == previous.app.processIdentifier &&
            CFEqual(current.window, previous.window) && current.frame == previous.frame && current.title == previous.title
    }

    private func capture(reason: CaptureReason) {
        guard let focused = focus() else { onStatus?("本次跳过：当前为 MyClip、排除的应用或没有可识别的焦点窗口"); return }
        if reason != .enter, reason != .manual, let last = lastWindowCapture[Self.windowKey(focused)],
           Date.now.timeIntervalSinceReferenceDate - last < Self.mouseCooldown {
            onStatus?("本次跳过：\(focused.app.localizedName ?? "应用") 刚截过图")
            return
        }
        if busy {
            if pendingCaptures.count < 16 { pendingCaptures.append((reason, focused, generation)); onStatus?("截图正在读取，另有 \(pendingCaptures.count) 次触发等待") }
            else { onStatus?("采集较繁忙，已跳过过密的触发") }
            return
        }
        capture(reason: reason, focused: focused, startedGeneration: generation)
    }

    private func capture(reason: CaptureReason, focused: Focus, startedGeneration: Int) {
        busy = true
        Task {
            defer {
                busy = false
                if !pendingCaptures.isEmpty {
                    let next = pendingCaptures.removeFirst()
                    capture(reason: next.0, focused: next.1, startedGeneration: next.2)
                }
            }
            guard enabled, !suspended, !screenLocked, startedGeneration == generation, stillFocused(focused) else { return }
            do {
                onStatus?("正在确认 \(focused.app.localizedName ?? "应用") 的焦点窗口")
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let candidates = content.windows.filter { $0.windowLayer == 0 }.map {
                    WindowCandidate(id: $0.windowID, processID: $0.owningApplication?.processID ?? 0, frame: $0.frame, title: $0.title ?? "")
                }
                guard let id = FocusedWindowMatcher.match(processID: focused.app.processIdentifier, frame: focused.frame, title: focused.title, candidates: candidates),
                      let window = content.windows.first(where: { $0.windowID == id }),
                      enabled, !suspended, !screenLocked, generation == startedGeneration, stillFocused(focused) else { onStatus?("本次跳过：焦点窗口发生变化或无法匹配"); return }
                let filter: SCContentFilter
                let title: String
                let captureFrame: CGRect
                let displays = content.displays.map { DisplayCandidate(id: $0.displayID, frame: $0.frame) }
                let displayID = FocusedDisplayMatcher.match(frame: focused.frame, displays: displays)
                let focusedDisplay = content.displays.first { $0.displayID == displayID }
                if settings.scope == .focusedDisplay {
                    guard let display = focusedDisplay else {
                        onStatus?("本次跳过：无法确认焦点窗口所在的显示器")
                        return
                    }
                    let excluded = content.applications.filter {
                        $0.processID == ProcessInfo.processInfo.processIdentifier || excludedBundleIDs.contains($0.bundleIdentifier)
                    }
                    filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                    captureFrame = display.frame
                    title = focused.title.isEmpty ? "显示器全屏" : focused.title + " · 显示器全屏"
                } else {
                    filter = SCContentFilter(desktopIndependentWindow: window)
                    captureFrame = window.frame
                    title = focused.title
                }
                let config = SCStreamConfiguration()
                let bounds: CGRect
                let pixelScale: Double
                if #available(macOS 14.0, *) {
                    bounds = filter.contentRect
                    pixelScale = Double(filter.pointPixelScale)
                    config.ignoreShadowsSingleWindow = true
                } else {
                    bounds = captureFrame
                    pixelScale = focusedDisplay.map { Double($0.width) / $0.frame.width } ?? 2
                }
                let scale = min(pixelScale, 4096 / max(bounds.width, bounds.height))
                config.width = max(1, Int(bounds.width * scale))
                config.height = max(1, Int(bounds.height * scale))
                config.showsCursor = false
                onStatus?("正在读取 \(focused.app.localizedName ?? "应用") 的截图")
                let image = try await WindowImageCapture.capture(filter: filter, configuration: config)
                guard enabled, !suspended, !screenLocked, generation == startedGeneration, stillFocused(focused) else { onStatus?("本次跳过：焦点窗口发生变化或无法匹配"); return }
                let captured = try await Task.detached(priority: .utility) { try CapturedImage(image: image) }.value
                guard enabled, generation == startedGeneration else { return }
                let context = CaptureContext(appName: focused.app.localizedName ?? "应用", bundleID: focused.app.bundleIdentifier ?? "",
                                             windowTitle: title, windowID: id, reason: reason)
                lastWindowCapture[Self.windowKey(focused)] = Date.now.timeIntervalSinceReferenceDate
                await onCapture?(captured, context)

            } catch { onStatus?("本次采集未完成：\(error.localizedDescription)") }
        }
    }
}
