# MyClip product website

Source for <https://myclip.vibevibe.cc/>. The product overview, demo wrapper, screen history guide, and MCP setup guides are rendered to static HTML. Visitors do not download React or require JavaScript to read the pages or follow download links.

## Build and preview

Requires Node.js 22+ and Python 3 for the local preview server.

```sh
npm ci --prefix website
npm run check --prefix website
npm run build --prefix website
npm run verify --prefix website
npm run preview --prefix website
```

Open <http://127.0.0.1:4173/>. Output lives in the ignored `website/dist/` directory. The site uses the root path on its custom domain, so assets and navigation resolve the same way locally and in production.

- `src/content.ts`: canonical origin, base path, shared description, and guide metadata.
- `src/pages.tsx`: product page, demo page, and reusable guide layout.
- `src/components/ui/`: locally owned shadcn/ui Nova components, adapted from the official MIT-licensed registry. See [third-party notices](THIRD_PARTY_NOTICES.md).
- `src/styles.css`: shared shadcn tokens and Tailwind CSS. Icons use Lucide. There are no scripted animations or client-side state dependencies.
- `../docs/guides/` and `../docs/integrations/`: Markdown guides shared between GitHub and the website.
- `public/`: static files copied unchanged to the site root, including the Google Search Console verification file. Keep verification files after ownership verification so subsequent builds preserve access. Google verification HTML is excluded from formatting to preserve the supplied bytes.
- Root favicon files reuse `../docs/images/myclip-icon.png`: `favicon.ico` contains 16, 32, 48, 64, 128, and 256 px variants, `favicon.png` retains the 256 px source, and `apple-touch-icon.png` is 180 px. The shared layout advertises these files on every page.
- `llms.txt` and `guides/*/index.md`: generated documentation entry points for clients that read Markdown. The guide exports use the same tracked sources as the HTML pages.
- `scripts/verify.ts`: checks generated metadata, internal links and fragments, HTML landmarks, image alternatives, and sitemap coverage.

Build dependencies are isolated here because the native Swift application has no web UI packages. React renders HTML only during the build; Tailwind compiles CSS. Marked renders the repository-owned guides, and LinkeDOM inspects the generated HTML. There is no runtime API, analytics service, or browser dependency.

## Publication

The `Publish website` workflow runs checks and builds on relevant pushes to `main`, then copies the output into the existing `gh-pages` branch without deleting other published files, including Google verification files. The build generates a root `CNAME` containing `myclip.vibevibe.cc` so subsequent publications preserve the custom domain. It explicitly requests a Pages build because a push made with `GITHUB_TOKEN` does not trigger one automatically. The repository's existing branch-based GitHub Pages deployment remains in place. A manual workflow run is also available.

The existing 45-second MP4 and poster are reused. The website build owns the published `/demo/` wrapper; the original HyperFrames composition and export workflow in `docs/demo/` remain separate.

The workflow needs Contents write permission for `gh-pages` and Pages write permission to request the build. If branch protection blocks that push, use the normal repository approval process rather than force-pushing.

## Search maintenance

Each indexable page has a unique title and description, a self-referencing canonical, social metadata, readable HTML, and links to the other pages. The homepage includes SoftwareApplication structured data without invented ratings. `sitemap.xml` lists the homepage, demo, and all guides. The custom 404 is marked `noindex`.

The build generates `/llms.txt` with a concise project summary and links to the Markdown guides. Indexable HTML pages advertise it with `rel="describedby"`; guide pages also provide `rel="alternate" type="text/markdown"` links. The exports are for documentation access, not a Google ranking signal. The sitemap lists canonical HTML pages rather than their Markdown copies. No duplicate `site.xml` or nonstandard `llm.xml` files are generated.

The build generates `https://myclip.vibevibe.cc/robots.txt` at the custom domain's root. It allows crawling and advertises `https://myclip.vibevibe.cc/sitemap.xml`. The sitemap, canonical links, social metadata, and guide links all use the custom domain.

To measure Google discovery, verify the URL-prefix property `https://myclip.vibevibe.cc/` in Google Search Console using an account you control, or use an already verified `vibevibe.cc` Domain property. Add the exact verification tag, file, or DNS record supplied by Google as needed, submit `https://myclip.vibevibe.cc/sitemap.xml`, and inspect the page URLs. Verification credentials and Search Console access are not fabricated or included in this repository. Keep the old GitHub Pages resource for migration monitoring and confirm its URLs redirect to the corresponding custom-domain pages.

Use Search Console query impressions and clicks to distinguish branded discovery from category and integration searches. Track download conversions only after choosing an analytics approach; no tracking has been added by this change. Sitemap submission and good metadata do not guarantee indexing or rankings.
