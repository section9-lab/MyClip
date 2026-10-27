import type { ReactNode } from "react";
import {
  ArrowRight,
  ArrowUpRight,
  BookOpen,
  Check,
  ChevronDown,
  Download,
  FileText,
  FolderSearch,
  Link2,
  Monitor,
  Play,
  ShieldCheck,
  Terminal,
} from "lucide-react";
import { guides, href, site, type Guide } from "./content";
import { Layout } from "./components/layout";
import { Badge } from "./components/ui/badge";
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
      className="inline-flex items-center gap-2 rounded-sm font-medium text-primary underline-offset-4 hover:underline"
    >
      {children}
      <ArrowRight className="size-4" aria-hidden="true" />
    </a>
  );
}

function SectionHeading({
  eyebrow,
  title,
  children,
}: {
  eyebrow: string;
  title: string;
  children?: ReactNode;
}) {
  return (
    <div className="max-w-2xl">
      <p className="mb-3 text-sm font-medium text-primary">{eyebrow}</p>
      <h2 className="text-3xl font-semibold tracking-tight sm:text-4xl">
        {title}
      </h2>
      {children && (
        <p className="mt-5 text-base leading-8 text-muted-foreground">
          {children}
        </p>
      )}
    </div>
  );
}

const features = [
  {
    icon: Monitor,
    title: "A history you can search",
    text: "Capture the focused window, or choose its display. Timeline keeps the screenshots with on-device OCR text, so you can revisit work you recorded.",
  },
  {
    icon: FileText,
    title: "Notes with their sources",
    text: "Your chosen Agent organizes captures into Markdown memories. Linked notes keep context connected and lead back to supporting screenshots.",
  },
  {
    icon: Check,
    title: "From context to next steps",
    text: "Review suggested tasks in Kanban, track progress, and read daily, weekly, or monthly reports built from your task history.",
  },
] as const;

const questions = [
  {
    q: "What does MyClip capture?",
    a: "By default, MyClip captures your focused application window in response to enabled activity triggers. You can choose the display containing that window instead. Capture scope, triggers, and excluded apps are configurable in Settings. The app captures while it is open; quitting stops capture.",
  },
  {
    q: "Can I search my screenshot history?",
    a: "Timeline stores captures with on-device OCR text. Memory provides searchable Markdown notes organized from those captures. MCP clients search the saved memories; MCP queries do not generate new notes or trigger screenshots.",
  },
  {
    q: "Does it remember every conversation with my AI?",
    a: "MyClip builds memories from captured work on your Mac. It does not automatically import every Codex or Claude conversation. What can be retrieved depends on the work you captured and the notes your selected Agent organized.",
  },
  {
    q: "Which AI tools can read my memories?",
    a: "MyClip includes client setup for Codex, Claude Code, Claude Desktop, Cursor, OpenCode, and WorkBuddy. Its local MCP server exposes memory_search and memory_get. Both tools are read-only, and each client may require its own approval.",
  },
  {
    q: "Does local-first mean all AI runs offline?",
    a: "Screenshots and notes are stored on your Mac, and OCR runs on-device. AI organization may use your chosen Agent's cloud service. Memory retrieved by an MCP client becomes available to that client under its own data settings.",
  },
  {
    q: "What do I need to install it?",
    a: "MyClip requires macOS 13 or later, Node.js 22 or later, and an account for the Agent you select. Releases include Apple Silicon and Intel DMGs. Community builds are self-signed and not notarized; installation help is linked below.",
  },
] as const;

