import MyClipCore
import SwiftUI

extension CalendarEventKind {
    var tint: Color {
        switch self {
        case .meeting: .blue
        case .travel: .teal
        case .deadline: .orange
        case .other: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .meeting: "person.2"
        case .travel: "airplane"
        case .deadline: "flag"
        case .other: "calendar"
        }
    }
}
