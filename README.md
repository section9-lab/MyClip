<div align="center">
  <img src="MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="MyClip icon" width="120" height="120">
  <h1 align="center">MyClip — AI screen memory for Mac</h1>

  <p align="center">Turn your work into searchable memories. Give your AI the context to continue.</p>
</div>

<p align="center">
  <strong>English</strong> · <a href="docs/README.zh-CN.md">简体中文</a> · <a href="docs/README.es.md">Español</a> · <a href="docs/README.fr.md">Français</a> · <a href="docs/README.de.md">Deutsch</a> · <a href="docs/README.ja.md">日本語</a> · <a href="docs/README.ko.md">한국어</a>
</p>

MyClip is a local-first macOS app that turns screenshots of your work into searchable Markdown memories and tasks. Its built-in **Model Context Protocol (MCP) server** lets **Codex**, **Claude Code**, and other MCP clients search saved work context and follow it back to source captures.

<p align="center">
  <a href="https://myclip.vibevibe.cc/">Website</a> · <a href="https://github.com/section9-lab/MyClip/releases/latest">Download for Mac</a> · <a href="docs/integrations/codex.md">Codex setup</a> · <a href="docs/integrations/claude-code.md">Claude Code setup</a>
</p>

<p align="center">
  <a href="https://myclip.vibevibe.cc/demo/"><img src="docs/images/myclip-demo.gif" alt="MyClip desktop demo: onboarding, Memory, Timeline, Kanban, Reports, Backstage, Settings, and memory recall in Codex and Claude" width="1000"></a>
</p>
<p align="center"><a href="https://myclip.vibevibe.cc/demo/">Watch HD video</a></p>

## Search and recall your work

- **Memory** — searchable Markdown notes with links to their sources.
- **Timeline** — searchable screenshot history with on-device OCR text.
- **Kanban** — tasks, progress, and daily, weekly, or monthly reports.

Screenshots and notes are saved on your Mac. AI organization may use your Agent’s cloud service. Enable **MyClip MCP** to let your AI tools search saved memories.

For example, ask your Agent: “Use MyClip to find the project decision I reviewed yesterday. Include the source captures and their dates.” Results depend on what you captured and organized. MyClip does not automatically import every AI conversation.

## Installation

Requires **macOS 13+**, **Node.js 22+**, and an account for your selected Agent.

1. Download the Apple Silicon or Intel DMG from [Releases](https://github.com/section9-lab/MyClip/releases/latest) and move MyClip to **Applications**.
2. Open MyClip, choose an Agent, and click **Get Started**.
3. Grant **Screen Recording** and **Accessibility** permissions. MyClip captures and organizes automatically while it is open.

Capture scope, excluded apps, and automatic organization can be changed in **Settings**. Quit MyClip to stop capture.

Choose models in **Backstage**. Every supported Agent loads its own searchable list and remembers its selection for later sessions; no model names are hardcoded. See [model selection](docs/agent-model-selection.md).

Releases are self-signed and not notarized. If macOS blocks the first launch, see [installation help](docs/release-signing.md#installing-a-community-build).

## MCP memory access for Codex and Claude Code

In **Settings → MCP memory access**, enable the service, select your clients, and run the one-click configuration. Restart the clients or open a new session after setup.

| Client | Setup guide |
| --- | --- |
| Codex | [Connect Codex to your Mac work memories](docs/integrations/codex.md) |
| Claude Code | [Search MyClip memories from Claude Code](docs/integrations/claude-code.md) |

MyClip also includes setup for Claude Desktop, Cursor, OpenCode, and WorkBuddy. The local server exposes two read-only tools: `memory_search` finds relevant excerpts; `memory_get` reads a returned memory path or section with links and source information. Queries do not edit memories, take screenshots, or start AI organization.

Connected clients receive retrieved memory content and may receive short summaries of updated profile and current-focus notes when they connect. Their own data settings apply. Turn off the MCP service in MyClip Settings to pause access.

## Contributing

See [development](docs/development.md) for the native app and [website maintenance](website/README.md) for the static product site and search metadata.
