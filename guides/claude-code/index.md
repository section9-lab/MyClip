# Search your Mac work memories from Claude Code with MyClip MCP

MyClip gives Claude Code access to work context saved from your Mac. It captures your focused application window, or its display when selected, and uses your chosen Agent to organize captures into searchable Markdown memories and tasks.

The built-in Model Context Protocol (MCP) server lets Claude Code search those memories and read their supporting context. This can help you recover a decision you reviewed in another app or resume work without manually finding the original note.

MyClip's screen-derived memories complement Claude Code's own memory features. MyClip does not automatically archive every Claude conversation, and its MCP tools cannot write memories.

## Before you connect

- Install MyClip in **Applications** and finish onboarding. It requires **macOS 13+**, **Node.js 22+**, and an account for your selected organizing Agent.
- Install and sign in to Claude Code on the same Mac.
- Grant MyClip Screen Recording and Accessibility permissions. Check that **Memory** contains at least one organized note before testing retrieval.

Get the Apple Silicon or Intel build from [MyClip Releases](https://github.com/section9-lab/MyClip/releases/latest). If macOS blocks the community build, follow the [installation instructions](https://github.com/section9-lab/MyClip/blob/main/docs/release-signing.md#installing-a-community-build).

## Connect from MyClip Settings

1. Open MyClip **Settings**, then locate **MCP memory access** (**MCP 记忆访问** in Chinese).
2. Turn on **Enable MyClip MCP service** (**启用 MyClip MCP 服务**).
3. Select **Claude Code**, the command-line client, and click the configuration button below the client icons (**一键开启**).
4. Check the setup result, then restart Claude Code or open a new session.

MyClip writes a user-level `myclip` stdio entry in `~/.claude.json` and preserves unrelated settings. When `CLAUDE_CONFIG_DIR` is set, MyClip uses `.claude.json` in that directory. An existing file is backed up once as `.myclip-backup` before it is changed.

**Claude Code and Claude Desktop use separate configurations.** To connect the Claude chat desktop app, select **Claude Desktop** separately in MyClip Settings. It uses `~/Library/Application Support/Claude/claude_desktop_config.json` and requires a full quit and restart.

## Configure manually with the Claude Code CLI

Choose this method if you prefer the CLI to MyClip's Settings configuration. This example assumes the standard app location and default library. Replace `--library` with your actual absolute library path if you use a different one.

```sh
claude mcp add --transport stdio --scope user myclip -- \
  /Applications/MyClip.app/Contents/MacOS/MyClip --mcp \
  --library "$HOME/Library/Application Support/MyClip"

claude mcp get myclip
```

The `--scope user` option makes the server available across your local projects. Keep the MyClip MCP service enabled, and restart Claude Code after configuring it. Inspect an existing `myclip` entry before replacing it.

Inside Claude Code, run `/mcp` to inspect the connection and any tool approvals. The [official Claude Code MCP documentation](https://code.claude.com/docs/en/mcp) describes scopes, policies, and current client commands.

## Retrieve context with a specific question

Try these prompts against your own captured work:

> Use MyClip to find the API design I reviewed yesterday. Include the date and source capture IDs, and distinguish old evidence from the current state.

> Search MyClip for my recent work on the release checklist. Follow linked memories if the search excerpts do not contain the decision.

The server provides two read-only tools:

| Tool | Use it for |
| --- | --- |
| `memory_search` | Finding relevant excerpts with a question or keywords. Optional `since`, `until`, and `app` filters narrow the results. |
| `memory_get` | Reading a returned memory path or `path#heading`, including linked memories, backlinks, and source capture information. |

For example, an Agent can call `memory_search` with these arguments:

```json
{
  "query": "release checklist",
  "limit": 5
}
```

Results depend on your actual saved memories. The Agent should use the returned path for `memory_get`, cite the source capture IDs, and indicate when evidence is old or undated. These examples do not represent an actual user's history.

## Troubleshoot connection and empty results

- **The server does not appear:** check `/mcp`, restart Claude Code, and verify that you selected Claude Code rather than Claude Desktop in MyClip Settings.
- **The server appears in only one project:** a manual installation may use project-local scope. Inspect it with `claude mcp get myclip`; MyClip's Settings method configures user-level access.
- **The process cannot start:** ensure MyClip remains in `/Applications`, or reconfigure after moving it. Check the executable path in the client entry.
- **Queries say access is disabled:** turn on the MCP service in MyClip Settings. Configuration alone does not enable a paused service.
- **Search is empty:** confirm that AI organization has finished and that Memory contains notes. Try a broader query and remove optional filters. The server searches existing memories and does not organize queued screenshots on demand.
- **Your organization blocks MCP:** follow Claude Code's managed policy. MyClip does not override client permissions.

## What is shared

MyClip stores screenshots and notes locally. AI organization may use your selected Agent's cloud service. Retrieved memories become available to Claude Code under that client's own data settings. At connection time, the server may also share short summaries from updated `Profile.md` and `Now.md` files.

`memory_search` and `memory_get` do not modify memories or trigger new captures. Turn off MyClip's MCP service to pause access and connection summaries. MyClip captures new work while the app is open; quit the app to stop capture.

See the [MyClip product overview](https://section9-lab.github.io/MyClip/) and the [Codex setup guide](https://section9-lab.github.io/MyClip/guides/codex/) for another supported client.
