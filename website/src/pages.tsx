import type { ReactNode } from "react";
import { ArrowRight, BookOpen, Download } from "lucide-react";
import { guides, href, site, type Guide } from "./content";
import { Layout } from "./components/layout";
import { Button } from "./components/ui/button";
import { cn } from "./lib/utils";

function TextLink({
  href: url,
  children,
}: {
  href: string;
  children: ReactNode;
}) {
  return (
    <a
      href={url}
      className="inline-flex items-center gap-2 rounded-sm text-sm font-medium underline-offset-4 hover:underline"
    >
      {children}
      <ArrowRight className="size-3.5" aria-hidden="true" />
    </a>
  );
}

function DemoVideo({
  autoPlay = false,
  className,
  descriptionId,
}: {
  autoPlay?: boolean;
  className?: string;
  descriptionId: string;
}) {
  return (
    <video
      className={cn("h-auto w-full rounded-lg border bg-muted", className)}
      width="1600"
      height="1000"
      autoPlay={autoPlay}
      muted={autoPlay}
      controls
      playsInline
      preload="metadata"
      poster={href("images/myclip-demo-poster.jpg")}
      aria-label="MyClip desktop demo with sample data and illustrated Agent interactions"
      aria-describedby={descriptionId}
    >
      <source src={href("images/myclip-demo.mp4")} type="video/mp4" />
      <a href={href("images/myclip-demo.mp4")}>Download the demo video</a>
    </video>
  );
}

function HomeSection({
  id,
  title,
  children,
}: {
  id: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <section
      id={id}
      className="grid gap-5 border-t py-8 sm:py-10 md:grid-cols-3 md:gap-12"
    >
      <h2 className="text-base font-semibold">{title}</h2>
      <div className="min-w-0 text-sm leading-7 md:col-span-2">{children}</div>
    </section>
  );
}

const modules = [
  {
    name: "Timeline",
    description:
      "Screenshots of the window you’re working in, with on-device OCR so you can search the text. You can also choose to capture the window’s display.",
  },
  {
    name: "Memory",
    description:
      "Markdown notes organized by your chosen Agent, linked to related notes and the screenshots they came from.",
  },
  {
    name: "Kanban",
    description:
      "Suggested tasks to review, a board for tracking progress, and daily, weekly, or monthly work reports.",
  },
] as const;

