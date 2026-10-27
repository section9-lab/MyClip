# Give Codex access to your Mac work memories with MyClip MCP

MyClip turns captured work on your Mac into searchable Markdown memories. Its built-in Model Context Protocol (MCP) server lets Codex retrieve that context: a project decision you read in a browser, the work you were doing yesterday, or a note linked to a source capture.

MyClip captures work in macOS applications. It does not automatically import all of your Codex conversations. MCP provides read-only access to memories that MyClip has already saved.

## Before you connect

- Install MyClip in **Applications** and complete its onboarding. MyClip requires **macOS 13+**, **Node.js 22+**, and an account for the Agent you use to organize captures.
- Install and sign in to Codex on the same Mac.
- Grant MyClip Screen Recording and Accessibility permissions. Let it capture work and finish organizing at least one memory, then check **Memory** in MyClip.

Download the Apple Silicon or Intel build from [MyClip Releases](https://github.com/section9-lab/MyClip/releases/latest). Community builds are self-signed and not notarized; see [installation help](https://github.com/section9-lab/MyClip/blob/main/docs/release-signing.md#installing-a-community-build) if macOS blocks the first launch.

## Connect from MyClip Settings

1. Open **Settings** in MyClip and find **MCP memory access** (Chinese interface: **MCP 记忆访问**).
2. Turn on **Enable MyClip MCP service** (**启用 MyClip MCP 服务**).
3. Select **Codex**, then click the configuration button beneath the client icons (**一键开启**).
4. Wait for the client result to show that configuration succeeded. Restart your Codex client or open a new session so it discovers the tools.

MyClip registers its own executable as the local `myclip` MCP server, using the current library path. The installer uses Codex's `mcp add` command. It makes a `.myclip-backup` copy of an existing configuration before the first installation.

## Configure manually with the Codex CLI

The following example assumes MyClip is installed in `/Applications` and uses its default library. If you use a custom library, replace the `--library` argument with that library's absolute path. Choose either the Settings method or this manual method.

```sh
codex mcp add myclip -- \
  /Applications/MyClip.app/Contents/MacOS/MyClip --mcp \
  --library "$HOME/Library/Application Support/MyClip"

codex mcp list
```

Keep **MyClip MCP service** enabled in MyClip Settings. Adding a client configuration does not override a disabled service. If `myclip` is already configured, inspect its current command and arguments before replacing it.

Codex stores user-level configuration in `~/.codex/config.toml`, or under a custom `CODEX_HOME`. In the CLI's interactive session, `/mcp` shows active MCP servers. See the [official OpenAI MCP documentation](https://developers.openai.com/codex/mcp/) for current Codex configuration options.

## Ask Codex to retrieve work context

These are example prompts; answers depend on what you have captured and organized:

> Use MyClip to find my recent work on the release checklist. Cite the source captures and their dates, and tell me if the evidence is old.

> Search MyClip for the project decision I was reviewing yesterday. Read the linked memory if the search excerpt is incomplete.

MyClip exposes two tools:

| Tool | What it does |
| --- | --- |
| `memory_search` | Searches saved memories with a question or keywords. Optional filters include `since`, `until`, and `app`. Results contain excerpts, memory paths, times, source capture IDs, and linked memories. |
| `memory_get` | Reads a memory by the returned path, or `path#heading` for one section. It includes links, backlinks, and source capture information. |

Start with `memory_search`, then use `memory_get` when more context is needed. The `since` lower bound is inclusive and the `until` upper bound is exclusive; both accept ISO 8601 timestamps. Capture dates describe the evidence and do not guarantee that a fact is still current.

## When the tools or results are missing

- **Codex is not found during setup:** install the Codex app or CLI, then retry configuration in MyClip Settings.
- **The server is configured but tools are missing:** restart the client or start a new session and inspect `/mcp`. Check that the configured executable still exists if you moved MyClip.
- **MyClip MCP is disabled:** enable it in MyClip Settings. Existing client configurations remain in place when access is paused.
- **Search returns no results:** confirm that Memory contains organized notes, try the project's own wording, and remove date or application filters. A screenshot waiting for AI organization may not have a searchable memory yet.
- **The wrong library is queried:** run the Settings configuration again after changing your library, or update the manual `--library` argument.
- **A client policy blocks the server:** follow the client's MCP approval or organization policy. MyClip's setup cannot override that policy.

## Local storage and Agent access

Screenshots and Markdown memories are stored on your Mac. AI organization may send captures to your selected Agent's cloud service. Connecting Codex makes retrieved memory content available to Codex under its own data settings. A short summary of updated `Profile.md` and `Now.md` files may also be shared when the MCP connection starts.

Both MCP tools are read-only: they do not edit memories, trigger capture, or start AI organization. Turn off **MyClip MCP service** to pause memory queries and connection summaries. Keep MyClip open when you want to capture new work; quit it to stop capture.

Continue with the [MyClip product overview](https://myclip.vibevibe.cc/) or the [Claude Code setup guide](https://myclip.vibevibe.cc/guides/claude-code/).
