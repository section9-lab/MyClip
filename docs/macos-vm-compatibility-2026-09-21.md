# macOS runtime compatibility verification

Date: September 21, 2026. This report records tests of MyClip 0.6.5 (24), not a guarantee for every macOS patch release or hardware configuration.

Across five platform runs, 819 automated assertions passed with no automated failures. Manual testing found one reproducible defect in the original installed build: Memory sidebar file selection fails on macOS 13.7.4. A subsequent source fix and focused regression run are recorded below. These results do not establish full compatibility across macOS 13–27.

## Environment and scope

- Host: Apple M4 Max, macOS 27.0 (26A428), 64 GB RAM.
- Virtualization: the official OpenAI Tart 2.37.0 release, using Cirrus Labs macOS base images. Each guest has 4 CPUs, 8 GB RAM, and a 1440 × 900 display.
- Installed app: a copy of `/Applications/MyClip.app`, with executable SHA-256 `f4f1e8e5435f42dd914a20a7a977050e92cf990a7e0c2abe38859a5eaeee6775`.
- The installed app is universal (arm64 and x86_64), with a minimum deployment target of macOS 13.0. Only arm64 is exercised by these virtual machines.
- Automated executables were compiled from the current working tree with an arm64 macOS 13.0 target. These checks are reported separately from manual checks of the installed app.
- All guest data is synthetic. No existing user library, agent credentials, or account sessions were copied into the guests. Host application permissions and the host installation were left unchanged.

## Automated checks

Each platform runs the same payload. Counts below are assertions printed by the harnesses, not independent end-to-end user journeys.

| Harness | Checks | Coverage |
| --- | ---: | --- |
| CaptureLifecycleTests | 77 | Startup, permission state transitions, stop/restart, retry, and preview isolation, with a stub capture service |
| ScreenshotDocumentTests | 7 | Real local OCR backfill, persistence, corrupt-image isolation and retry, and preference propagation |
| CaptureFilterModelTests | 7 | Timeline application, event, date, and combined filters |
| MemoryScrollTests | 38 | Native document layout, narrow/wide resizing, scrolling, and reading-position restoration |
| TaskBoardScrollTests | 31 | Native Kanban columns, five-row bounds, independent scrolling, and report layout |
| CompatibilityFixture | 2 | Synthetic library creation and Vision recognition of an English/Chinese image |
| **Total per platform** | **162** | |

An additional `CaptureAPISmoke` executable links the production `WindowImageCapture.swift`, creates its own synthetic native window, captures that window through ScreenCaptureKit, and verifies numeric and Chinese OCR sentinels in the resulting pixels. Its three checks exercise the real capture API; they do not test input monitoring or the installed app's permission identity. The test uses existing guest permissions and skips without prompting if its process lacks access.

| Platform | Build | Automated result | Installed app checks |
| --- | --- | --- | --- |
| macOS 13.7.4, Tart | 22H420 | 162 passed, 0 failed | Capture/OCR, Timeline, Kanban, Reports, Markdown rendering, and restart passed; **Memory sidebar file selection failed** |
| macOS 14.8.7, Tart | 23J520 | 165 passed, 0 failed, including the real capture API | Launch, permissions, actual capture/OCR, Memory file selection, independent columns, report periods, and app restart checked |
| macOS 15.7.7, Tart | 24G720 | 165 passed, 0 failed, including the real capture API | Installed app signature verified; interactive app checks not performed |
| macOS 26.6.2, Tart | 25G83 | 165 passed, 0 failed, including the real capture API | Launch, permissions, actual capture/OCR, Timeline detail, Memory file selection, independent columns, and daily Reports checked |
| macOS 27.0, host | 26A428 | 162 passed, 0 failed | Existing host installation; this run does not replace prior native UI verification |

## macOS 13 installed-app observations