export function HomePage() {
  return (
    <Layout
      title="MyClip — Searchable Screen History for Mac"
      description={site.description}
    >
      <main id="content" className="mx-auto max-w-5xl px-5 sm:px-8">
        <section className="pt-10 pb-8 sm:pt-14 sm:pb-10">
          <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">
            MyClip
          </h1>
          <p className="mt-3 text-xl leading-8 tracking-tight sm:text-2xl">
            Searchable screen history for Mac.
          </p>
          <p className="mt-5 max-w-2xl text-base leading-7 text-muted-foreground">
            MyClip captures the window you’re working in and organizes
            screenshots into Markdown notes and tasks. Codex and Claude can
            search those notes through MCP.
          </p>
          <div className="mt-6 flex flex-wrap items-center gap-x-6 gap-y-4">
            <Button asChild size="lg" className="gap-2 px-4">
              <a href={`${site.repository}/releases/latest`}>
                <Download aria-hidden="true" />
                Download for Mac
              </a>
            </Button>
            <TextLink href="#demo">Watch the demo</TextLink>
          </div>
          <p className="mt-4 text-xs leading-6 text-muted-foreground">
            Apple Silicon & Intel · macOS 13+ · Node.js 22+ · Agent account
            required
          </p>
        </section>

        <figure id="demo" className="pb-8 sm:pb-10">
          <DemoVideo autoPlay descriptionId="home-demo-caption" />
          <figcaption
            id="home-demo-caption"
            className="mt-3 flex flex-wrap justify-between gap-x-6 gap-y-1 text-xs leading-6 text-muted-foreground"
          >
            <span>
              45-second silent video · HTML reconstruction · Sample data ·
              Chinese interface.
              <br />
              The Codex and Claude interactions are illustrations.
            </span>
            <a
              href={href("demo/")}
              className="rounded-sm underline underline-offset-4"
            >
              Open demo page
            </a>
          </figcaption>
        </figure>

        <HomeSection id="how-it-works" title="What it keeps">
          <dl className="divide-y">
            {modules.map(({ name, description }) => (
              <div
                key={name}
                className="grid gap-1 py-4 first:pt-0 last:pb-0 sm:grid-cols-4 sm:gap-5"
              >
                <dt className="font-medium">{name}</dt>
                <dd className="text-muted-foreground sm:col-span-3">
                  {description}
                </dd>
              </div>
            ))}
          </dl>
          <div className="mt-5">
            <TextLink href={href("guides/search-screen-history/")}>
              How to search your screen history
            </TextLink>
          </div>
        </HomeSection>

        <HomeSection id="setup" title="Use it with your Agent">
          <p className="text-muted-foreground">
            In MyClip Settings, enable MCP memory access and select your client.
            After setup, restart the client or open a new session. It can then
            search and read your saved notes.
          </p>
          <div className="mt-4 flex flex-wrap gap-x-6 gap-y-3">
            {guides
              .filter((guide) => guide.category === "MCP setup")
              .map((guide) => (
                <TextLink key={guide.slug} href={href(`guides/${guide.slug}/`)}>
                  {guide.label} setup
                </TextLink>
              ))}
          </div>
          <p className="mt-4 text-muted-foreground">
            Also supports Claude Desktop, Cursor, OpenCode, and WorkBuddy. MCP
            access is read-only; queries do not trigger capture or AI
            organization.
          </p>
        </HomeSection>

        <HomeSection id="privacy" title="Storage and privacy">
          <div className="space-y-4 text-muted-foreground">
            <p>
              Screenshots and notes are saved on your Mac. OCR runs on-device.
              AI organization may send captures to the Agent service you choose.
            </p>
            <p>
              You can exclude apps and change the capture scope in Settings.
              Quit MyClip to stop capture.
            </p>
            <p>
              Connected MCP clients receive retrieved notes and may receive
              short profile and current-focus summaries when they connect. Turn
              off MCP memory access in Settings to pause it.
            </p>
          </div>
        </HomeSection>

        <HomeSection id="download" title="Installation">
          <ol className="list-decimal space-y-3 pl-5 text-muted-foreground marker:text-foreground">
            <li>
              Download the Apple Silicon or Intel DMG from{" "}
              <a
                href={`${site.repository}/releases/latest`}
                className="rounded-sm text-foreground underline underline-offset-4"
              >
                GitHub Releases
              </a>{" "}
              and move MyClip to Applications.
            </li>
            <li>
              Open MyClip, choose an Agent, and grant Screen Recording and
              Accessibility permissions.
            </li>
            <li>
              Keep MyClip open to capture new work. Search organized notes in
              Memory and revisit screenshots in Timeline.
            </li>
          </ol>
          <p className="mt-5 text-muted-foreground">
            Community builds are self-signed and not notarized. If macOS blocks
            the first launch, see the{" "}
            <a
              href={`${site.repository}/blob/main/docs/release-signing.md#installing-a-community-build`}
              className="rounded-sm text-foreground underline underline-offset-4"
            >
              installation help
            </a>
            .
          </p>
        </HomeSection>
      </main>
    </Layout>
  );
}

