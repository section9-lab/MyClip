import Foundation
import MyClipCore

extension MyClipModel {
    func setTaskStatus(_ id: UUID, _ status: WorkTaskStatus) {
        guard !updatingTaskIDs.contains(id) else { return }
        updatingTaskIDs.insert(id)
        Task {
            defer { updatingTaskIDs.remove(id) }
            do {
                try await store.setWorkTaskStatus(id, status: status)
                if lastTaskReview?.taskID == id { lastTaskReview = nil }
                await refresh()
            }
            catch { notice = error.localizedDescription }
        }
    }

    func reviewTask(_ id: UUID, _ status: WorkTaskStatus) {
        guard !updatingTaskIDs.contains(id) else { return }
        updatingTaskIDs.insert(id)
        Task {
            defer { updatingTaskIDs.remove(id) }
            do {
                lastTaskReview = try await store.reviewWorkTask(id, status: status)
                await refresh()
            } catch { notice = error.localizedDescription }
        }
    }

    func undoTaskReview() {
        guard let review = lastTaskReview, !updatingTaskIDs.contains(review.taskID) else { return }
        updatingTaskIDs.insert(review.taskID)
        Task {
            defer { updatingTaskIDs.remove(review.taskID) }
            do {
                try await store.undoWorkTaskReview(review)
                if lastTaskReview?.taskID == review.taskID { lastTaskReview = nil }
                await refresh()
            } catch { notice = error.localizedDescription }
        }
    }

    func saveTask(id: UUID?, title: String, project: String, waitingReason: String) async throws -> UUID {
        let saved: UUID
        if let id { try await store.updateWorkTask(id, title: title, project: project, waitingReason: waitingReason); saved = id }
        else { saved = try await store.createWorkTask(title: title, project: project, waitingReason: waitingReason) }
        if lastTaskReview?.taskID == saved { lastTaskReview = nil }
        await refresh()
        return saved
    }
}
