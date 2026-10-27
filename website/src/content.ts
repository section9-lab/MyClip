export const site = {
  name: "MyClip",
  origin: "https://myclip.vibevibe.cc",
  basePath: "/",
  repository: "https://github.com/section9-lab/MyClip",
  description:
    "Searchable screen history for macOS. MyClip turns screenshots into Markdown notes and tasks, with MCP access for Codex and Claude Code.",
} as const;

export function href(path = "") {
  return `${site.basePath}${path}`;
}

export function absolute(path = "") {
  return `${site.origin}${href(path)}`;
}

export const guides = [
  {
    slug: "search-screen-history",
    label: "Screen history",
    category: "Using MyClip",
    title: "How to search your screen history on Mac",
    pageTitle: "How to Search Screen History on Mac — MyClip",
    description:
      "Find a captured screen in MyClip: search its text, filter by app or date, and open the original screenshot to check what you saw.",
    source: "docs/guides/search-screen-history.md",
  },
  {
    slug: "codex",
    label: "Codex",
    category: "MCP setup",
    title: "Connect MyClip to Codex",
    pageTitle: "Codex MCP Memory Setup for Mac — MyClip",
    description:
      "Set up MyClip's local MCP server, check the connection, and search saved notes from Codex.",
    source: "docs/integrations/codex.md",
  },
  {
    slug: "claude-code",
    label: "Claude Code",
    category: "MCP setup",
    title: "Connect MyClip to Claude Code",
    pageTitle: "Claude Code MCP Memory Setup for Mac — MyClip",
    description:
      "Connect Claude Code to MyClip, then search and read the notes saved on your Mac.",
    source: "docs/integrations/claude-code.md",
  },
] as const;

export type Guide = (typeof guides)[number];

export function guideMarkdownPath(slug: Guide["slug"]) {
  return `guides/${slug}/index.md`;
}
