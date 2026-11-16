import Foundation

public enum CalendarEventKind: String, Codable, CaseIterable, Sendable {
    case meeting, travel, deadline, other

    public var title: String {
        switch self {
        case .meeting: String(localized: "会议")
        case .travel: String(localized: "出行")
        case .deadline: String(localized: "截止")
        case .other: String(localized: "日程")
        }
    }
}

public enum CalendarEventOrigin: String, Codable, Sendable {
    /// Created or confirmed by the user.
    case user
    /// Projected from a dated Memory passage (`myclip-event`).
    case memory
}

public enum CalendarEventState: String, Codable, Sendable {
    case scheduled, dismissed
}

public struct CalendarEvent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let notes: String
    public let location: String
    public let project: String
    public let kind: CalendarEventKind
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let state: CalendarEventState
    public let origin: CalendarEventOrigin
    /// Verbatim Memory passage that supports this event; empty for manual events.
    public let evidence: String
    public let memoryID: UUID?
    public let memoryPath: String?
    public let taskID: UUID?
    /// A user edit pins the event, so later Memory synchronization leaves it alone.
    public let edited: Bool

    public init(id: UUID, title: String, notes: String, location: String, project: String,
                kind: CalendarEventKind, start: Date, end: Date, isAllDay: Bool,
                state: CalendarEventState = .scheduled, origin: CalendarEventOrigin,
                evidence: String = "", memoryID: UUID? = nil, memoryPath: String? = nil,
                taskID: UUID? = nil, edited: Bool = false) {
        self.id = id
        self.title = title
        self.notes = notes
        self.location = location
        self.project = project
        self.kind = kind
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.state = state
        self.origin = origin
        self.evidence = evidence
        self.memoryID = memoryID
        self.memoryPath = memoryPath
        self.taskID = taskID
        self.edited = edited
    }

    public var projectTitle: String { project.isEmpty ? String(localized: "未归类") : project }
}

public struct CalendarEventDraft: Sendable, Equatable {
    public var title: String
    public var notes: String
    public var location: String
    public var project: String
    public var kind: CalendarEventKind
    public var start: Date
    public var end: Date
    public var isAllDay: Bool

    public init(title: String = "", notes: String = "", location: String = "", project: String = "",
                kind: CalendarEventKind = .other, start: Date, end: Date, isAllDay: Bool = false) {
        self.title = title
        self.notes = notes
        self.location = location
        self.project = project
        self.kind = kind
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }

    public init(event: CalendarEvent) {
        self.init(title: event.title, notes: event.notes, location: event.location, project: event.project,
                  kind: event.kind, start: event.start, end: event.end, isAllDay: event.isAllDay)
    }
}
