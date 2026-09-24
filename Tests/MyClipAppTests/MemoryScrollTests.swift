@testable import MyClip
import AppKit
import SwiftUI

@MainActor private final class Document: ObservableObject {
    @Published var paragraphs = 24
    var first: NSView?
    var last: NSView?
    var savedOffset: CGFloat = 0

    var markdown: String {
        (0..<paragraphs).map { index in
            "## 第 \(index + 1) 节\n\n- " + String(repeating: "中文长段落需要根据阅读区域的实际宽度完整换行。**Markdown** content must remain reachable after resizing the window. ", count: 6)
        }.joined(separator: "\n\n")
    }
}

private struct Marker: NSViewRepresentable {
    let report: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        report(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct Reader: View {
    @ObservedObject var document: Document
    var initialOffset: CGFloat = 0

    var body: some View {
        MemoryScrollView(initialOffset: initialOffset, onScroll: { document.savedOffset = $0 }) {
            VStack(alignment: .leading, spacing: 28) {
                Text("文档开头")
                    .background(Marker { document.first = $0 })
                MemoryMarkdownView(markdown: document.markdown, baseURL: FileManager.default.temporaryDirectory)
                Text("文档结尾")
                    .background(Marker { document.last = $0 })
            }
            .padding(32).frame(maxWidth: 840).frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

@main
struct MemoryScrollTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let document = Document()
        var expectedWidth: CGFloat = 520
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: Reader(document: document))

        func settle() {
            let deadline = Date().addingTimeInterval(0.3)
            repeat {
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < deadline
        }
        func findScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll(in: $0) }.first
        }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        settle()
        var scroll = findScroll(in: window.contentView!)!
        var host = scroll.documentView!
        func checkEntireDocument(_ context: String) {
            check(abs(scroll.frame.width - expectedWidth) < 1, "\(context): reader fills the window width")
            check(host.bounds.width >= expectedWidth - 20, "\(context): document uses the available width")
            let first = document.first!.convert(document.first!.bounds, to: host)
            let last = document.last!.convert(document.last!.bounds, to: host)
            print("\(context): document=\(host.frame), first=\(first), last=\(last), visible=\(scroll.documentVisibleRect)")
            check(first.minY >= 0, "\(context): document start is inside the scrollable area")
            check(last.maxY <= host.bounds.maxY + 1, "\(context): document end is inside the scrollable area")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle()
            check(scroll.documentVisibleRect.contains(document.first!.convert(document.first!.bounds, to: host)), "\(context): scrolling to the top reveals the start")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, host.bounds.height - scroll.contentSize.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle()
            check(scroll.documentVisibleRect.contains(document.last!.convert(document.last!.bounds, to: host)), "\(context): scrolling to the bottom reveals the end")
        }
        checkEntireDocument("Long document at 520 pt")
        expectedWidth = 360
        window.setContentSize(NSSize(width: expectedWidth, height: 480))
        settle()
        checkEntireDocument("Long document at 360 pt")
        expectedWidth = 1000
        window.setContentSize(NSSize(width: expectedWidth, height: 640))
        settle()
        checkEntireDocument("Long document at 1000 pt")

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        check(abs(document.savedOffset - 900) < 1, "Scrolling saves the reading position")
        window.contentView = NSHostingView(rootView: Reader(document: document, initialOffset: document.savedOffset))
        settle()
        scroll = findScroll(in: window.contentView!)!
        host = scroll.documentView!
        // Restoration is asynchronous and may outlast a layout pass on busy CI runners.
        let restoreDeadline = Date().addingTimeInterval(5)
        while abs(scroll.documentVisibleRect.minY - 900) >= 1 && Date() < restoreDeadline {
            settle()
        }
        check(abs(scroll.documentVisibleRect.minY - 900) < 1, "Reopening restores the saved position after layout")
        checkEntireDocument("Reopened document")

        document.paragraphs = 1
        settle()
        checkEntireDocument("Shortened document")
        document.paragraphs = 32
        settle()
        checkEntireDocument("Expanded document")
        print("Memory scrolling checks: \(failures) failure(s)")
        if failures > 0 { exit(1) }
    }
}
