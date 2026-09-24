import Foundation
import MyClipCore

extension MyClipModel {
    func save(_ entry: KnowledgeEntry, title: String, body: String) async -> Bool {
        do {
            try await store.updateEntry(id: entry.id, title: title, body: body, expectedRevision: entry.revision)
            await refresh()
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    func delete(_ entry: KnowledgeEntry) {
        Task {
            do {
                try await store.deleteEntry(id: entry.id)
                if selectedEntry == entry.id { selectedEntry = nil }
                await refresh()
            } catch { notice = error.localizedDescription }
        }
    }

    func move(_ entry: KnowledgeEntry, to path: String) async -> Bool {
        do {
            try await store.moveMemory(entry.id, to: path, expectedRevision: entry.revision)
            await refresh()
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    func openMemoryLink(_ url: URL) {
        guard url.scheme == "myclip-memory" else { return }
        let target = String(url.path(percentEncoded: false).dropFirst())
        Task {
            do {
                let entry = try await store.resolveMemoryLink(target)
                if !library.entries.contains(where: { $0.id == entry.id }) { library.entries.append(entry) }
                selectedEntry = entry.id
            } catch { notice = error.localizedDescription }
        }
    }

    func rebuildIndex() {
        Task {
            do { try await store.rebuildSearchIndex(); await refresh(); notice = String(localized: "搜索索引已重建。") }
            catch { notice = error.localizedDescription }
        }
    }

    func cleanupIfNeeded() async {
        guard Date().timeIntervalSince(lastCleanup) > 3600 else { return }
        lastCleanup = Date()
        guard preferences.retentionDays > 0 else { return }
        do {
            try await store.expireImages(before: Date().addingTimeInterval(-Double(preferences.retentionDays) * 86_400))
            await refresh()
        } catch { notice = error.localizedDescription }
    }
}
