import assert from "node:assert/strict";
import { access, readFile, stat } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseHTML } from "linkedom";
import { absolute, guides, href, site } from "../src/content";

const root = fileURLToPath(new URL("../dist/MyClip/", import.meta.url));
const pages = [
  "index.html",
  "demo/index.html",
  ...guides.map((guide) => `guides/${guide.slug}/index.html`),
  "404.html",
];
const titles = new Set<string>();
let checkedLinks = 0;

for (const path of pages) {
  const { document } = parseHTML(await readFile(resolve(root, path), "utf8"));
  assert.equal(
    document.documentElement.lang,
    "en",
    `${path}: document language`,
  );
  assert.equal(
    document.querySelectorAll("h1").length,
    1,
    `${path}: one primary heading`,
  );
  assert(
    document.querySelector("main#content"),
    `${path}: main landmark and skip target`,
  );
  assert(
    document.querySelector('a[href="#content"]'),
    `${path}: keyboard skip link`,
  );
  const title = document.querySelector("title")?.textContent;
  assert(title && !titles.has(title), `${path}: unique title`);
  titles.add(title);
  assert(
    document.querySelector('meta[name="description"]')?.getAttribute("content"),
    `${path}: description`,
  );
  const canonical = document
    .querySelector('link[rel="canonical"]')
    ?.getAttribute("href");
  assert(canonical, `${path}: canonical is present`);
  assert.equal(
    canonical,
    absolute(path === "index.html" ? "" : path.replace(/index\.html$/, "")),
    `${path}: canonical`,
  );
  assert.equal(
    document.querySelector('meta[property="og:url"]')?.getAttribute("content"),
    canonical,
  );
  assert.equal(
    Boolean(document.querySelector('meta[name="robots"][content="noindex"]')),
    path === "404.html",
  );
  assert.equal(
    document.querySelectorAll('script:not([type="application/ld+json"])')
      .length,
    0,
    `${path}: no browser JavaScript needed`,
  );
  for (const script of document.querySelectorAll(
    'script[type="application/ld+json"]',
  )) {
    const data: unknown = JSON.parse(script.textContent ?? "");
    assert(data && typeof data === "object", `${path}: valid structured data`);
  }
  const ids = Array.from(document.querySelectorAll("[id]")).map(
    (element) => element.id,
  );
  assert.equal(ids.length, new Set(ids).size, `${path}: unique IDs`);

  for (const element of document.querySelectorAll(
    "a[href], img[src], link[href], source[src]",
  )) {
    const reference =
      element.getAttribute("href") ?? element.getAttribute("src");
    if (!reference) continue;
    if (element.tagName === "A")
      assert(
        element.textContent?.trim() || element.getAttribute("aria-label"),
        `${path}: named link ${reference}`,
      );
    if (element.tagName === "IMG")
      assert(element.hasAttribute("alt"), `${path}: image alternative`);
    const url = new URL(reference, canonical);
    if (url.origin !== site.origin) continue;
    assert(
      url.pathname.startsWith(site.basePath),
      `${path}: link remains under project base ${reference}`,
    );
    const relative = decodeURIComponent(
      url.pathname.slice(site.basePath.length),
    );
    const target = resolve(root, relative || "index.html");
    await access(target);
    const info = await stat(target);
    const targetPage = info.isDirectory()
      ? resolve(target, "index.html")
      : target;
    await access(targetPage);
    if (url.hash) {
      const targetDocument = parseHTML(
        await readFile(targetPage, "utf8"),
      ).document;
      assert(
        targetDocument.getElementById(decodeURIComponent(url.hash.slice(1))),
        `${path}: valid fragment ${reference}`,
      );
    }
    checkedLinks += 1;
  }
}

const sitemap = await readFile(resolve(root, "sitemap.xml"), "utf8");
assert.equal((sitemap.match(/<loc>/g) ?? []).length, 4);
for (const path of [
  "",
  "demo/",
  ...guides.map((guide) => `guides/${guide.slug}/`),
])
  assert(sitemap.includes(`<loc>${absolute(path)}</loc>`));
assert(!sitemap.includes("404.html"));
assert(
  (await readFile(resolve(root, "assets/site.css"), "utf8")).length > 1000,
);
assert.equal(href(), "/MyClip/");
console.log(
  `Verified ${pages.length} pages, ${checkedLinks} internal references, metadata, sitemap, structured data, and static HTML access.`,
);
