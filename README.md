<div align="center">
  <img src="MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="MyClip icon" width="120" height="120">
  <h1 align="center">MyClip</h1>

  <p align="center">
    MyClip helps you remember what you were working on. It captures the focused window or its display on your Mac and uses Codex or Claude to turn screenshots into searchable notes, connected knowledge, and suggested tasks.
  </p>
</div>

<p align="center">
  <strong>English</strong> · <a href="docs/README.zh-CN.md">简体中文</a> · <a href="docs/README.es.md">Español</a> · <a href="docs/README.fr.md">Français</a> · <a href="docs/README.de.md">Deutsch</a> · <a href="docs/README.ja.md">日本語</a> · <a href="docs/README.ko.md">한국어</a>
</p>

<p align="center">
  <a href="https://section9-lab.github.io/MyClip/demo/"><img src="docs/images/myclip-demo.gif" alt="MyClip desktop demo: onboarding, Memory, Timeline, Kanban, Reports, Backstage, Settings, and memory recall in Codex and Claude" width="1000"></a>
</p>
<p align="center"><a href="https://section9-lab.github.io/MyClip/demo/">Watch HD video</a> · <a href="docs/images/myclip-demo.mp4">Download MP4</a></p>
<p align="center"><sub>45-second HTML demo · Sample data · Chinese interface.</sub></p>

## What you can do

- **Revisit your work.** Browse a screenshot timeline and check the sources behind your notes. Every screenshot has a local OCR text document you can view, copy, or open.
- **Build a personal knowledge library.** Search, edit, and link notes across projects, topics, and daily work. Your notes are Markdown files you can open in other editors.
- **Keep track of next steps.** Review suggested tasks, confirm what matters, and follow progress on a task board. Switch between **Kanban** and **Reports** to review daily, weekly, or monthly work reports grouped by project and progress.
- **Give your AI tools context.** Let Codex, Claude Code, Claude Desktop, Cursor, or OpenCode search your saved memories.

## Get started

