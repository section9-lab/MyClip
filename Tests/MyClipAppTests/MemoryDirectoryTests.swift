@testable import MyClip
import AppKit
import SwiftUI
import MyClipCore
@main
struct MemoryDirectoryTests {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-DirectoryTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try MyClipModel(root: root, preview: true)
        defer { model.stop() }
        let note = root.appendingPathComponent("Memory/Wiki/Projects/Detail.md")
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Memory/Empty"), withIntermediateDirectories: true)
        try "# Nested document\n\nDirectory selection fixture.".write(to: note, atomically: true, encoding: .utf8)
        try await model.store.synchronizeMemoryFiles()
        await model.refresh()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: KnowledgeLibraryView(model: model))

        func settle() async {
            for _ in 0..<20 {
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable(in: $0) }.first
        }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            fflush(stdout)
            if !condition { failures += 1 }
        }
        await settle()
        guard let table = findTable(in: window.contentView!) else {
            throw LibraryError.invalidResult("Memory directory did not create a native table")
        }
        let nodes = MemoryFileNode.tree(model.library)
        var rows = nodes
        print("Native directory: \(type(of: table)), \(table.numberOfRows) rows")
        check(table.numberOfRows == nodes.count, "Directory initially shows its root files and folders")

        func select(_ path: String) async {
            guard let row = rows.firstIndex(where: { $0.id == path }) else {
                check(false, "Fixture contains \(path)")
                return
            }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await settle()
            let node = rows[row]
            if let entry = node.entry {
                check(model.selectedEntry == entry.id, "Selecting \(path) switches the document")
            } else {
                check(model.selectedEntry == nil && model.memoryFolder == path, "Selecting \(path) switches to the folder")
            }
            check(table.selectedRow == row, "\(path) remains highlighted after the selection update")
        }
        await select("Now.md")
        await select("Profile.md")
        await select("Wiki")
        await select("Memory.md")
        await select("Empty")
        model.search = "fixture"
        await settle()
        await select("Now.md")
        check(model.search.isEmpty, "Selecting a directory file clears search")
        if let outline = table as? NSOutlineView {
            func flattened(_ nodes: [MemoryFileNode]) -> [MemoryFileNode] {
                nodes.flatMap { [$0] + flattened($0.children ?? []) }
            }
            let wikiRow = nodes.firstIndex { $0.id == "Wiki" }!
            outline.expandItem(outline.item(atRow: wikiRow))
            await settle()
            // SwiftUI creates child rows lazily; other Wiki folders can sort before Projects.
            let projectsIndex = nodes[wikiRow].children!.firstIndex { $0.id == "Wiki/Projects" }!
            outline.expandItem(outline.item(atRow: wikiRow + 1 + projectsIndex))
            await settle()
            rows = flattened(nodes)
            check(table.numberOfRows == rows.count, "Expanding folders reveals nested files")
            await select("Wiki/Projects/Detail.md")
            await select("Wiki/Projects")
            outline.collapseItem(outline.item(atRow: wikiRow))
            await settle()
            rows = nodes
            check(table.numberOfRows == rows.count, "Collapsing a folder hides its descendants")
            await select("Profile.md")
        } else {
            check(false, "Directory supports native folder expansion")
        }
        print("Memory directory checks: \(failures) failure(s)")
        if failures > 0 { exit(1) }
    }
}
