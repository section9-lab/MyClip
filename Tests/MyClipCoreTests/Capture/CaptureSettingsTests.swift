import XCTest
@testable import MyClipCore

final class CaptureSettingsTests: XCTestCase {
    func testExplanationMatchesScopeAndEnabledTriggers() {
        let settings = CaptureSettings(scope: .focusedDisplay, mouseTriggers: [.scroll], keyboard: .afterLetters)
        let explanation = String(describing: settings)
        XCTAssertTrue(explanation.contains("焦点窗口所在的显示器"))
        XCTAssertTrue(explanation.contains("scroll向下滚动后静止5秒"))
        XCTAssertTrue(explanation.contains("字母键后再回车"))
        XCTAssertFalse(explanation.contains("点击"))
        XCTAssertFalse(explanation.contains("只记录"))
    }

    func testKeyboardOnlyExplanationDoesNotDescribeMouseTriggers() {
        let explanation = String(describing: CaptureSettings(mouseTriggers: [], keyboard: .returnKey))
        XCTAssertTrue(explanation.contains("只记录前台焦点窗口"))
        XCTAssertTrue(explanation.contains("每次按下回车"))
        XCTAssertFalse(explanation.contains("点击"))
        XCTAssertFalse(explanation.contains("滚动"))
    }

    func testDefaultsAndLegacyMouseChoices() {
        let name = "MyClip.CaptureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let initial = CaptureSettings.load(from: defaults)
        XCTAssertEqual(initial.scope, .focusedWindow)
        XCTAssertEqual(initial.keyboard, .afterLetters)
        XCTAssertEqual(initial.mouseTriggers, [.click, .scroll])
        XCTAssertEqual(initial.filterStrategies, [.similarImages, .nearUniformImages])
        XCTAssertEqual(CaptureSettings().filterStrategies, initial.filterStrategies)
        for (value, expected) in [("pointer", Set<MouseCaptureTrigger>([.click])), ("scroll", [.scroll]), ("both", [.click, .scroll])] {
            defaults.set(value, forKey: "myclip.mouseActivity")
            XCTAssertEqual(CaptureSettings.load(from: defaults).mouseTriggers, expected)
        }
    }

    func testSelectionsPersistIncludingNoMouseTriggers() {
        let name = "MyClip.CaptureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("both", forKey: "myclip.mouseActivity")
        let options = CaptureSettings(scope: .focusedDisplay, mouseTriggers: [], keyboard: .returnKey)
        options.save(to: defaults)
        XCTAssertEqual(CaptureSettings.load(from: UserDefaults(suiteName: name)!), options)
    }

    func testBothImageFiltersAreEnabledWhenOldPreferencesHaveNoFilterSelection() {
        let name = "MyClip.CaptureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        CaptureSettings.load(from: defaults).save(to: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "myclip.captureFilterStrategies"), ["nearUniformImages", "similarImages"])
        XCTAssertEqual(CaptureFilterStrategy.allCases, [.similarImages, .nearUniformImages])
    }

    func testFilteringSelectionsSurviveReloadIncludingAllDisabled() {
        let name = "MyClip.CaptureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for values in [[], ["mouseCooldown"], ["similarImages"], ["mouseCooldown", "similarImages"], ["similarImages", "unknown"],
                       ["nearUniformImages"], ["similarImages", "nearUniformImages"]] {
            defaults.set(values, forKey: "myclip.captureFilterStrategies")
            let settings = CaptureSettings.load(from: defaults)
            defaults.removeObject(forKey: "myclip.captureFilterStrategies")
            settings.save(to: defaults)
            XCTAssertEqual(defaults.stringArray(forKey: "myclip.captureFilterStrategies"), values.filter { ["similarImages", "nearUniformImages"].contains($0) }.sorted())
        }
    }

    func testFocusedDisplayUsesLargestWindowOverlapAcrossMultipleScreens() {
        let screens = [
            DisplayCandidate(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            DisplayCandidate(id: 2, frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440)),
            DisplayCandidate(id: 3, frame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080)),
            DisplayCandidate(id: 4, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)),
            DisplayCandidate(id: 5, frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        ]
        XCTAssertEqual(FocusedDisplayMatcher.match(frame: CGRect(x: 2100, y: 100, width: 800, height: 600), displays: screens), 2)
        XCTAssertEqual(FocusedDisplayMatcher.match(frame: CGRect(x: 1700, y: 100, width: 1000, height: 600), displays: screens), 2)
        XCTAssertEqual(FocusedDisplayMatcher.match(frame: CGRect(x: 1000, y: 100, width: 1000, height: 600), displays: screens), 1)
        XCTAssertEqual(FocusedDisplayMatcher.match(frame: CGRect(x: -1500, y: -900, width: 800, height: 600), displays: screens), 3)
        XCTAssertEqual(FocusedDisplayMatcher.match(frame: CGRect(x: -1500, y: 100, width: 800, height: 600), displays: screens), 4)
        XCTAssertEqual(FocusedDisplayMatcher.match(frame: CGRect(x: 100, y: -900, width: 800, height: 600), displays: screens), 5)
        XCTAssertNil(FocusedDisplayMatcher.match(frame: CGRect(x: 6000, y: 0, width: 800, height: 600), displays: screens))
        XCTAssertNil(FocusedDisplayMatcher.match(frame: .zero, displays: screens))
        XCTAssertNil(FocusedDisplayMatcher.match(frame: CGRect(x: 100, y: 100, width: 800, height: 600), displays: []))
    }

    func testEqualOverlapUsesStableDisplayOrder() {
        let screens = [DisplayCandidate(id: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 100)),
                       DisplayCandidate(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]
        XCTAssertEqual(FocusedDisplayMatcher.match(frame: CGRect(x: 50, y: 0, width: 100, height: 100), displays: screens), 1)
    }
}
