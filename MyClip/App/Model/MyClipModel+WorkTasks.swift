import Foundation
import MyClipCore

extension MyClipModel {
    func retryTaskIngestionFailures() {
        guard canStartOrganization else { return }
        Task {
            do {
                try await store.retryFailedTaskIngestions()
                await refresh()
                await processNext(immediately: true)
            } catch { notice = error.localizedDescription }
        }
    }

    func setTaskStatus(_ id: UUID, _ status: WorkTaskStatus) {
        guard !updatingTaskIDs.contains(id) else { return }
        updatingTaskIDs.insert(id)
        Task {
            defer { updatingTaskIDs.remove(id) }
            do {
                try await store.setWorkTaskStatus(id, status: status)
                await refresh()
            }
            catch { notice = error.localizedDescription }
        }
    }

    func saveTask(id: UUID?, title: String, project: String, waitingReason: String) async throws -> UUID {
        let saved: UUID
        if let id { try await store.updateWorkTask(id, title: title, project: project, waitingReason: waitingReason); saved = id }
        else { saved = try await store.createWorkTask(title: title, project: project, waitingReason: waitingReason) }
        await refresh()
        return saved
    }
}
