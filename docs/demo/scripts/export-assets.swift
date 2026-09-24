// Exports the installed apps' icons and native system symbols; does not control the UI.
import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
func save(_ source: NSImage, name: String, size: Int) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = min(CGFloat(size) / source.size.width, CGFloat(size) / source.size.height)
    let rect = NSRect(x: (CGFloat(size) - source.size.width * scale) / 2,
                      y: (CGFloat(size) - source.size.height * scale) / 2,
                      width: source.size.width * scale, height: source.size.height * scale)
    source.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
}
let apps = CommandLine.arguments.contains("--share") ? [
    ("feishu", "/Applications/Lark.app"),
    ("lark", "/Applications/LarkSuite.app"),
    ("dingtalk", "/Applications/DingTalk.app"),
    ("wechat", "/Applications/WeChat.app"),
    ("slack", "/Applications/Slack.app")
] : [
    ("finder", "/System/Library/CoreServices/Finder.app"),
    ("safari", "/Applications/Safari.app"),
    ("notes", "/System/Applications/Notes.app"),
    ("settings", "/System/Applications/System Settings.app"),
    ("codex", "/Applications/ChatGPT.app"),
    ("claude", "/Applications/Claude.app")
]
for (name, path) in apps {
    try save(NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path), name: name, size: 256)
}
if CommandLine.arguments.contains("--share") { exit(0) }
for name in ["apple.logo", "wifi", "battery.100", "switch.2", "magnifyingglass", "paperclip", "sidebar.left", "square.and.pencil", "plus", "chevron.down", "arrow.up", "doc.text", "folder", "ellipsis", "gearshape", "command"] {
    if let icon = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular)) {
        try save(icon, name: name, size: 64)
    }
}
if let trash = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/TrashIcon.icns") {
    try save(trash, name: "trash", size: 256)
}
