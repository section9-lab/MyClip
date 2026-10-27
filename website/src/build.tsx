import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { marked } from "marked";
import { absolute, guides } from "./content";
import { DemoPage, GuidePage, HomePage, NotFoundPage } from "./pages";

const repository = fileURLToPath(new URL("../../", import.meta.url));
const output = resolve(repository, "website/dist/MyClip");
await rm(output, { recursive: true, force: true });
await mkdir(resolve(output, "assets"), { recursive: true });
await mkdir(resolve(output, "images"), { recursive: true });

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
}

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

const urls = ["", "demo/", ...guides.map((guide) => `guides/${guide.slug}/`)];
await writeFile(
  resolve(output, "sitemap.xml"),
  `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map((path) => `  <url><loc>${absolute(path)}</loc></url>`).join("\n")}\n</urlset>\n`,
);
console.log(
  `Built ${urls.length} indexable pages and a custom 404 in ${output}`,
);