export function HomePage() {
  return (
    <Layout
      title="MyClip — AI Screen Memory & Searchable History for Mac"
      description={site.description}
    >
      <main id="content">
        <section className="mx-auto max-w-6xl px-5 pt-16 pb-12 sm:px-8 sm:pt-24">
          <div className="grid items-end gap-10 lg:grid-cols-3 lg:gap-16">
            <div className="lg:col-span-2">
              <Badge variant="secondary" className="mb-6 h-6 gap-2 px-3">
                <Monitor aria-hidden="true" /> Local-first · Open source
              </Badge>
              <h1 className="text-5xl leading-tight font-semibold tracking-tight sm:text-6xl">
                AI screen memory
                <br />
                for your Mac.
              </h1>
              <p className="mt-6 max-w-xl text-lg leading-8 text-muted-foreground">
                Turn the work on your screen into searchable memories and tasks.
                Find your way back to a decision, then give Codex or Claude the
                context to continue.
              </p>
              <div className="mt-8 flex flex-wrap gap-3">
                <Button asChild size="lg" className="h-11 gap-2 px-5">
                  <a href={`${site.repository}/releases/latest`}>
                    <Download aria-hidden="true" />
                    Download for Mac
                  </a>
                </Button>
                <Button
                  asChild
                  variant="outline"
                  size="lg"
                  className="h-11 gap-2 px-5"
                >
                  <a href={href("demo/")}>
                    <Play aria-hidden="true" />
                    Watch the 45-second demo
                  </a>
                </Button>
              </div>
              <p className="mt-4 text-xs leading-6 text-muted-foreground">
                macOS 13+ · Apple Silicon & Intel · Node.js 22+ and an Agent
                account
              </p>
            </div>
            <div className="space-y-6 border-l pl-6 lg:mb-2">
              <div>
                <FolderSearch
                  className="mb-2 size-5 text-primary"
                  aria-hidden="true"
                />
                <p className="font-medium">Find what you were working on</p>
                <p className="mt-1 text-sm leading-6 text-muted-foreground">
                  Search saved notes and revisit their source captures.
                </p>
              </div>
              <div>
                <Link2
                  className="mb-2 size-5 text-primary"
                  aria-hidden="true"
                />
                <p className="font-medium">Bring context to your Agent</p>
                <p className="mt-1 text-sm leading-6 text-muted-foreground">
                  Read-only MCP access for Codex, Claude, and other clients.
                </p>
              </div>
            </div>
          </div>
          <figure className="mt-12 sm:mt-16">
            <a
              href={href("demo/")}
              aria-label="Watch the MyClip desktop demonstration"
              className="block overflow-hidden rounded-xl border"
            >
              <img
                className="h-auto w-full"
                src={href("images/myclip-demo-poster.jpg")}
                alt="MyClip's Memory workspace with linked Markdown notes and source captures, shown in a desktop demonstration with sample data"
                width="1600"
                height="1000"
                fetchPriority="high"
              />
            </a>
            <figcaption className="mt-3 flex flex-wrap justify-between gap-2 text-xs leading-6 text-muted-foreground">
              <span>
                Desktop demonstration · Sample data · Chinese interface
              </span>
              <a
                className="inline-flex items-center gap-1 hover:text-foreground"
                href={href("demo/")}
              >
                Watch the complete tour{" "}
                <ArrowUpRight className="size-3" aria-hidden="true" />
              </a>
            </figcaption>
          </figure>
        </section>

        <section id="how-it-works" className="border-y bg-muted/40">
          <div className="mx-auto max-w-6xl px-5 py-16 sm:px-8 sm:py-20">
            <SectionHeading
              eyebrow="Capture → Organize → Recall"
              title="Keep the thread of your work."
            >
              A screenshot holds a moment. MyClip connects captured moments to
              notes you can search, follow, and use again.
            </SectionHeading>
            <div className="mt-10 grid gap-8 md:grid-cols-3 md:gap-10">
              {features.map(({ icon: Icon, title, text }) => (
                <div key={title}>
                  <Icon
                    className="mb-4 size-6 text-primary"
                    aria-hidden="true"
                  />
                  <h3 className="text-lg font-semibold tracking-tight">
                    {title}
                  </h3>
                  <p className="mt-3 text-sm leading-7 text-muted-foreground">
                    {text}
                  </p>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section className="mx-auto grid max-w-6xl gap-12 px-5 py-16 sm:px-8 sm:py-20 lg:grid-cols-2 lg:gap-20">
          <div>
            <SectionHeading
              eyebrow="Work context, available through MCP"
              title="Let your Agent pick up the thread."
            >
              MyClip's built-in Model Context Protocol server lets your AI tools
              search and read saved work memories. Ask a specific question and
              follow the evidence back to its source.
            </SectionHeading>
            <p className="mt-5 text-sm leading-7 text-muted-foreground">
              Also includes setup for Claude Desktop, Cursor, OpenCode, and
              WorkBuddy. Capture and AI organization happen separately from
              read-only retrieval.
            </p>
            <TextLink href={`${site.repository}/tree/main/docs/integrations`}>
              Read the integration docs
            </TextLink>
          </div>
          <div className="space-y-4">
            {guides.map((guide) => (
              <a
                key={guide.slug}
                href={href(`guides/${guide.slug}/`)}
                className="group flex gap-4 rounded-xl border p-6 hover:bg-muted/50"
              >
                <Terminal
                  className="mt-1 size-5 shrink-0 text-primary"
                  aria-hidden="true"
                />
                <div className="flex-1">
                  <h3 className="flex items-center justify-between gap-3 font-semibold">
                    Connect {guide.client}
                    <ArrowUpRight
                      className="size-4 text-muted-foreground group-hover:text-foreground"
                      aria-hidden="true"
                    />
                  </h3>
                  <p className="mt-2 text-sm leading-6 text-muted-foreground">
                    Setup, example questions, and troubleshooting for your Mac
                    work memories.
                  </p>
                </div>
              </a>
            ))}
            <div className="rounded-xl bg-muted/60 p-6">
              <p className="text-xs font-medium text-muted-foreground">
                Example question · Results depend on your saved work
              </p>
              <p className="mt-3 text-base leading-7">
                “Use MyClip to find the project decision I reviewed yesterday.
                Include the source captures and their dates.”
              </p>
            </div>
          </div>
        </section>

        <section id="privacy" className="border-y bg-muted/40">
          <div className="mx-auto grid max-w-6xl gap-8 px-5 py-16 sm:px-8 lg:grid-cols-2 lg:gap-20">
            <div>
              <ShieldCheck
                className="mb-4 size-6 text-primary"
                aria-hidden="true"
              />
              <h2 className="text-3xl font-semibold tracking-tight">
                Your library stays on your Mac.
              </h2>
              <p className="mt-5 leading-8 text-muted-foreground">
                Screenshots and Markdown notes are saved locally. OCR runs
                on-device. You choose the capture scope, exclude apps, and can
                quit MyClip to stop capture.
              </p>
            </div>
            <div className="space-y-5 text-sm leading-7 text-muted-foreground">
              <p>
                <strong className="font-medium text-foreground">
                  AI organization:
                </strong>{" "}
                your selected Agent may process captures through its cloud
                service. Local storage does not mean every AI operation runs
                offline.
              </p>
              <p>
                <strong className="font-medium text-foreground">
                  MCP access:
                </strong>{" "}
                retrieved memories are shared with the connected client. Short
                summaries of updated profile and current-focus notes may be
                shared when it connects. Turn off the MCP service in Settings to
                pause access.
              </p>
              <p>
                <strong className="font-medium text-foreground">
                  Read-only tools:
                </strong>{" "}
                memory queries do not edit notes, take screenshots, or start AI
                organization.
              </p>
            </div>
          </div>
        </section>

        <section
          id="questions"
          className="mx-auto grid max-w-6xl gap-8 px-5 py-16 sm:px-8 sm:py-20 lg:grid-cols-3 lg:gap-16"
        >
          <div>
            <SectionHeading
              eyebrow="A few useful details"
              title="Before you begin."
            />
          </div>
          <div className="divide-y border-y lg:col-span-2">
            {questions.map(({ q, a }) => (
              <details key={q} className="group py-5">
                <summary className="flex cursor-pointer list-none items-center justify-between gap-5 rounded-sm font-medium [&::-webkit-details-marker]:hidden">
                  {q}
                  <ChevronDown
                    className="size-4 shrink-0 text-muted-foreground group-open:rotate-180"
                    aria-hidden="true"
                  />
                </summary>
                <p className="mt-4 pr-8 text-sm leading-7 text-muted-foreground">
                  {a}
                </p>
              </details>
            ))}
          </div>
        </section>

        <section
          id="download"
          className="mx-auto max-w-6xl px-5 pb-16 sm:px-8 sm:pb-20"
        >
          <div className="flex flex-col justify-between gap-8 rounded-xl border bg-muted/30 p-8 sm:p-10 lg:flex-row lg:items-center">
            <div>
              <h2 className="text-2xl font-semibold tracking-tight sm:text-3xl">
                Make your next return easier.
              </h2>
              <p className="mt-3 max-w-xl text-sm leading-7 text-muted-foreground">
                Download a DMG, choose your Agent, and grant Screen Recording
                and Accessibility permissions. Community builds are self-signed
                and not notarized.
              </p>
              <a
                className="mt-3 inline-block rounded-sm text-sm text-primary underline underline-offset-4"
                href={`${site.repository}/blob/main/docs/release-signing.md#installing-a-community-build`}
              >
                First-launch installation help
              </a>
            </div>
            <Button asChild size="lg" className="h-11 shrink-0 gap-2 px-5">
              <a href={`${site.repository}/releases/latest`}>
                <Download aria-hidden="true" />
                Get MyClip for Mac
              </a>
            </Button>
          </div>
        </section>
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
      <main
        id="content"
        className="mx-auto max-w-6xl px-5 py-12 sm:px-8 sm:py-16"
      >
        <div className="grid gap-10 lg:grid-cols-4 lg:gap-16">
          <aside className="space-y-5">
            <p className="flex items-center gap-2 text-sm font-medium">
              <BookOpen className="size-4" aria-hidden="true" />
              MCP setup guides
            </p>
            <nav
              aria-label="Integration guides"
              className="flex flex-wrap gap-2 lg:flex-col"
            >
              {guides.map((item) => (
                <a
                  key={item.slug}
                  href={href(`guides/${item.slug}/`)}
                  aria-current={item.slug === guide.slug ? "page" : undefined}
                  className={cn(
                    "rounded-lg px-3 py-2 text-sm hover:bg-muted",
                    item.slug === guide.slug
                      ? "bg-muted font-medium text-foreground"
                      : "text-muted-foreground",
                  )}
                >
                  {item.client}
                </a>
              ))}
            </nav>
            <p className="hidden text-xs leading-6 text-muted-foreground lg:block">
              Local stdio server
              <br />
              Two read-only tools
              <br />
              macOS 13+
            </p>
          </aside>
          <article className="min-w-0 lg:col-span-3">
            <Badge variant="secondary">{guide.client} + MyClip MCP</Badge>
            <h1 className="mt-5 text-4xl leading-tight font-semibold tracking-tight sm:text-5xl">
              {guide.title}
            </h1>
            <p className="mt-5 text-lg leading-8 text-muted-foreground">
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
      title="MyClip Demo — AI Screen Memory for Mac"
      description="Watch MyClip capture work, organize linked Markdown memories, track tasks, and illustrate memory recall in Codex and Claude. A 45-second tour with sample data."
      path="demo/"
    >
      <main
        id="content"
        className="mx-auto max-w-6xl px-5 py-12 sm:px-8 sm:py-16"
      >
        <Badge variant="secondary">45-second desktop tour</Badge>
        <h1 className="mt-5 text-4xl font-semibold tracking-tight sm:text-5xl">
          See MyClip remember the work.
        </h1>
        <p className="mt-5 max-w-2xl text-lg leading-8 text-muted-foreground">
          From a captured window to a linked memory, a task, and context your
          Agent can retrieve.
        </p>
        <video
          className="mt-8 h-auto w-full rounded-xl border bg-muted"
          width="1600"
          height="1000"
          controls
          playsInline
          preload="metadata"
          poster={href("images/myclip-demo-poster.jpg")}
          aria-label="MyClip desktop demonstration, using fictional sample data and illustrated Agent interactions"
        >
          <source src={href("images/myclip-demo.mp4")} type="video/mp4" />
          <a href={href("images/myclip-demo.mp4")}>Download the demo video</a>
        </video>
        <p className="mt-3 text-xs leading-6 text-muted-foreground">
          HTML reconstruction · Fictional sample data · Chinese interface ·
          Codex and Claude recall interactions are illustrations. The video is
          silent; the written tour follows.
        </p>
        <section
          className="mt-12 grid gap-8 sm:grid-cols-2 lg:grid-cols-4"
          aria-label="Written tour"
        >
          {[
            {
              title: "Set up your Mac",
              text: "Choose an Agent and grant capture permissions during onboarding.",
            },
            {
              title: "Explore your library",
              text: "Read linked Markdown in Memory and revisit source screenshots in Timeline.",
            },
            {
              title: "Review next steps",
              text: "See suggested tasks, the Kanban board, and work reports.",
            },
            {
              title: "Recall with your Agent",
              text: "The final scenes illustrate retrieving saved work context from Codex and Claude through MyClip MCP.",
            },
          ].map(({ title, text }) => (
            <div key={title}>
              <h2 className="font-semibold">{title}</h2>
              <p className="mt-3 text-sm leading-7 text-muted-foreground">
                {text}
              </p>
            </div>
          ))}
        </section>
        <div className="mt-12 flex flex-wrap gap-3">
          <Button asChild size="lg">
            <a href={`${site.repository}/releases/latest`}>
              <Download aria-hidden="true" />
              Download for Mac
            </a>
          </Button>
          <Button asChild variant="outline" size="lg">
            <a href={href("guides/codex/")}>
              Set up MCP
              <ArrowRight aria-hidden="true" />
            </a>
          </Button>
        </div>
      </main>
    </Layout>
  );
}

export function NotFoundPage() {
  return (
    <Layout
      title="Page not found — MyClip"
      description="Return to MyClip's product overview or MCP setup guides."
      path="404.html"
      noIndex
    >
      <main id="content" className="mx-auto max-w-6xl px-5 py-24 sm:px-8">
        <p className="text-sm font-medium text-muted-foreground">
          404 · Page not found
        </p>
        <h1 className="mt-4 text-4xl font-semibold tracking-tight">
          Let's get you back to your work.
        </h1>
        <p className="mt-5 text-muted-foreground">
          Find MyClip's overview, downloads, and setup guides on the home page.
        </p>
        <Button asChild className="mt-8">
          <a href={href()}>
            Go to MyClip
            <ArrowRight aria-hidden="true" />
          </a>
        </Button>
      </main>
    </Layout>
  );
}
