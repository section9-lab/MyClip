import type { ReactNode } from "react";
import { ArrowUpRight } from "lucide-react";
import { absolute, guideMarkdownPath, guides, href, site } from "../content";
import { cn } from "../lib/utils";

interface LayoutProps {
  title: string;
  description: string;
  path?: string;
  noIndex?: boolean;
  children: ReactNode;
}

export function Layout({
  title,
  description,
  path = "",
  noIndex = false,
  children,
}: LayoutProps) {
  const canonical = absolute(path);
  const guide = guides.find((item) => path === `guides/${item.slug}/`);
  const schema = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: site.name,
    url: absolute(),
    description: site.description,
    operatingSystem: "macOS 13.0 or later",
    applicationCategory: "ProductivityApplication",
    image: absolute("images/myclip-demo-poster.jpg"),
    downloadUrl: `${site.repository}/releases/latest`,
    sameAs: site.repository,
  };

  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{title}</title>
        <meta name="description" content={description} />
        <link rel="canonical" href={canonical} />
        {!noIndex && <link rel="describedby" href={absolute("llms.txt")} />}
        {guide && (
          <link
            rel="alternate"
            type="text/markdown"
            href={absolute(guideMarkdownPath(guide.slug))}
            title={`${guide.title} (Markdown)`}
          />
        )}
        {noIndex && <meta name="robots" content="noindex" />}
        <link rel="icon" type="image/x-icon" href={href("favicon.ico")} />
        <link
          rel="icon"
          type="image/png"
          sizes="256x256"
          href={href("favicon.png")}
        />
        <link
          rel="apple-touch-icon"
          sizes="180x180"
          href={href("apple-touch-icon.png")}
        />
        <link rel="stylesheet" href={href("assets/site.css")} />
        <meta property="og:type" content="website" />
        <meta property="og:site_name" content={site.name} />
        <meta property="og:title" content={title} />
        <meta property="og:description" content={description} />
        <meta property="og:url" content={canonical} />
        <meta
          property="og:image"
          content={absolute("images/myclip-demo-poster.jpg")}
        />
        <meta
          property="og:image:alt"
          content="MyClip Memory view in the desktop demonstration, using sample data"
        />
        <meta name="twitter:card" content="summary_large_image" />
        {path === "" && (
          <script
            type="application/ld+json"
            dangerouslySetInnerHTML={{
              __html: JSON.stringify(schema).replace(/</g, "\\u003c"),
            }}
          />
        )}
      </head>
      <body>
        <a
          href="#content"
          className="sr-only rounded-lg bg-background px-4 py-3 focus:not-sr-only focus:fixed focus:top-3 focus:left-3 focus:z-50"
        >
          Skip to content
        </a>
        <header className="mx-auto max-w-5xl px-5 sm:px-8">
          <div className="flex flex-wrap items-center justify-between gap-4 border-b py-5">
            <a
              href={href()}
              aria-label="MyClip home"
              className="flex items-center gap-2 rounded-lg font-semibold tracking-tight"
            >
              <img
                src={href("assets/myclip.png")}
                alt=""
                width="32"
                height="32"
              />
              MyClip
            </a>
            <nav
              aria-label="Main navigation"
              className="flex flex-wrap items-center gap-x-5 gap-y-3 text-sm"
            >
              <a
                className="rounded-sm underline-offset-4 hover:underline"
                href={href("#how-it-works")}
              >
                Overview
              </a>
              {guides.map((guide) => {
                const selected = path === `guides/${guide.slug}/`;
                return (
                  <a
                    key={guide.slug}
                    href={href(`guides/${guide.slug}/`)}
                    aria-current={selected ? "page" : undefined}
                    className={cn(
                      "rounded-sm underline-offset-4 hover:underline",
                      selected && "underline",
                    )}
                  >
                    {guide.label}
                  </a>
                );
              })}
              <a
                className="rounded-sm underline-offset-4 hover:underline"
                href={site.repository}
              >
                GitHub
              </a>
            </nav>
          </div>
        </header>
        {children}
        <footer className="mx-auto max-w-5xl px-5 sm:px-8">
          <div className="flex flex-col justify-between gap-5 border-t py-6 text-xs text-muted-foreground sm:flex-row">
            <p>MyClip · Open source</p>
            <nav
              aria-label="Footer navigation"
              className="flex flex-wrap gap-x-6 gap-y-3"
            >
              <a className="hover:text-foreground" href={href("#privacy")}>
                Data & privacy
              </a>
              <a
                className="hover:text-foreground"
                href={`${site.repository}/issues`}
              >
                Support
              </a>
              <a
                className="inline-flex items-center gap-1 hover:text-foreground"
                href={site.repository}
              >
                Source on GitHub{" "}
                <ArrowUpRight className="size-3.5" aria-hidden="true" />
              </a>
            </nav>
          </div>
        </footer>
      </body>
    </html>
  );
}
