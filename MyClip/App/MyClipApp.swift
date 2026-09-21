import AppKit
import SwiftUI
import MyClipCore

@main
@MainActor
final class MyClipAppDelegate: NSObject, NSApplicationDelegate {
    private var model: MyClipModel?
    private var window: NSWindow?
    private var menuBar: MyClipMenuBarController?

    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            Task.detached {
                await MemoryMCP.run(arguments: CommandLine.arguments)
                exit(0)
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        let delegate = MyClipAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

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
            alert.messageText = "MyClip 无法打开资料库"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshPermissions() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
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
            window.contentView = NSHostingView(rootView: MyClipRootView(model: model).environment(\.locale, Locale(identifier: "zh_Hans_CN")))
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
        appMenu.addItem(withTitle: "关于 MyClip", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 MyClip", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 MyClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let search = edit.addItem(withTitle: "搜索资料库", action: #selector(focusSearch), keyEquivalent: "f")
        search.target = self
        editItem.submenu = edit
        bar.addItem(editItem)
        let windowItem = NSMenuItem()
        let windows = NSMenu(title: "窗口")
        let open = windows.addItem(withTitle: "MyClip 资料库", action: #selector(openLibrary), keyEquivalent: "0")
        open.target = self
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windows
        bar.addItem(windowItem)
        NSApp.windowsMenu = windows
        NSApp.mainMenu = bar
    }

    @objc private func showSettings() { model?.open(.settings) }
    @objc private func openLibrary() { model?.open() }
    @objc private func focusSearch() {
        showWindow()
        NotificationCenter.default.post(name: .init("MyClipFocusSearch"), object: nil)
    }
}
