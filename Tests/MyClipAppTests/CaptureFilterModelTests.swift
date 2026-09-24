@testable import MyClip
import AppKit
import MyClipCore

@main
struct CaptureFilterModelTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-FilterTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try MyClipModel(root: root, preview: true)
        defer { model.stop() }
        let canvas = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = try CapturedImage(image: canvas.makeImage()!)
        let today = Calendar.current.startOfDay(for: Date())
        let contexts = [
            CaptureContext(appName: "Notes", bundleID: "notes", windowTitle: "Needle", windowID: 1, reason: .enter, date: today),
            CaptureContext(appName: "Notes", bundleID: "notes", windowTitle: "Other", windowID: 1, reason: .clickAfterIdle, date: today),
            CaptureContext(appName: "Safari", bundleID: "safari", windowTitle: "Needle", windowID: 1, reason: .enter, date: today),
            CaptureContext(appName: "Notes", bundleID: "notes", windowTitle: "Yesterday", windowID: 1, reason: .enter, date: today.addingTimeInterval(-1))
        ]
        for context in contexts { try await model.store.record(image: image, context: context, agent: .codex, organize: false) }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            fflush(stdout)
            if !condition { failures += 1 }
        }
        await model.refresh()
        model.captureFilter = CaptureFilter(appName: "Notes", dateRange: today...today, event: .keyboard)
        let deadline = Date().addingTimeInterval(3)
        while model.results.captures.count != 1, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        check(model.results.captures.map(\.id) == [contexts[0].id], "Changing filters refreshes the displayed captures")
        check(model.library.captures.count == 4, "Filtering preserves the unfiltered library")
        model.search = "Missing"
        await model.refresh()
        check(model.results.captures.isEmpty, "Keyword search intersects with active filters")
        model.search = ""
        check(model.results.captures.isEmpty, "Clearing search does not flash unfiltered captures")
        await model.refresh()
        check(model.results.captures.map(\.id) == [contexts[0].id], "Clearing search preserves all three filters")
        model.search = "Needle"
        model.captureFilter = CaptureFilter()
        await model.refresh()
        check(model.search == "Needle" && model.results.captureCount == 2, "Clearing filters preserves keyword search")
        model.search = ""
        await model.refresh()
        check(model.results.captureCount == 4, "Clearing search and filters restores every capture")
        print("Capture filter model checks: \(failures) failure(s)")
        if failures > 0 { throw LibraryError.invalidResult("Capture filter model checks failed") }
    }
}
