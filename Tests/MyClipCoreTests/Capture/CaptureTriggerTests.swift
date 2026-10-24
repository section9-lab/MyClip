import XCTest
@testable import MyClipCore

final class CaptureTriggerTests: XCTestCase {
    func testPointerMovementAndStillnessAloneDoNotTriggerCapture() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 100)
        XCTAssertNil(trigger.poll(at: 101))
        XCTAssertNil(trigger.poll(at: 200))
    }

    func testClickWithoutMovementDoesNotTriggerCapture() {
        var trigger = CaptureTrigger()
        XCTAssertFalse(trigger.press(at: 100))
        XCTAssertFalse(trigger.click(at: 100.25))
        XCTAssertNil(trigger.poll(at: 102))
    }

    func testClickImmediatelyAfterPointerMovementTriggersCapture() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        XCTAssertTrue(trigger.press(at: 10))
        XCTAssertTrue(trigger.click(at: 10.25))
        XCTAssertNil(trigger.poll(at: 10.749))
        XCTAssertEqual(trigger.poll(at: 10.75), .clickAfterIdle)
        XCTAssertNil(trigger.poll(at: 20))
    }

    func testHoldingAnExpiredClickDoesNotTriggerCapture() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        XCTAssertFalse(trigger.press(at: 15.001))
        XCTAssertFalse(trigger.click(at: 16))
        XCTAssertNil(trigger.poll(at: 20))
    }

    func testClickAtFiveSecondBoundaryCapturesAfterDoubleClickWindow() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        XCTAssertTrue(trigger.press(at: 15))
        XCTAssertTrue(trigger.click(at: 15.25))
        XCTAssertNil(trigger.poll(at: 15.749))
        XCTAssertEqual(trigger.poll(at: 15.75), .clickAfterIdle)
        XCTAssertNil(trigger.poll(at: 20))
    }

    func testNewMovementRestartsTheFiveSecondClickWindow() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        XCTAssertFalse(trigger.press(at: 15.001))
        XCTAssertFalse(trigger.click(at: 15.25))
        trigger.activity(at: 16)
        XCTAssertTrue(trigger.press(at: 16.5))
        XCTAssertTrue(trigger.click(at: 16.75))
        XCTAssertEqual(trigger.poll(at: 17.25), .clickAfterIdle)
    }

    func testDoubleClickProducesOneCaptureAfterTheLastRelease() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        XCTAssertTrue(trigger.press(at: 12))
        XCTAssertTrue(trigger.click(at: 12.25))
        XCTAssertTrue(trigger.press(at: 12.5, clickCount: 2))
        XCTAssertTrue(trigger.click(at: 12.625))
        XCTAssertNil(trigger.poll(at: 12.75))
        XCTAssertEqual(trigger.poll(at: 13.125), .clickAfterIdle)
        XCTAssertNil(trigger.poll(at: 20))
    }

    func testDoubleClickDoesNotBypassAnExpiredMovement() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        XCTAssertFalse(trigger.press(at: 15.25))
        XCTAssertFalse(trigger.click(at: 15.5))
        XCTAssertFalse(trigger.press(at: 15.625, clickCount: 2))
        XCTAssertFalse(trigger.click(at: 15.75))
        XCTAssertNil(trigger.poll(at: 20))
    }

    func testDoubleClickCanFinishAfterTheFiveSecondMovementWindow() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        XCTAssertTrue(trigger.press(at: 15))
        XCTAssertTrue(trigger.click(at: 15.25))
        XCTAssertTrue(trigger.press(at: 15.5, clickCount: 2))
        XCTAssertTrue(trigger.click(at: 15.625))
        XCTAssertNil(trigger.poll(at: 15.75))
        XCTAssertEqual(trigger.poll(at: 16.125), .clickAfterIdle)
        XCTAssertNil(trigger.poll(at: 20))
    }

    func testPendingSingleClickDoesNotFireWhileSecondClickIsHeld() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        trigger.press(at: 12)
        trigger.click(at: 12.25)
        XCTAssertTrue(trigger.press(at: 12.5, clickCount: 2))
        XCTAssertNil(trigger.poll(at: 13))
        XCTAssertTrue(trigger.click(at: 14))
        XCTAssertEqual(trigger.poll(at: 14.5), .clickAfterIdle)
    }

    func testClickUsesTheProvidedSystemDoubleClickInterval() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        trigger.press(at: 12)
        trigger.click(at: 12.25, doubleClickInterval: 0.75)
        XCTAssertNil(trigger.poll(at: 12.75))
        XCTAssertEqual(trigger.poll(at: 13), .clickAfterIdle)
    }

    func testStationaryRepeatedClickCannotStartAnotherCapture() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        trigger.press(at: 12)
        trigger.click(at: 12.25)
        XCTAssertFalse(trigger.press(at: 12.5))
        XCTAssertFalse(trigger.click(at: 12.625))
        XCTAssertEqual(trigger.poll(at: 12.75), .clickAfterIdle)
        XCTAssertFalse(trigger.press(at: 14))
        XCTAssertFalse(trigger.click(at: 14.25))
        XCTAssertNil(trigger.poll(at: 20))
    }

    func testMovementAfterClickStartsANewSequenceWithoutDelayingPendingCapture() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        trigger.press(at: 12)
        trigger.click(at: 12.25)
        trigger.activity(at: 12.5)
        XCTAssertEqual(trigger.poll(at: 12.75), .clickAfterIdle)
        XCTAssertTrue(trigger.press(at: 13.5))
        XCTAssertTrue(trigger.click(at: 13.75))
        XCTAssertEqual(trigger.poll(at: 14.25), .clickAfterIdle)
    }

    func testDraggingAfterPressDoesNotBecomeAClickCapture() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        trigger.press(at: 12)
        trigger.activity(at: 12.25)
        XCTAssertFalse(trigger.click(at: 15))
        XCTAssertNil(trigger.poll(at: 20))
    }

    func testReleaseWithoutAPressDoesNotTriggerCapture() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        XCTAssertFalse(trigger.click(at: 12))
        XCTAssertNil(trigger.poll(at: 20))
    }

    func testDownwardScrollingFiresOnceAfterFiveSecondsWithoutPointerMovementOrClick() {
        var trigger = CaptureTrigger()
        trigger.scroll(at: 100, deltaY: -1)
        XCTAssertNil(trigger.poll(at: 103))
        XCTAssertNil(trigger.poll(at: 104.999))
        XCTAssertEqual(trigger.poll(at: 105), .scrollIdle)
        XCTAssertNil(trigger.poll(at: 200))
    }

    func testContinuedScrollingRestartsTheDeadline() {
        var trigger = CaptureTrigger()
        trigger.scroll(at: 10, deltaY: -1)
        trigger.scroll(at: 11.5, deltaY: -1)
        XCTAssertNil(trigger.poll(at: 15))
        XCTAssertNil(trigger.poll(at: 16.499))
        XCTAssertEqual(trigger.poll(at: 16.5), .scrollIdle)
    }

    func testUpwardAndHorizontalScrollingDoNotTriggerCapture() {
        for deltaY in [1.0, 0.0] {
            var trigger = CaptureTrigger()
            XCTAssertFalse(trigger.scroll(at: 10, deltaY: deltaY))
            XCTAssertNil(trigger.poll(at: 13))
            XCTAssertNil(trigger.poll(at: 20))
        }
    }

    func testUpwardOrHorizontalScrollingCancelsPendingScrollCapture() {
        for deltaY in [1.0, 0.0] {
            var trigger = CaptureTrigger()
            XCTAssertTrue(trigger.scroll(at: 10, deltaY: -0.25))
            XCTAssertFalse(trigger.scroll(at: 12, deltaY: deltaY))
            XCTAssertNil(trigger.poll(at: 13))
            XCTAssertNil(trigger.poll(at: 20))
        }
    }

    func testDownwardScrollingCanRestartAfterADirectionChange() {
        var trigger = CaptureTrigger()
        XCTAssertTrue(trigger.scroll(at: 10, deltaY: -1))
        XCTAssertFalse(trigger.scroll(at: 11, deltaY: 1))
        XCTAssertTrue(trigger.scroll(at: 12, deltaY: -0.25))
        XCTAssertNil(trigger.poll(at: 16.999))
        XCTAssertEqual(trigger.poll(at: 17), .scrollIdle)
    }

    func testUpwardAndHorizontalScrollingPreservePendingClickCapture() {
        for deltaY in [1.0, 0.0] {
            var trigger = CaptureTrigger()
            trigger.activity(at: 10)
            trigger.press(at: 12)
            trigger.click(at: 12.25)
            XCTAssertFalse(trigger.scroll(at: 12.5, deltaY: deltaY))
            XCTAssertEqual(trigger.poll(at: 12.75), .clickAfterIdle)
            XCTAssertNil(trigger.poll(at: 20))
        }
    }

    func testScrollingDoesNotQualifyAsPointerMovementForClick() {
        var trigger = CaptureTrigger()
        trigger.scroll(at: 10, deltaY: -1)
        XCTAssertFalse(trigger.press(at: 11))
        XCTAssertFalse(trigger.click(at: 11.25))
        XCTAssertEqual(trigger.poll(at: 15), .scrollIdle)
    }

    func testPointerMovementDoesNotPostponeScrollCapture() {
        var trigger = CaptureTrigger()
        trigger.scroll(at: 10, deltaY: -1)
        trigger.activity(at: 11)
        XCTAssertEqual(trigger.poll(at: 15), .scrollIdle)
        XCTAssertNil(trigger.poll(at: 20))
    }

    func testScrollAfterClickCoalescesIntoOneCapture() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        trigger.press(at: 12)
        trigger.click(at: 12.25)
        trigger.scroll(at: 12.5, deltaY: -1)
        XCTAssertNil(trigger.poll(at: 12.75))
        XCTAssertEqual(trigger.poll(at: 17.5), .scrollIdle)
        XCTAssertNil(trigger.poll(at: 20))
    }

    func testEligibleClickConsumesPendingScroll() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        trigger.scroll(at: 11, deltaY: -1)
        trigger.press(at: 12)
        trigger.click(at: 12.25)
        XCTAssertEqual(trigger.poll(at: 12.75), .clickAfterIdle)
        XCTAssertNil(trigger.poll(at: 14))
    }

    func testReturnWithoutLettersDoesNotCaptureByDefault() {
        var trigger = CaptureTrigger()
        XCTAssertNil(trigger.enter(isRepeat: false))
        XCTAssertNil(trigger.poll(at: 100))
    }

    func testLetterThenReturnCapturesOnceUntilAnotherLetter() {
        var trigger = CaptureTrigger()
        XCTAssertNil(trigger.keyDown(keyCode: 0)) // A
        XCTAssertEqual(trigger.keyDown(keyCode: 36), .enter)
        XCTAssertNil(trigger.keyDown(keyCode: 36))
        XCTAssertNil(trigger.keyDown(keyCode: 11)) // B
        XCTAssertEqual(trigger.keyDown(keyCode: 76), .enter) // Keypad Enter
    }

    func testDigitsPunctuationAndShortcutsDoNotArmReturn() {
        var trigger = CaptureTrigger()
        for code in [UInt16(18), 43, 49, 123] {
            XCTAssertNil(trigger.keyDown(keyCode: code))
            XCTAssertNil(trigger.keyDown(keyCode: 36))
        }
        XCTAssertNil(trigger.keyDown(keyCode: 0, isShortcut: true))
        XCTAssertNil(trigger.keyDown(keyCode: 36))
    }

    func testEveryPhysicalLetterKeyCanArmReturnIncludingIMEInput() {
        for code in [UInt16(0), 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40, 45, 46] {
            var trigger = CaptureTrigger()
            XCTAssertNil(trigger.keyDown(keyCode: code))
            XCTAssertEqual(trigger.keyDown(keyCode: 36), .enter, "Letter key \(code) should qualify")
        }
    }

    func testRepeatedReturnDoesNotConsumeFreshLetterInput() {
        var trigger = CaptureTrigger()
        _ = trigger.keyDown(keyCode: 0)
        XCTAssertNil(trigger.keyDown(keyCode: 36, isRepeat: true))
        XCTAssertEqual(trigger.keyDown(keyCode: 36), .enter)
    }

    func testMouseCaptureDoesNotConsumeTypedLetter() {
        var trigger = CaptureTrigger()
        _ = trigger.keyDown(keyCode: 0)
        trigger.scroll(at: 10, deltaY: -1)
        XCTAssertEqual(trigger.poll(at: 15), .scrollIdle)
        XCTAssertEqual(trigger.keyDown(keyCode: 36), .enter)
    }

    func testFocusChangeDiscardsLettersWithoutLosingPendingMouseCapture() {
        var trigger = CaptureTrigger()
        _ = trigger.keyDown(keyCode: 0)
        trigger.scroll(at: 10, deltaY: -1)
        trigger.resetKeyboard()
        XCTAssertNil(trigger.keyDown(keyCode: 36))
        XCTAssertEqual(trigger.poll(at: 15), .scrollIdle)
    }

    func testPauseAndSettingsChangesDiscardArmedInput() {
        var trigger = CaptureTrigger()
        _ = trigger.keyDown(keyCode: 0)
        trigger.reset()
        XCTAssertNil(trigger.keyDown(keyCode: 36))
        _ = trigger.keyDown(keyCode: 0)
        trigger.scroll(at: 10, deltaY: -1)
        trigger.settings.scope = .focusedDisplay
        XCTAssertNil(trigger.keyDown(keyCode: 36))
        XCTAssertNil(trigger.poll(at: 13))
    }

    func testMouseOptionsAreIndependentAndCanBothBeOff() {
        for selected in [Set<MouseCaptureTrigger>(), [.click], [.scroll], [.click, .scroll]] {
            var trigger = CaptureTrigger(settings: CaptureSettings(mouseTriggers: selected))
            trigger.activity(at: 10)
            XCTAssertEqual(trigger.press(at: 11), selected.contains(.click))
            XCTAssertEqual(trigger.click(at: 11.25), selected.contains(.click))
            XCTAssertEqual(trigger.poll(at: 11.75), selected.contains(.click) ? .clickAfterIdle : nil)
            trigger.scroll(at: 20, deltaY: -1)
            XCTAssertNil(trigger.poll(at: 23))
            XCTAssertEqual(trigger.poll(at: 25), selected.contains(.scroll) ? .scrollIdle : nil)
            _ = trigger.keyDown(keyCode: 0)
            XCTAssertEqual(trigger.keyDown(keyCode: 36), .enter)
        }
    }

    func testReturnOnlyModeDoesNotRequireLetters() {
        var trigger = CaptureTrigger(settings: CaptureSettings(keyboard: .returnKey))
        XCTAssertEqual(trigger.keyDown(keyCode: 36), .enter)
        XCTAssertNil(trigger.keyDown(keyCode: 36, isRepeat: true))
        XCTAssertEqual(trigger.keyDown(keyCode: 76), .enter)
    }

    func testRepeatedReturnDoesNotConsumePendingClick() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        trigger.press(at: 12)
        trigger.click(at: 12.25)
        XCTAssertNil(trigger.enter(isRepeat: true))
        XCTAssertEqual(trigger.poll(at: 12.75), .clickAfterIdle)
    }

    func testReturnConsumesPendingClickAndMovement() {
        var trigger = CaptureTrigger(settings: CaptureSettings(keyboard: .returnKey))
        trigger.activity(at: 10)
        trigger.press(at: 12)
        trigger.click(at: 12.25)
        XCTAssertEqual(trigger.enter(isRepeat: false), .enter)
        XCTAssertNil(trigger.poll(at: 13))
        XCTAssertFalse(trigger.press(at: 14))
        XCTAssertFalse(trigger.click(at: 14.25))
    }

    func testReturnCancelsAnUnreleasedClick() {
        var trigger = CaptureTrigger(settings: CaptureSettings(keyboard: .returnKey))
        trigger.activity(at: 10)
        trigger.press(at: 12)
        XCTAssertEqual(trigger.enter(isRepeat: false), .enter)
        XCTAssertFalse(trigger.click(at: 12.25))
        XCTAssertNil(trigger.poll(at: 13))
    }

    func testReturnConsumesPendingScroll() {
        var trigger = CaptureTrigger(settings: CaptureSettings(keyboard: .returnKey))
        trigger.scroll(at: 10, deltaY: -1)
        XCTAssertEqual(trigger.enter(isRepeat: false), .enter)
        XCTAssertNil(trigger.poll(at: 13))
    }

    func testPauseDiscardsPendingClickAndMovement() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        trigger.press(at: 12)
        trigger.click(at: 12.25)
        trigger.reset()
        XCTAssertNil(trigger.poll(at: 13))
        XCTAssertFalse(trigger.press(at: 14))
        XCTAssertFalse(trigger.click(at: 14.25))
    }

    func testPauseDiscardsUnclickedMovement() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        trigger.reset()
        XCTAssertFalse(trigger.press(at: 12))
        XCTAssertFalse(trigger.click(at: 12.25))
        XCTAssertNil(trigger.poll(at: 13))
    }

    func testPauseDiscardsAnUnreleasedClick() {
        var trigger = CaptureTrigger()
        trigger.activity(at: 10)
        trigger.press(at: 12)
        trigger.reset()
        XCTAssertFalse(trigger.click(at: 12.25))
        XCTAssertNil(trigger.poll(at: 13))
    }

    func testPauseDiscardsPendingScroll() {
        var trigger = CaptureTrigger()
        trigger.scroll(at: 10, deltaY: -1)
        trigger.reset()
        XCTAssertNil(trigger.poll(at: 13))
    }
}
