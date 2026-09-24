import AppKit
import SwiftUI
import MyClipCore

@MainActor
final class MyClipAppDelegate: NSObject, NSApplicationDelegate {
    private var model: MyClipModel?
    private var window: NSWindow?
    private var menuBar: MyClipMenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ProcessInfo.processInfo.disableAutomaticTermination("MyClip keeps its menu bar and capture queue available")
        installMenus()
        let preview = CommandLine.arguments.contains("--preview")
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
            model.onOpenWindow = { [weak self] in self?.showWindow() }
            menuBar = MyClipMenuBarController(model: model)
            model.start()
            showWindow()
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
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }

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

    private func installMenus() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "MyClip")
        let about = appMenu.addItem(withTitle: String(localized: "关于 MyClip"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: String(localized: "设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "隐藏 MyClip"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "退出 MyClip"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: String(localized: "编辑"))
        edit.addItem(withTitle: String(localized: "撤销"), action: Selector(("undo:")), keyEquivalent: "z")
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
        let windowItem = NSMenuItem()
        let windows = NSMenu(title: String(localized: "窗口"))
        let open = windows.addItem(withTitle: String(localized: "MyClip 资料库"), action: #selector(openLibrary), keyEquivalent: "0")
        open.target = self
        windows.addItem(withTitle: String(localized: "最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: String(localized: "关闭"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windows
        bar.addItem(windowItem)
        NSApp.windowsMenu = windows
        NSApp.mainMenu = bar
    }

    @objc private func showAbout() { NSApp.orderFrontStandardAboutPanel(options: [.version: ""]) }
    @objc private func showSettings() { model?.open(.settings) }
    @objc private func openLibrary() { model?.open() }
    @objc private func focusSearch() {
        showWindow()
        NotificationCenter.default.post(name: .init("MyClipFocusSearch"), object: nil)
    }
}
