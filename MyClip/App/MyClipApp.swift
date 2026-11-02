import AppKit
import SwiftUI
import MyClipCore

@MainActor
final class MyClipAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var model: MyClipModel?
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var menuBar: MyClipMenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ProcessInfo.processInfo.disableAutomaticTermination("MyClip keeps its menu bar and capture queue available")
        installMenus()
        let preview = CommandLine.arguments.contains("--preview")
        if !preview { ForegroundUsageTracker.shared.start() }
        if preview && CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        let root: URL
        if preview {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-Preview-\(ProcessInfo.processInfo.processIdentifier)")
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyClip")
        }
        do {
            let model = try MyClipModel(root: root, preview: preview)
            self.model = model
            if !preview {
                let captureHandler = model.captureService.onCapture
                model.captureService.onCapture = { image, context in
                    await captureHandler?(image, context)
                    AppAnalytics.shared.recordActivity()
                }
            }
            model.onOpenWindow = { [weak self] in self?.showWindow() }
            model.onOpenSettings = { [weak self] in self?.showSettingsWindow() }
            menuBar = MyClipMenuBarController(model: model)
            model.start()
            showWindow()
            if !preview { AppUpdater.shared.start() }
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "MyClip 无法打开资料库")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshPermissions() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { AppAnalytics.shared.flush(); model?.stop() }

    /// A language change only reaches the already-resolved bundle after a restart, the same as System Settings'
    /// per-app language. The running instance stops its capture and queue before the new one takes over.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }

    private func showWindow() {
        guard let model else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "MyClip"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 840, height: 580)
            window.contentView = NSHostingView(rootView: MyClipRootView(model: model))
            window.setFrameAutosaveName("MyClipLibraryWindow")
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettingsWindow() {
        guard let model else { return }
        if settingsWindow == nil {
            let settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            settingsWindow.title = String(localized: "设置")
            settingsWindow.toolbarStyle = .preference
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.minSize = NSSize(width: 760, height: 520)
            settingsWindow.contentView = NSHostingView(rootView: MyClipSettingsView(model: model))
            settingsWindow.setFrameAutosaveName("MyClipSettingsWindow")
            settingsWindow.center()
            self.settingsWindow = settingsWindow
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMenus() {
        let bar = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "MyClip")
        let about = appMenu.addItem(withTitle: String(localized: "关于 MyClip"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        let updates = appMenu.addItem(withTitle: String(localized: "检查更新…"), action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = AppUpdater.shared
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: String(localized: "设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let capture = appMenu.addItem(withTitle: String(localized: "暂停采集"), action: #selector(toggleCapture), keyEquivalent: "")
        capture.target = self
        appMenu.addItem(.separator())
        let services = NSMenu(title: String(localized: "服务"))
        let servicesItem = appMenu.addItem(withTitle: String(localized: "服务"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "隐藏 MyClip"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: String(localized: "隐藏其他应用"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "全部显示"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "退出 MyClip"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        bar.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: String(localized: "文件"))
        let newTask = file.addItem(withTitle: String(localized: "新建待办"), action: #selector(createTask), keyEquivalent: "n")
        newTask.target = self
        let revealLibrary = file.addItem(withTitle: String(localized: "在访达中打开资料库"), action: #selector(openLibraryFolder), keyEquivalent: "")
        revealLibrary.target = self
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "关闭"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        bar.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: String(localized: "编辑"))
        edit.addItem(withTitle: String(localized: "撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let search = edit.addItem(withTitle: String(localized: "搜索资料库"), action: #selector(focusSearch), keyEquivalent: "f")
        search.target = self
        editItem.submenu = edit
        bar.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: String(localized: "显示"))
        let sidebar = view.addItem(withTitle: String(localized: "显示或隐藏边栏"), action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: String(localized: "进入全屏"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = view
        bar.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windows = NSMenu(title: String(localized: "窗口"))
        windows.addItem(withTitle: String(localized: "最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: String(localized: "缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        let open = windows.addItem(withTitle: String(localized: "MyClip 资料库"), action: #selector(openLibrary), keyEquivalent: "0")
        open.target = self
        windows.addItem(withTitle: String(localized: "全部置于前面"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windows
        bar.addItem(windowItem)
        NSApp.windowsMenu = windows

        let helpItem = NSMenuItem()
        let help = NSMenu(title: String(localized: "帮助"))
        let openHelp = help.addItem(withTitle: String(localized: "MyClip 帮助"), action: #selector(showHelp), keyEquivalent: "?")
        openHelp.target = self
        helpItem.submenu = help
        bar.addItem(helpItem)
        NSApp.helpMenu = help

        NSApp.mainMenu = bar
    }

    @objc private func showAbout() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func showSettings() { model?.open(.settings) }
    @objc private func openLibrary() { model?.open() }
    @objc private func openLibraryFolder() {
        guard let model else { return }
        NSWorkspace.shared.open(model.store.root)
    }
    @objc private func createTask() { model?.requestNewTask() }
    @objc private func toggleCapture() {
        guard let model else { return }
        if model.showPermissions {
            showWindow()
            NotificationCenter.default.post(name: .init("MyClipShowOnboarding"), object: nil)
        } else {
            model.toggleCapture()
        }
    }
    @objc private func showHelp() {
        guard let url = URL(string: "https://myclip.vibevibe.cc/") else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func focusSearch() {
        showWindow()
        NotificationCenter.default.post(name: .init("MyClipFocusSearch"), object: nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleCapture) {
            if model?.showPermissions == true {
                menuItem.title = String(localized: "设置采集权限…")
            } else if model?.preferences.captureEnabled == true {
                menuItem.title = String(localized: "暂停采集")
            } else {
                menuItem.title = String(localized: "继续采集")
            }
            return model?.preview == false
        }
        if menuItem.action == #selector(focusSearch) {
            return NSApp.keyWindow !== settingsWindow && model?.page?.supportsSearch == true
        }
        return true
    }
}
