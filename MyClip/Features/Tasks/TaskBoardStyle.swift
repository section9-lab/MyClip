import MyClipCore
import SwiftUI

extension WorkTaskStatus {
    var tint: Color {
        switch self {
        case .candidate, .todo, .ignored: .secondary
        case .doing: .orange
        case .done: .blue
        }
    }
}

/// Shared column styling for the application board and its menu bar preview.
struct TaskBoardColumnBackground: View {
    let status: WorkTaskStatus
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .fill(status == .todo ? Color.primary.opacity(0.035) : status.tint.opacity(colorScheme == .dark ? 0.12 : 0.07))
            }
    }
}
