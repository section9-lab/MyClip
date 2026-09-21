# Screenshot OCR and macOS compatibility verification

## Behavior

- Every available screenshot is queued for local Vision OCR, independently of AI organization. Startup backfills older screenshots.
- UTF-8 text is saved beside the PNG as `Images/<fingerprint>.txt`. Identical images share the document while keeping every capture occurrence.
- The screenshot detail sheet provides image/OCR tabs, selectable text, Copy Text, Open Document, loading, empty-result, expired-source, and retry states.
- OCR failures remain retryable and do not prevent later images from being processed. Empty results are saved as empty documents.
- Text documents and their search index expire with the image; Memory notes keep their existing retention behavior.

## Compatibility changes

- App and Swift package deployment targets are macOS 13.0.
- OCR explicitly uses [Vision text-recognition revision 3](https://developer.apple.com/documentation/vision/vnrecognizetextrequestrevision3), available since macOS 13 in the SDK headers.
- macOS 13 captures one complete ScreenCaptureKit frame, with cancellation, a timeout, and stream cleanup. macOS 14+ uses SCScreenshotManager. Both paths retain the same window/application exclusions.
- ObservableObject/Published replaces macOS 14 Observation in the active application. Preferences forward change notifications to the app model.
- [MarkdownUI 2.4.1](https://github.com/gonzalezreal/swift-markdown-ui/tree/2.4.1) replaces the macOS 15-only Textual dependency. Memory links, local images, tables, and selectable text remain available. AppKit scroll hosting retains reading positions on older systems.
- The inactive Kara entry point and its services are excluded from the MyClip target. Their source files remain in the repository; no active MyClip feature depends on them.

## Validation

Host: macOS 27.0 (26A428), Xcode 26.0 (17A324), macOS 26 SDK.

- The five document-persistence regression tests failed before implementation and passed afterward.
- `swift test`: 177 tests, zero failures, six existing opt-in external integration tests skipped. Includes Chinese/English OCR, concurrent requests, document persistence, blank images, corrupt-image retry, search, and expiration.
- `bash Scripts/test_screenshot_documents.sh`: all seven checks passed. Compiles the real app model and capture service for macOS 13; checks background backfill while AI organization is off/paused, corrupt-image isolation and retry, no capture in preview, and nested preference notifications.
- Capture lifecycle checks compiled with a macOS 13 target: zero failures.
- Debug and universal Release app builds succeeded. Both arm64 and x86_64 executable slices report `LC_BUILD_VERSION minos 13.0`; the app's `LSMinimumSystemVersion` is `13.0`.
- On macOS 27, preview UI verification confirmed OCR text, immediate cached reopening, and opening the matching `.txt` in TextEdit. Memory headings, tables, long-document scrolling, and saved scroll position were also checked with temporary preview data.
- OCR extracted 737 characters, including Chinese and English, from the supplied reference screenshot. In a fresh command-line process on this beta OS, the first recognition took approximately 43 seconds; a second recognition took 0.38 seconds. Recognition runs off the main actor and the detail view shows its loading state.

macOS 13–26 runtime tests were not available on this host. Deployment-target compilation and universal-binary inspection do not substitute for testing capture permissions, the legacy stream path, and rendering on each OS.

Reproduce the universal build with:

```sh
xcodebuild -project MyClip.xcodeproj -scheme MyClip -configuration Release \
  -destination 'platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
```
