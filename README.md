<div align="center">
  <img src="MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="MyClip icon" width="120" height="120">
  <h1 align="center">MyClip</h1>

  <p align="center">
    MyClip helps you remember what you were working on. It captures the focused window or its display on your Mac and uses Codex or Claude to turn screenshots into searchable notes, connected knowledge, and suggested tasks.
  </p>
</div>

<p align="center">
  <img src="docs/images/myclip-demo.gif" alt="MyClip walkthrough: screenshot timeline, Memory file browser, task board, project progress, and AI memory access" width="1000">
</p>
<p align="center"><sub>MyClip 0.6.0 · Demo with sample data.</sub></p>

## What you can do

- **Revisit your work.** Browse a screenshot timeline and check the sources behind your notes.
- **Build a personal knowledge library.** Search, edit, and link notes across projects, topics, and daily work. Your notes are Markdown files you can open in other editors.
- **Keep track of next steps.** Review suggested tasks, confirm what matters, and follow progress on a task board.
- **Give your AI tools context.** Let Codex, Claude Code, Cursor, or OpenCode search your saved memories.

## Get started

Requires **macOS 26 or later** and a **Codex or Claude account**. Installing the agent connector also requires **Node.js 22 or later**. Local build instructions are below.

1. Open MyClip and choose Codex or Claude using the icons at the bottom of the sidebar. Install its connector and sign in when prompted.
2. Grant **Screen Recording** and **Accessibility** permissions, then start capture.
3. Work as usual. By default, MyClip captures the focused window after a click following one second of pointer stillness, after two seconds without vertical scrolling, or after a letter key followed by Return. Automatic organization turns new screenshots into Memory.
4. Explore **Timeline** for screenshots, **Memory** for notes, and **Task Board** for suggested work.

To use your memory in an AI tool, enable **MyClip MCP** in Settings, select your clients, and apply the configuration. Restart the client or start a new session afterward.

## Screenshot organization

Screenshots enter a persistent waiting pool as soon as they are saved. Automatic organization waits three minutes from the oldest pending capture, then takes up to eight screenshots for the same agent in chronological order. New captures do not reset the timer. Only one batch runs at a time, with at least three minutes between batch starts.

The sidebar and agent panel show the waiting count, countdown, and current batch. **Organize Now** starts one batch early. A failure or interrupted run pauses automatic processing until you retry or resume; screenshots and existing Memory files are retained. Each agent continues its own saved ACP conversation. Switching the default agent affects future captures only.

## Privacy and control

- **Choose what to capture.** Settings groups capture into three controls: scope (focused window by default, or the display containing it), independent mouse triggers (idle-then-click and scroll-then-pause), and keyboard trigger (letters then Return by default, or every Return). Pause capture anytime and exclude specific apps; full-display capture also filters excluded apps.
- **Keep your library locally.** Screenshots and notes are stored on your Mac. Original screenshots expire after 30 days by default; saved notes remain. You can change the retention period in Settings.
- **Decide when to use AI.** Organization uses your selected agent's model service, which may process screenshots and notes in the cloud. Turn off automatic organization to keep new captures local until you choose to process them.

<details>
<summary>Build from source</summary>

Requires Xcode 26, Swift 6.2, and XcodeGen.

```sh
swift test
xcodegen generate
xcodebuild -project MyClip.xcodeproj -scheme MyClip -configuration Debug build
```

To package a DMG, run `Scripts/package_dmg.sh`. The output is `dist/MyClip-<version>.dmg`.

</details>
