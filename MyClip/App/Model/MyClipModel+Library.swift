import Foundation
import MyClipCore

enum MemorySaveOutcome {
    case saved
    case conflict(KnowledgeEntry)
    case failed
}

extension MyClipModel {
    var selectedMemoryEntry: KnowledgeEntry? {
        (library.entries + results.entries).first { $0.id == selectedEntry }
    }

    func openMemoryEntry(_ id: UUID) {
        search = ""
        memoryFolder = nil
        selectedEntry = id
        open(.memory)
    }

    func saveMemory(id: UUID, title: String, body: String, expectedRevision: Int) async -> MemorySaveOutcome {
        do {
            try await store.updateEntry(id: id, title: title, body: body, expectedRevision: expectedRevision)
            await refresh()
            return .saved
        } catch LibraryError.conflict {
            do {
                let latest = try await store.readMemory(id)
                await refresh()
                return .conflict(latest)
            } catch {
                notice = error.localizedDescription
                return .failed
            }
        } catch {
            notice = error.localizedDescription
            return .failed
        }
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
