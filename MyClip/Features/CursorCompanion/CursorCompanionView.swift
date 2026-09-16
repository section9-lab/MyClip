import SwiftUI

struct CursorCompanionView: View {
    let model: CursorCompanionModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let dotSize: CGFloat = 18
    private let followOffset = CGSize(width: 18, height: -9)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

            Circle()
                .fill(Color(red: 0.02, green: 0.22, blue: 1.0))
                .frame(width: dotSize, height: dotSize)
                .scaleEffect(breathingScale(time: time))
                .position(
                    x: model.cursorPosition.x + followOffset.width,
                    y: model.cursorPosition.y + followOffset.height
                )
        }
        .frame(width: model.screenSize.width, height: model.screenSize.height)
        .allowsHitTesting(false)
    }

    private func breathingScale(time: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return 1.0 }
        return 1.0 + CGFloat(sin(time * 2.2)) * 0.1
    }
}