- The unchanged installed app reached its first-run permission screen. Granting Screen Recording and Accessibility through guest System Settings allowed the app to enter Timeline and start capture.
- TextEdit Return and scroll-idle events created real capture records and PNG files. The macOS 13 `SCStream` fallback therefore ran successfully; this is separate evidence from the stubbed lifecycle checks.
- Vision generated text files containing English and Chinese. The real screenshot and its OCR document both opened in the Timeline detail sheet. OCR output is imperfect, especially for the small text used in this fixture; this was not an OCR accuracy benchmark.
- The Kanban columns had the expected gray, orange, and blue backgrounds. Dragging the Todo column's scroll thumb changed that column while the other two stayed in place. Five-row layout bounds also passed the automated harness.
- Reports switched among daily, weekly, and monthly periods, with headings and project groups visible.
- Memory rendered headings, Chinese text, and a Markdown table. Opening a document through the folder content area worked.
- Clicking Memory sidebar file rows did not change the displayed document. This reproduced after restarting the VM. Folder-row clicks and folder-content navigation worked; file-row clicks worked on macOS 14 and 26. See the finding below.
- After restarting the VM, MyClip reopened with its 16-image Timeline library, retained permissions, and automatically resumed capture.
- A mouse-only capture trigger was not established in this run.

## macOS 14 installed-app observations

- First launch, guest Screen Recording and Accessibility grants, and automatic capture startup completed successfully.
- Real TextEdit Return and scroll-idle events produced PNGs and English/Chinese OCR documents. Both the image and extracted text opened inside Timeline.
- Mouse clicks on `Now.md` and `Profile.md` selected the corresponding Memory sidebar rows and changed the displayed document.
- Kanban rendered the three status colors. Dragging the Todo scrollbar moved only that column. Daily, weekly, and monthly Reports switched correctly.
- Quitting and relaunching the installed app preserved the 14-image Timeline library, retained permissions, and resumed capture automatically.
- Separately, the capture API smoke test passed through `SCScreenshotManager` and recognized the expected text from its own synthetic window.

## macOS 26 installed-app observations

- First launch and Screen Recording and Accessibility grants completed through guest System Settings. Accepting the additional screen-capture authorization prompt allowed automatic capture to continue.
- Real TextEdit Return and scroll-idle events produced saved PNGs and English/Chinese OCR documents. The extracted text opened in the Timeline detail sheet.
- Clicking `Profile.md` selected the Memory sidebar file and updated the displayed document.
- Kanban rendered the status colors, and dragging the Todo scrollbar changed only that column. The daily Report rendered its headings and project groups.
- Separately, the capture API smoke test passed through `SCScreenshotManager` and recognized its numeric and Chinese OCR sentinels.

## Finding: macOS 13 Memory sidebar file selection

**Status: reproduced in the original installed build; fixed in the subsequent source revision.** See the focused regression results below.

1. Launch the installed MyClip app on macOS 13.7.4 and open Memory.
2. Click the `Now.md` or `Profile.md` file row in the middle sidebar.
3. The file row does not become selected and the right pane continues to display the previous document.
4. Click the `Wiki` folder row: the folder is selected and the right pane changes normally.

The file-row failure occurred in two sessions separated by a full guest restart. On macOS 14.8.7, clicking both `Now.md` and `Profile.md` selected the expected document immediately; clicking `Profile.md` also worked on macOS 26.6.2. Opening a file through its folder's content area remains a usable workaround on macOS 13.

The relevant UI is `MemoryDirectoryView` in `MyClip/Features/Library/MyClipViews.swift`, where an `OutlineGroup` supplies tags to a selection-bound `List`. Existing `MemoryScrollTests` cover the document reader, not directory row selection, so their passing result did not cover this failure.

## Follow-up: Memory directory selection fix

The original outline identified nodes by their string paths, while the list selection and row tags used `MemoryFileSelection`. On macOS 13, leaf rows did not propagate selection to the model. This affected files and empty folders; folders with children still worked.

The production change is one line: explicitly give `OutlineGroup` the identifier key path `id: \.selection`. Row identity now matches the selection value. The existing binding, folder navigation, document renderer, and list styling remain in place.

`Scripts/test_memory_directory.sh` compiles the production views and model into a native AppKit/SwiftUI harness. It uses a temporary library and preview-mode model without starting capture or AI agents. The test selects real outline rows and checks document selection, row highlighting, empty folders, selection while searching, nested files, and folder expansion/collapse. It exercises native selection callbacks, not synthesized mouse events.

