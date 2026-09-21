import AppKit

@MainActor
final class MyClipMenuBarController: NSObject {
    private let model: MyClipModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(model: MyClipModel) {
        self.model = model
        super.init()
        guard let button = statusItem.button else { return }
        let icon = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "MyClip")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        icon?.isTemplate = true
        button.image = icon
        button.imagePosition = .imageOnly
        button.toolTip = "打开 MyClip"
        button.setAccessibilityLabel("MyClip")
        button.setAccessibilityHelp("打开 MyClip 资料库")
        button.target = self
        button.action = #selector(openLibrary)
    }

    @objc private func openLibrary() { model.open() }
}
