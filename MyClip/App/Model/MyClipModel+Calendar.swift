import Foundation
import MyClipCore

extension MyClipModel {
    /// Memory synchronization is page-scoped and throttled: the background worker must not read every
    /// Memory file on each tick. Opening the page forces one pass so new annotations appear immediately.
    func refreshCalendar(force: Bool = false) async {
        do {
            let versions = try await store.refreshVersions()
            let due = force || lastCalendarSync == .distantPast || Date().timeIntervalSince(lastCalendarSync) >= 60
            let libraryChanged = lastCalendarLibraryVersion != versions.library
            guard (due && libraryChanged) || force || !calendarLoaded || calendarLoadError != nil
                    || lastCalendarVersion != versions.calendar else { return }
            if due && (libraryChanged || force) {
                try await store.synchronizeCalendarEvents()
                lastCalendarSync = Date()
            }
            let next = try await store.calendarEvents()
            if calendarEvents != next { calendarEvents = next }
            if calendarLoadError != nil { calendarLoadError = nil }
            calendarLoaded = true
            lastCalendarVersion = try await store.refreshVersions().calendar
            lastCalendarLibraryVersion = versions.library
        } catch {
            if calendarLoadError != error.localizedDescription { calendarLoadError = error.localizedDescription }
        }
    }

    func saveCalendarEvent(id: UUID?, draft: CalendarEventDraft) async throws -> UUID {
        let saved: UUID
        if let id {
            try await store.updateCalendarEvent(id, draft)
            saved = id
        } else {
            saved = try await store.createCalendarEvent(draft)
        }
        await refreshCalendar(force: true)
        return saved
    }

    func dismissCalendarEvent(_ id: UUID) {
        Task {
            do {
                try await store.dismissCalendarEvent(id)
                await refreshCalendar(force: true)
            } catch { notice = error.localizedDescription }
        }
    }
}
