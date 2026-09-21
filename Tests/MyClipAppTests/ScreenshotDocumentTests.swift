import AppKit
import MyClipCore

@main
struct ScreenshotDocumentTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-OCRTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try MyClipModel(root: root, preview: true)
        defer { model.stop() }
        let previousAutoOrganize = model.preferences.autoOrganize
        defer { model.preferences.autoOrganize = previousAutoOrganize }
        model.preferences.autoOrganize = false
        try await model.store.setOrganizationPaused(true)

        func image(gray: CGFloat) throws -> CapturedImage {
            let canvas = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.setFillColor(CGColor(gray: gray, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            return try CapturedImage(image: canvas.makeImage()!)
        }
        func record(_ image: CapturedImage) async throws {
            let context = CaptureContext(appName: "OCR Test", bundleID: "myclip.test", windowTitle: "Fixture", windowID: 1, reason: .manual)
            try await model.store.record(image: image, context: context, agent: .codex, organize: false)
        }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            fflush(stdout)
            if !condition { failures += 1 }
        }

        let broken = try image(gray: 0)
        let blank = try image(gray: 1)
        try await record(broken)
        try await record(blank)
        let brokenURL = root.appendingPathComponent("Images/\(broken.fingerprint).png")
        try Data("Invalid image".utf8).write(to: brokenURL)
        let documentURL = root.appendingPathComponent("Images/\(blank.fingerprint).txt")

        model.start()
        // A fresh process can spend tens of seconds initializing Vision on macOS 27.
        let deadline = Date().addingTimeInterval(90)
        while !FileManager.default.fileExists(atPath: documentURL.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        check(FileManager.default.fileExists(atPath: documentURL.path), "Startup backfills OCR while AI organization is disabled and paused")
        check((try? String(contentsOf: documentURL, encoding: .utf8)) == "", "A blank screenshot has an empty UTF-8 document")
        let pending = try await model.store.imageNeedsTextIndex(broken.fingerprint)
        check(pending, "A corrupt screenshot remains retryable and does not block later screenshots")
        check(!model.capturing, "Preview verification never starts screen capture")
        let queue = try await model.store.organizationQueue()
        check(queue.paused && queue.pendingCount == 0, "OCR does not alter the AI organization queue")

        try broken.pngData.write(to: brokenURL)
        _ = try await model.store.recognizeImageText(id: broken.fingerprint)
        check(FileManager.default.fileExists(atPath: brokenURL.deletingPathExtension().appendingPathExtension("txt").path), "Retry creates the repaired screenshot's document")

        var preferenceChanges = 0
        let observation = model.objectWillChange.sink { preferenceChanges += 1 }
        model.preferences.autoOrganize.toggle()
        check(preferenceChanges > 0, "Nested preferences still notify the UI with macOS 13 observation")
        observation.cancel()
        print("Screenshot document checks: \(failures) failure(s)")
        if failures > 0 { throw LibraryError.invalidResult("Screenshot document checks failed") }
    }
}
