import Foundation

/// The real-time pipeline. A batch only records what its screenshots show into the local day's Daily pages; the
/// hourly digest (`digestPrompt`) is the only writer of Wiki knowledge, the root files, the board and the calendar.
public enum DayPrompt {
    /// One line per screenshot, in the same shape the organizing prompt uses so both pipelines cite the same way.
    static func sources(_ captures: [ClipCapture], timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return captures.enumerated().map { index, capture in
            PromptLibrary.render("generation/daily-source", [
                "index": String(index + 1),
                "sourceID": capture.id.uuidString,
                "app": capture.appName,
                "window": capture.windowTitle,
                "date": formatter.string(from: capture.date),
                "trigger": capture.reason.rawValue
            ])
        }.joined(separator: "\n\n")
    }

    public static func daily(captures: [ClipCapture], handoff: String? = nil, previousAttempt: String? = nil) -> String {
        let timeZone = TimeZone.current
        let retry = previousAttempt.map {
            "\n" + PromptLibrary.render("generation/retry-daily", ["error": $0]) + "\n"
        } ?? ""
        return PromptLibrary.render("generation/daily", [
            "sandbox": MemoryRules.sandboxScope,
            "dataRule": MemoryRules.dataNotInstructionsTail,
            "dailyPathPattern": MemoryRules.dailyPathPattern,
            "dailyWriting": MemoryRules.dailyWriting,
            "retry": retry,
            "handoff": handoff ?? PromptLibrary.text("shared/none"),
            "timezone": timeZone.identifier,
            "sources": sources(captures, timeZone: timeZone)
        ])
    }

    public static func digest(dailies: [String], handoff: String? = nil, previousAttempt: String? = nil,
                              board: [WorkTask] = [], calendar: [CalendarEvent] = []) -> String {
        let retry = previousAttempt.map {
            "\n" + PromptLibrary.render("generation/retry-digest", ["error": $0]) + "\n"
        } ?? ""
        let existingBoard = board.filter { $0.status != .ignored }.prefix(120).map { task in
            ["id": task.id.uuidString, "title": task.title, "project": task.project, "status": task.status.rawValue]
        }
        let existingCalendar = calendar.prefix(120).map { event in
            ["id": event.id.uuidString, "title": event.title, "start": event.start.ISO8601Format(),
             "end": event.end.ISO8601Format(), "allDay": String(event.isAllDay), "kind": event.kind.rawValue]
        }
        let boardJSON = String(decoding: (try? JSONEncoder().encode(existingBoard)) ?? Data("[]".utf8), as: UTF8.self)
        let calendarJSON = String(decoding: (try? JSONEncoder().encode(existingCalendar)) ?? Data("[]".utf8), as: UTF8.self)
        return PromptLibrary.render("generation/digest", [
            "sandbox": MemoryRules.sandboxScope,
            "dataRule": MemoryRules.dataNotInstructionsTail,
            "dailies": dailies.map { "- \($0)" }.joined(separator: "\n"),
            "reviewWriting": MemoryRules.reviewWriting,
            "boardJSON": boardJSON,
            "calendarJSON": calendarJSON,
            "retry": retry,
            "handoff": handoff ?? PromptLibrary.text("shared/none")
        ])
    }
}
