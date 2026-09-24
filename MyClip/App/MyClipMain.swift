import AppKit
import MyClipCore

@main
@MainActor
enum MyClipMain {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            Task.detached {
                await MemoryMCP.run(arguments: CommandLine.arguments)
                exit(0)
            }
            dispatchMain()
        }
        // Before AppKit exists, so the bundle has not resolved its language yet.
        AppLanguage.applyAtLaunch()
        let app = NSApplication.shared
        let delegate = MyClipAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