Requires **macOS 13 or later** and a **Codex or Claude account**. Installing the agent connector also requires **Node.js 22 or later**. Download the Apple Silicon or Intel DMG from [Releases](https://github.com/section9-lab/MyClip/releases). These community builds are self-signed and not notarized; see [opening the app and permission recovery](docs/release-signing.md). Local build instructions are below.

1. Open MyClip and choose a default Agent in onboarding. MyClip detects available local agents and saves your selection after a successful connection. You can change it later in **Backstage**; multiple agents can be connected, but only one is enabled at a time.
2. Grant **Screen Recording** and **Accessibility** permissions. Capture starts automatically whenever MyClip is open, including after permissions are granted.
3. Work as usual. By default, MyClip captures the focused window after a click following one second of pointer stillness, after two seconds without vertical scrolling, or after a letter key followed by Return. Automatic organization turns new screenshots into Memory.
4. Explore **Memory** for notes, **Timeline** for screenshots, and **Kanban** for suggested work.

To use your memory in an AI tool, enable **MyClip MCP** in Settings, select your clients, and apply the configuration. Restart the client or start a new session afterward.

**Claude Code (CLI)** handles background screenshot organization through ACP. **Claude Desktop** has a separate entry for opening the app and configuring MCP memory access in Chat and local Code sessions; it cannot be enabled for background organization. Desktop configuration is saved to `~/Library/Application Support/Claude/claude_desktop_config.json`, preserving existing servers and leaving the CLI configuration untouched. Fully quit and reopen Claude Desktop after configuring it.

## Screenshot text documents

MyClip extracts Chinese and English text on-device with Apple Vision, independently of AI organization. In a screenshot's detail view, select **OCR 文档** to read or copy its text, or choose **打开文档** to open the UTF-8 `.txt` file saved beside the original image. Repeated screenshots share one image and text document. Screenshots without readable text receive an empty document; recognition failures can be retried.

Existing screenshots are processed in the background after startup. OCR documents and their search index expire with the original images according to the retention setting. Saved Memory notes remain. The app targets macOS 13 and later, including macOS 27; macOS 13 uses a single-frame ScreenCaptureKit stream with the same application exclusions as newer systems.

## Screenshot organization

Screenshots enter a persistent waiting pool as soon as they are saved. Automatic organization waits five minutes from the oldest pending capture, then takes a chronological batch for the same agent: at most **8 images and 32 OCR records**, with at most **12,000 OCR characters** in total. Return-key and manual captures use images; mouse click, scroll, and older pointer captures use locally extracted OCR. Missing OCR is generated before dispatch. Empty, failed, or individually oversized OCR falls back to the original image and counts toward the image limit. The batch stops at the first record that would exceed a limit, without skipping it. New captures do not reset the timer. Only one batch runs at a time, with at least five minutes between batch starts.

The **Backstage** page shows the waiting count, countdown, and current batch. **Organize Now** starts one batch early. A failure or interrupted run pauses automatic processing until you retry or resume; screenshots and existing Memory files are retained. Input modes and OCR content are frozen when a batch is created, including across retries and restarts. **按图片重新整理** in screenshot details explicitly sends the original image, useful for charts or layouts that OCR cannot preserve. Enabling another agent reassigns captures waiting for automatic organization. Running batches finish with their original agent. Existing jobs and retries also keep their original agent and wait until it is enabled again.

Each batch uses an independent temporary session. Claude receives `persistSession: false`; MyClip's Codex app-server proxy enforces `ephemeral: true` and rejects a backend that does not acknowledge it. The agent process closes after each run. Old saved conversations are neither resumed nor deleted. The next batch receives the fixed organization rules, only the previous successful batch's handoff (at most 4 KiB), current timestamped inputs with their source IDs, app/window and trigger metadata, and existing task context. Related Memory files are read on demand. The handoff records saved file changes and source IDs, excludes conversation history and Memory bodies, and is replaced only after Memory publishing succeeds. Failed retries start fresh and inspect the current files.

Without an enabled agent, screenshots remain in the waiting pool. Disabling an agent stops new tasks while allowing the current task to finish. MyClip remembers the enabled agent and reconnects it at startup. Older default-agent preferences do not enable an agent automatically; enable one explicitly after upgrading.

MyClip starts every organization and task-discovery session with **Full access**: `agent-full-access` for Codex and `bypassPermissions` for Claude Code. File access, edits, commands, network access, and MCP tool calls proceed without per-operation confirmation cards. Any remaining tool permission requests are handled automatically for the active session, while cancelled tasks reject late requests. Tool activity remains available in the execution record.

The **Backstage** page tracks reported token consumption across organization, task discovery, and retries, with totals per agent and per batch. Usage is stored locally when each request ends; older or unreported usage is shown as unavailable, not zero. Context-window occupancy is not counted as consumption. Active batches show their current stage, elapsed time, and time since the last progress update. Claude ACP uses Claude Code's existing login and network settings, so a configured local proxy must be running.

Organization stops after five minutes without new thinking, response text, tool activity, or permission activity in the current session. A batch can continue while it makes progress, up to a fifteen-minute total limit. Usage-only updates and other sessions do not extend the timeout.

Memory keeps screenshot observation time (`observed_at`) separate from file update time (`updated_at`). Now shows when its evidence was captured; older evidence cannot replace a newer Now page. Missing observation time remains unknown. The organizer consolidates event history in Daily, keeps conclusions in project/topic pages, and moves resolved items out of Inbox. Repeated or incidental browsing does not require a new permanent note.

For newly organized pages, `source_ids` contains actual screenshot IDs cited in the text. The batch's reference screenshots are retained separately in `context_source_ids`; they are not evidence for every statement. MCP search results carry the cited source IDs of their paragraphs, and `memory_get` summarizes the screenshots behind a page (count, time span, apps). Existing notes remain readable and adopt these rules when organized again; notes are not bulk-rewritten during upgrade.

Memory search in the app and MCP uses the same SQLite FTS5 ranking. Keywords match any term; exact titles and declared aliases come first, then a mix of each note's best-matching paragraphs and whole-note BM25, then file modification time. Scoring by paragraphs keeps long notes from outranking the paragraph that answers the question. Literal substring matches remain available for Chinese text and punctuation. An empty query still lists recently edited notes.

MCP offers two read-only tools. `memory_search` takes `query` (the question or keywords) plus optional `since`, `until`, `app` and `limit` (default 10), and returns ranked results with `path`, `title`, a short `snippet` (up to two matching paragraphs of at most 300 characters each, with Wikilinks shown as their labels and citation IDs left out), `links` (the pages the shown lines point to, as `path` or `path#heading`), `time`, the paragraphs' cited `sourceIDs` and source `apps`. `memory_get` takes a `path` from those results, optionally with `#heading` to read one section, and `from`/`lines` for line ranges; it returns the Markdown lines, the page's links grouped by heading, its backlinks newest first (each with the line that holds the link and its date), and a summary of the screenshots behind the page. Unknown arguments are rejected rather than ignored.

Search follows Wikilinks. The strongest matches, plus both ends of links whose line matches the question, seed a two-step spread over the link graph: one hop from every seed and a second hop only through entity pages (a Daily note → a person or topic page → another Daily note). Each link is weighted by how well its line matches the question and damped by how many links the page it enters has, so hub pages such as `Now.md` do not flood the results; root files and `Wiki/Archives` are left out. Pages reached this way are ranked together with direct matches and carry `via`: one or two hops, each with the page that holds the link, its heading, the line itself and its date. Links indicate association, not proof of a factual relationship.

`time` and the `since`/`until` filters describe when the content happened: an annotated event on a paragraph, else a cited screenshot, else the file edit time. `since` is inclusive and `until` exclusive; both accept ISO 8601 timestamps. With `app`, notes with events match through an event paragraph that also cites a screenshot from that app, and notes without events need one cited screenshot that satisfies both the range and the app. Unknown event dates are never replaced by capture or edit dates. Dated pages without a range gently favor recent days.

Event annotations are stored immediately before their paragraph, without a blank line, as an HTML comment. They survive Markdown copies and index rebuilds. For example:

```markdown
<!-- myclip-event {"start":"2026-09-10T00:00:00+08:00","end":"2026-09-11T00:00:00+08:00","precision":"day","evidence":"2026年9月10日"} -->
2026年9月10日，客户会议结束。来源：截图 `REPLACE_WITH_ACTUAL_SOURCE_UUID`。
```

Use actual evidence and a real cited screenshot ID. Supported precision values are `day` (a local calendar day), `range` (an explicit interval, end exclusive), and `instant` (end omitted or equal to start). Timestamps require an explicit UTC offset. Search reports the event start as the result's `time`; this records the note's assertion, not independent verification of the source. Invalid dates, conflicting annotations, annotations in code examples, missing paragraph citations, or an `evidence` expression absent from the paragraph do not produce indexed event times. Relative dates require a known original-message time and timezone; the organizer must retain the expression and explain its conversion. Capture time and edit time never supply a missing event date. Existing notes remain searchable without annotations and receive them when relevant evidence is organized; upgrading does not invent or rewrite their dates.

Passage, event and link indexes are derived SQLite data. They are refreshed on edits, deleted with their note, and rebuilt for older libraries without changing Markdown. For questions that need more than two hops, an agent reads a page with `memory_get` and follows the links or backlinks it lists.

Temporary sessions cannot be reopened in Codex or Claude. Inspect their execution details in MyClip instead; each record also shows its image/text input counts. These settings prevent resumable local agent conversations, not the model provider's service-side data retention.

Click an organization record in **Backstage** to inspect each request, including retries: tool calls, command arguments, results, file locations and edits, agent replies, input/output tokens, cache reads/writes, and reported cost. Tool records are saved while the request runs and remain available after cancellation or restart. Cost uses the difference between reported cumulative session amounts; missing reports or an unknown session baseline remain unknown. Older records retain their existing token totals but cannot recover tool details that were never saved.

## Privacy and control

- **Choose what to capture.** Settings groups capture into three controls: scope (focused window by default, or the display containing it), independent mouse triggers (idle-then-click and scroll-then-pause), and keyboard trigger (letters then Return by default, or every Return). Capture runs automatically while MyClip is open; quit the app to stop it. You can exclude specific apps; full-display capture also filters excluded apps.
- **Keep your library locally.** Screenshots and notes are stored on your Mac. Original screenshots expire after 30 days by default; saved notes remain. You can change the retention period in Settings.
- **Decide when to use AI.** Organization uses your selected agent's model service, which may process screenshots and notes in the cloud. Turn off automatic organization to keep new captures local until you choose to process them.

<details>
<summary>Build from source</summary>

Requires Xcode 26, Swift 6.2, XcodeGen, Python 3, and Node.js. See the [development guide](docs/development.md) for source layout, prompts and test groups.

```sh
xcodegen generate
bash Scripts/test.sh
xcodebuild -project MyClip.xcodeproj -scheme MyClip -configuration Debug build
```

To package a DMG, run `Scripts/package_dmg.sh`. The output is `dist/MyClip-<version>.dmg`.

For separate Apple Silicon and Intel packages, run `MYCLIP_ARCH=arm64 bash Scripts/package_dmg.sh` or `MYCLIP_ARCH=x86_64 bash Scripts/package_dmg.sh`. Their filenames end in `-arm64.dmg` and `-x86_64.dmg` respectively. After the one-time [community signing setup](docs/release-signing.md), pushing a `v<version>` tag triggers GitHub Actions to test and package both architectures, then publish a Release with both DMGs, the public signing certificate, and `SHA256SUMS`. The tag must match `CFBundleShortVersionString`, with release notes in `docs/releases/v<version>.md`.

</details>
