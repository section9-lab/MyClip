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
        let original = model.library.entries.first { $0.relativePath == "Wiki/Projects/Detail.md" }!
        try await model.store.updateEntry(id: original.id, title: original.title, body: "# Updated document\n\nNewly saved memory.", expectedRevision: original.revision)
        await model.refresh()
        model.search = "old search"
        model.memoryFolder = "Wiki"
        model.openMemoryEntry(original.id)
        check(model.page == .memory && model.selectedEntry == original.id, "A saved-file result opens its Memory document")
        check(model.search.isEmpty && model.memoryFolder == nil, "Opening a saved file clears the previous search and folder")
        model.results.entries = [original] // An older in-flight search can finish after the document opens.
        check(model.selectedMemoryEntry?.body.contains("Newly saved memory") == true, "The reader prefers the saved revision over a stale search result")

        let staleProfile = model.library.entries.first { $0.relativePath == "Profile.md" }!
        try await model.store.updateEntry(id: staleProfile.id, title: staleProfile.title,
                                          body: staleProfile.body + "\n\n后台更新。", expectedRevision: staleProfile.revision)
        model.notice = nil
        let draft = staleProfile.body + "\n\n编辑器中的草稿。"
        let firstSave = await model.saveMemory(id: staleProfile.id, title: staleProfile.title, body: draft,
                                               expectedRevision: staleProfile.revision)
        if case .conflict(let latest) = firstSave {
            check(latest.revision == staleProfile.revision + 1, "A stale editor receives the latest revision instead of a repeating global alert")
            check(model.notice == nil, "A normal edit conflict stays inside the editor")
            let retry = await model.saveMemory(id: staleProfile.id, title: staleProfile.title, body: draft,
                                               expectedRevision: latest.revision)
            if case .saved = retry { check(true, "The preserved draft can be saved deliberately as a new version") }
            else { check(false, "The preserved draft can be saved deliberately as a new version") }
            let final = try await model.store.readMemory(staleProfile.id)
            check(final.body == draft && final.revision == staleProfile.revision + 2,
                  "Resolving the conflict preserves history and publishes the chosen draft")
        } else {
            check(false, "A stale editor receives the latest revision instead of a repeating global alert")
        }
        print("Memory directory checks: \(failures) failure(s)")
        if failures > 0 { exit(1) }
    }
}