export function GuidePage({ guide, html }: { guide: Guide; html: string }) {
  return (
    <Layout
      title={guide.pageTitle}
      description={guide.description}
      path={`guides/${guide.slug}/`}
    >
      <main id="content" className="mx-auto max-w-5xl px-5 py-12 sm:px-8">
        <div className="grid gap-10 lg:grid-cols-4 lg:gap-16">
          <aside className="hidden space-y-5 lg:block">
            <p className="flex items-center gap-2 text-sm font-medium">
              <BookOpen className="size-4" aria-hidden="true" />
              Guides
            </p>
            <nav aria-label="MyClip guides" className="space-y-5">
              {(["Using MyClip", "MCP setup"] as const).map((category) => (
                <div key={category}>
                  <p className="mb-2 text-xs text-muted-foreground">
                    {category}
                  </p>
                  <div className="flex flex-wrap gap-2 lg:flex-col">
                    {guides
                      .filter((item) => item.category === category)
                      .map((item) => (
                        <a
                          key={item.slug}
                          href={href(`guides/${item.slug}/`)}
                          aria-current={
                            item.slug === guide.slug ? "page" : undefined
                          }
                          className={cn(
                            "rounded-lg px-3 py-2 text-sm hover:bg-muted",
                            item.slug === guide.slug
                              ? "bg-muted font-medium text-foreground"
                              : "text-muted-foreground",
                          )}
                        >
                          {item.label}
                        </a>
                      ))}
                  </div>
                </div>
              ))}
            </nav>
            <p className="hidden text-xs leading-6 text-muted-foreground lg:block">
              {guide.category === "MCP setup" ? (
                <>
                  Local stdio server
                  <br />
                  Two read-only tools
                  <br />
                </>
              ) : (
                <>
                  Timeline search uses local OCR.
                  <br />
                </>
              )}
              macOS 13+
            </p>
          </aside>
          <article className="min-w-0 lg:col-span-3">
            <p className="text-sm text-muted-foreground">
              {guide.category} / {guide.label}
            </p>
            <h1 className="mt-3 text-3xl leading-tight font-semibold tracking-tight sm:text-4xl">
              {guide.title}
            </h1>
            <p className="mt-4 text-base leading-7 text-muted-foreground">
              {guide.description}
            </p>
            <div
              className="guide-content mt-10 border-t pt-5"
              dangerouslySetInnerHTML={{ __html: html }}
            />
            <div className="mt-10 border-t pt-6">
              <TextLink href={`${site.repository}/blob/main/${guide.source}`}>
                View this guide on GitHub
              </TextLink>
            </div>
          </article>
        </div>
      </main>
    </Layout>
  );
}

export function DemoPage() {
  return (
    <Layout
      title="MyClip Demo — 45-Second App Walkthrough"
      description="A 45-second walkthrough of MyClip: onboarding, screenshot history, Markdown notes, tasks, and memory retrieval in Codex and Claude."
      path="demo/"
    >
      <main
        id="content"
        className="mx-auto max-w-5xl px-5 py-10 sm:px-8 sm:py-12"
      >
        <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">
          MyClip demo
        </h1>
        <p className="mt-4 max-w-2xl text-base leading-7 text-muted-foreground">
          A 45-second walkthrough of the app, from setup to looking up a note
          with Codex or Claude.
        </p>
        <DemoVideo className="mt-6" descriptionId="demo-caption" />
        <p
          id="demo-caption"
          className="mt-3 text-xs leading-6 text-muted-foreground"
        >
          Silent video · HTML reconstruction · Sample data · Chinese interface.
          The Codex and Claude interactions are illustrations.
        </p>
        <section className="mt-8 border-t pt-6" aria-labelledby="tour-heading">
          <h2 id="tour-heading" className="text-base font-semibold">
            In the video
          </h2>
          <ol className="mt-4 list-decimal space-y-3 pl-5 text-sm leading-7 text-muted-foreground">
            <li>Choose an Agent and grant permissions during onboarding.</li>
            <li>
              Read Markdown notes in Memory and view source screenshots in
              Timeline.
            </li>
            <li>Review suggested tasks in Kanban and open work reports.</li>
            <li>
              See illustrated examples of retrieving a saved memory in Codex and
              Claude.
            </li>
          </ol>
        </section>
        <div className="mt-8 flex flex-wrap gap-x-6 gap-y-3 border-t pt-6">
          <TextLink href={`${site.repository}/releases/latest`}>
            Download MyClip
          </TextLink>
          {guides
            .filter((guide) => guide.category === "MCP setup")
            .map((guide) => (
              <TextLink key={guide.slug} href={href(`guides/${guide.slug}/`)}>
                {guide.label} setup
              </TextLink>
            ))}
        </div>
      </main>
    </Layout>
  );
}

export function NotFoundPage() {
  return (
    <Layout
      title="Page not found — MyClip"
      description="Return to MyClip’s product overview or setup guides."
      path="404.html"
      noIndex
    >
      <main id="content" className="mx-auto max-w-5xl px-5 py-16 sm:px-8">
        <p className="text-sm text-muted-foreground">404</p>
        <h1 className="mt-3 text-3xl font-semibold tracking-tight">
          Page not found.
        </h1>
        <p className="mt-4 text-muted-foreground">
          The page may have moved. Downloads and setup guides are on the home
          page.
        </p>
        <div className="mt-6">
          <TextLink href={href()}>MyClip home</TextLink>
        </div>
      </main>
    </Layout>
  );
}
