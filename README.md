<div align="center">
  <img src="MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="MyClip icon" width="120" height="120">
  <h1 align="center">MyClip</h1>

  <p align="center">Turn your work on Mac into searchable memories and tasks.</p>
</div>

<p align="center">
  <strong>English</strong> · <a href="docs/README.zh-CN.md">简体中文</a> · <a href="docs/README.es.md">Español</a> · <a href="docs/README.fr.md">Français</a> · <a href="docs/README.de.md">Deutsch</a> · <a href="docs/README.ja.md">日本語</a> · <a href="docs/README.ko.md">한국어</a>
</p>

<p align="center">
  <a href="https://section9-lab.github.io/MyClip/demo/"><img src="docs/images/myclip-demo.gif" alt="MyClip desktop demo: onboarding, Memory, Timeline, Kanban, Reports, Backstage, Settings, and memory recall in Codex and Claude" width="1000"></a>
</p>
<p align="center"><a href="https://section9-lab.github.io/MyClip/demo/">Watch HD video</a></p>

MyClip captures your work and uses your selected AI Agent to organize it:

- **Memory** — searchable Markdown notes with links to their sources.
- **Timeline** — a screenshot history with on-device OCR text.
- **Kanban** — tasks, progress, and daily, weekly, or monthly reports.

Screenshots and notes are saved on your Mac. AI organization may use your Agent’s cloud service. Enable **MyClip MCP** to let your AI tools search saved memories.

## Installation

Requires **macOS 13+**, **Node.js 22+**, and an account for your selected Agent.

1. Download the Apple Silicon or Intel DMG from [Releases](https://github.com/section9-lab/MyClip/releases) and move MyClip to **Applications**.
2. Open MyClip, choose an Agent, and click **Get Started**.
3. Grant **Screen Recording** and **Accessibility** permissions. MyClip captures and organizes automatically while it is open.

Capture scope, excluded apps, and automatic organization can be changed in **Settings**. Quit MyClip to stop capture.

Choose models in **Backstage**. Every supported Agent loads its own searchable list and remembers its selection for later sessions; no model names are hardcoded. See [model selection](docs/agent-model-selection.md).

Releases are self-signed and not notarized. If macOS blocks the first launch, see [installation help](docs/release-signing.md#installing-a-community-build).
