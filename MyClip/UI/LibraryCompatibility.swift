import SwiftUI

struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "搜索任务、记忆与截图")
        field.setAccessibilityLabel(field.placeholderString)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if focused, field.currentEditor() == nil {
            DispatchQueue.main.async {
                if context.coordinator.parent.focused { field.window?.makeFirstResponder(field) }
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: LibrarySearchField
        init(_ parent: LibrarySearchField) { self.parent = parent }
        @objc func changed(_ field: NSSearchField) { parent.text = field.stringValue }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if parent.text.isEmpty {
                parent.focused = false
                control.window?.makeFirstResponder(nil)
            } else {
                (control as? NSSearchField)?.stringValue = ""
                parent.text = ""
            }
            return true
        }
    }
}

// The system-image convenience initializer was introduced in macOS 14.
extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Label(title, systemImage: systemImage) }
    }
}

extension View {
    @ViewBuilder func onActivationKey(perform: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onKeyPress(keys: [.space, .return]) { _ in perform(); return .handled }
        } else {
            self
        }
    }

    @ViewBuilder func fillingHorizontalViewport(minWidth: CGFloat) -> some View {
        if #available(macOS 14.0, *) {
            self.containerRelativeFrame(.horizontal) { width, _ in max(width, minWidth) }
        } else {
            self.frame(minWidth: minWidth)
        }
    }
}

struct LibraryUnavailableView: View {
    let title: String
    let systemImage: String
    let description: Text

    init(_ title: String, systemImage: String, description: Text) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            description.foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// AppKit keeps the same reading position on macOS 13 and later.
struct MemoryScrollView<Content: View>: NSViewRepresentable {
    let initialOffset: CGFloat
    let onScroll: (CGFloat) -> Void
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let host = NSHostingView(rootView: DocumentContent(content: content(), width: scroll.contentSize.width))
        host.sizingOptions = [.intrinsicContentSize]
        context.coordinator.host = host
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.host?.rootView = DocumentContent(content: content(), width: scroll.contentSize.width)
        context.coordinator.onScroll = onScroll
        if !context.coordinator.restored {
            context.coordinator.restored = true
            DispatchQueue.main.async {
                scroll.layoutSubtreeIfNeeded()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: initialOffset))
                scroll.reflectScrolledClipView(scroll.contentView)
                context.coordinator.ready = true
            }
        }
    }

    struct DocumentContent: View {
        var content: Content
        var width: CGFloat

        var body: some View { content.frame(width: width) }
    }

    @MainActor final class Coordinator: NSObject {
        weak var host: NSHostingView<DocumentContent>?
        var onScroll: (CGFloat) -> Void
        var restored = false
        var ready = false
        init(onScroll: @escaping (CGFloat) -> Void) { self.onScroll = onScroll }
        @objc func scrolled(_ notification: Notification) {
            guard let clip = notification.object as? NSClipView else { return }
            // Intrinsic height must use the viewport width so wrapped text is fully scrollable.
            if let host, host.rootView.width != clip.bounds.width {
                host.rootView.width = clip.bounds.width
            }
            guard ready else { return }
            onScroll(max(0, clip.bounds.origin.y))
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
