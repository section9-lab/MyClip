import Foundation
import MyClipCore

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
