export const site = {
  name: "MyClip",
  origin: "https://section9-lab.github.io",
  basePath: "/MyClip/",
  repository: "https://github.com/section9-lab/MyClip",
  description:
    "AI screen memory for macOS. Capture your work as searchable Markdown notes and tasks. Let Codex and Claude Code recall saved context through a built-in MCP server.",
} as const;

export function href(path = "") {
  return `${site.basePath}${path}`;
}

export function absolute(path = "") {
  return `${site.origin}${href(path)}`;
}

export const guides = [
  {
    slug: "codex",
    client: "Codex",
    title: "Give Codex access to your Mac work memories",
    pageTitle: "Codex MCP Memory Setup for Mac — MyClip",
    description:
      "Connect MyClip's local MCP server to Codex. Search work memories captured on your Mac, read linked notes, and cite the source evidence.",
    source: "docs/integrations/codex.md",
  },
  {
    slug: "claude-code",
    client: "Claude Code",
    title: "Search your Mac work memories from Claude Code",
    pageTitle: "Claude Code MCP Memory Setup for Mac — MyClip",
    description:
      "Set up MyClip MCP for Claude Code on macOS. Retrieve screen-derived work context with read-only memory search, setup examples, and troubleshooting.",
    source: "docs/integrations/claude-code.md",
  },
] as const;

export type Guide = (typeof guides)[number];