| Check | Before the fix | After the fix |
| --- | --- | --- |
| Directory selection, macOS 13.7.4 | 10 passed, 12 failed | 22 passed, 0 failed |
| Directory selection, macOS 14.8.7 | Not rerun with this harness | 22 passed, 0 failed |
| Directory selection, macOS 27.0 host | 22 passed, 0 failed | 22 passed, 0 failed |
| Document scrolling, macOS 13.7.4 | 38 passed in the initial run | 38 passed, 0 failed |
| Document scrolling, macOS 27.0 host | 38 passed in the initial run | 38 passed, 0 failed |

The signed Release build succeeded and remains universal, with executable SHA-256 `b06d916e8560ed1471dc4f55278731628f816e384492a11ee7d47b967e3e00d5`. It was installed in the isolated macOS 13 guest. The host installation was not replaced. A fresh mouse-driven check of that installed build could not be completed because the host window capture service returned `-3812` or an unreadable VM-window thumbnail; the automated native regression results above are complete.

Follow-up logs, the before/after source comparison, test executables, and the fixed app are retained under `build/memory-directory-fix/`. Run the focused checks from the repository root with:

```sh
bash Scripts/test_memory_directory.sh
bash Scripts/test_memory_scrolling.sh
```

## Limits

- The Cirrus Labs base images used here have System Integrity Protection disabled upstream. We did not disable SIP. The guest results do not establish identical behavior for a clean, default-security macOS installation, Gatekeeper, notarization, or all permission reset/upgrade scenarios.
- The Tahoe image also reports Gatekeeper assessments disabled upstream. This task did not change that setting. Its Tart guest agent's screen access prompt was accepted only inside the synthetic guest environment; host protections were not changed.
- No Intel hardware was tested. A universal executable and a 13.0 deployment target are not runtime verification of x86_64.
- AI agent login, remote model calls, live organization, and external MCP integrations were not exercised; guest accounts and credentials were intentionally absent.
- Synthetic task content validates rendering and navigation, not the quality of generated work-report prose.
- GUI input forwarded through Tart can drop or reinterpret modifiers and scroll deltas. A failed forwarded interaction requires confirmation before being classified as a product defect.
- The host UI capture service temporarily returned ScreenCaptureKit error `-3812` during Sonoma's sidebar comparison. Manual testing resumed after the user made the VM window visible. This was a host automation interruption, not a failed MyClip capture in the guest.

## Local evidence and reproduction

Artifacts are kept in the ignored directory `build/macos-vm-compat-20260921/`: the manifest, payload hashes and build targets, per-platform logs, SQLite capture extracts, actual capture PNG/OCR pairs, and native UI screenshots.

Tart was run from the isolated executable `build/macos-vm-compat-20260921/runtime/tart.app/Contents/MacOS/tart`; it was not installed globally. All four test VMs are stopped and retained with their synthetic fixtures for follow-up. The initial compatibility run did not change product code; the subsequent Memory fix is described above.

The host harnesses are reproducible with:

```sh
bash Scripts/test_capture_lifecycle.sh
bash Scripts/test_screenshot_documents.sh
bash Scripts/test_capture_filters.sh
bash Scripts/test_memory_scrolling.sh
bash Scripts/test_task_board_scrolling.sh
```

The artifact directory includes `CompatibilityFixture.swift`, and its `payload` contains `run-guest-checks.sh`. Mount `payload` read-only and a separate `results` directory read-write, then execute from the repository root:

```sh
build/macos-vm-compat-20260921/runtime/tart.app/Contents/MacOS/tart \
  exec <guest-name> /bin/bash "/Volumes/My Shared Files/payload/run-guest-checks.sh"
```

Use a fresh guest library: the fixture refuses to overwrite an existing `Library.sqlite`. The script copies the app to the guest's `/Applications`, runs the harnesses, and verifies its code signature. Native capture and permission checks are performed separately through the guest UI.
