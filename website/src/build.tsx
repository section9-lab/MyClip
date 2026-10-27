import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { marked } from "marked";
import { absolute, guideMarkdownPath, guides, site } from "./content";
import { DemoPage, GuidePage, HomePage, NotFoundPage } from "./pages";

const repository = fileURLToPath(new URL("../../", import.meta.url));
const output = resolve(repository, "website/dist");
await rm(output, { recursive: true, force: true });
await mkdir(resolve(output, "assets"), { recursive: true });
await mkdir(resolve(output, "images"), { recursive: true });
await cp(resolve(repository, "website/public"), output, { recursive: true });

async function page(path: string, content: ReactNode) {
  const destination = resolve(output, path);
  await mkdir(resolve(destination, ".."), { recursive: true });
  await writeFile(
    destination,
    `<!doctype html>\n${renderToStaticMarkup(content)}\n`,
  );
}

await page("index.html", <HomePage />);
await page("demo/index.html", <DemoPage />);
await page("404.html", <NotFoundPage />);
for (const guide of guides) {
  const markdown = await readFile(resolve(repository, guide.source), "utf8");
  const html = marked.parse(markdown.replace(/^# .+\r?\n/, ""), {
    async: false,
  });
  await page(
    `guides/${guide.slug}/index.html`,
    <GuidePage guide={guide} html={html} />,
  );
  await writeFile(resolve(output, guideMarkdownPath(guide.slug)), markdown);
}

await writeFile(
  resolve(output, "llms.txt"),
  [
    `# ${site.name}`,
    `> ${site.description}`,
    "MyClip is an open-source macOS app. It captures the focused application window, or that window's display when selected, and uses your chosen Agent to organize captures into searchable notes and tasks. It does not automatically import every AI conversation.",
    "Requires macOS 13+, Node.js 22+, and an account for your selected Agent. Apple Silicon and Intel builds are available from GitHub Releases.",
    "Screenshots and Markdown notes are stored on your Mac; OCR runs on-device. AI organization may use the selected Agent's cloud service. Connected MCP clients can retrieve saved notes and may receive short profile and current-focus summaries when they connect. The memory_search and memory_get tools are read-only: they do not edit notes, take screenshots, or start AI organization. Turn off MCP access in Settings to pause it.",
    "## Guides",
    guides
      .map(
        (guide) =>
          `- [${guide.title}](${absolute(guideMarkdownPath(guide.slug))}): ${guide.description}`,
      )
      .join("\n"),
    "## Project links",
    [
      `- [Product overview](${absolute()}): Features, installation, and privacy information.`,
      `- [Downloads](${site.repository}/releases/latest): Apple Silicon and Intel DMGs.`,
      `- [Source code](${site.repository}): Native app source, documentation, and issue tracking.`,
    ].join("\n"),
  ].join("\n\n") + "\n",
);

await cp(
  resolve(repository, "docs/images/myclip-icon.png"),
  resolve(output, "assets/myclip.png"),
);
await cp(
  resolve(repository, "docs/images/myclip-demo-poster.jpg"),
  resolve(output, "images/myclip-demo-poster.jpg"),
);
await cp(
  resolve(repository, "docs/images/myclip-demo.mp4"),
  resolve(output, "images/myclip-demo.mp4"),
);
await writeFile(resolve(output, ".nojekyll"), "");
await writeFile(resolve(output, "CNAME"), `${new URL(site.origin).hostname}\n`);
await writeFile(
  resolve(output, "robots.txt"),
  `User-agent: *\nAllow: /\n\nSitemap: ${absolute("sitemap.xml")}\n`,
);

const urls = ["", "demo/", ...guides.map((guide) => `guides/${guide.slug}/`)];
await writeFile(
  resolve(output, "sitemap.xml"),
  `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map((path) => `  <url><loc>${absolute(path)}</loc></url>`).join("\n")}\n</urlset>\n`,
);
console.log(
  `Built ${urls.length} indexable pages and a custom 404 in ${output}`,
);
