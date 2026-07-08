import { type ReactNode, useEffect } from "react";
import EdithDemo from "./EdithDemo";

const PRICE_USD = 50;
const DOWNLOAD_HREF = "#download";

function useReveal() {
  useEffect(() => {
    const els = document.querySelectorAll<HTMLElement>(".reveal");
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.isIntersecting) {
            e.target.classList.add("in");
            io.unobserve(e.target);
          }
        }
      },
      { threshold: 0.12, rootMargin: "0px 0px -8% 0px" },
    );
    els.forEach((el) => io.observe(el));
    return () => io.disconnect();
  }, []);
}

export default function Landing() {
  useReveal();
  return (
    <div className="min-h-screen bg-background text-foreground">
      <Nav />
      <Hero />
      <Pitch />
      <ReplacesTable />
      <Feature
        eyebrow="Rate limits"
        title="Live rings for session and week."
        body="Second-by-second countdowns to your next 5-hour session reset and to the weekly rollover. A 24-hour spark shows the shape of your day at a glance."
        media={
          <Shot
            src="/media/rate-limit-rings.png"
            alt="Session and weekly rate-limit rings with reset countdowns"
            width={640}
            height={530}
          />
        }
      />
      <Feature
        eyebrow="Menu bar"
        reverse
        title="Two numbers in your menu bar."
        body="Session and weekly percentages, tinted by a time-aware risk model. Green when you have room. Amber when you're close. Red when the next prompt could push you over."
        media={<MenubarMock />}
      />
      <Feature
        eyebrow="Notifications"
        title="Alerts that stay out of your way."
        body="Threshold, ahead-of-pace, burn, back-to-green, and pre-reset. All optional. A single button sends a test notification and reports back exactly why it did or didn't fire."
        media={<NotificationsMock />}
      />
      <Feature
        eyebrow="Dashboard"
        reverse
        title="A native window for the whole picture."
        body="KPIs, per-day and per-model charts, hourly distribution, sources, projects, and a sortable model table. Refreshed by a collector that runs quietly in the background."
        media={
          <Shot
            src="/media/dashboard.png"
            alt="Edith dashboard showing cost, tokens, cache hit rate, activity heatmap and rate-limit chart"
            width={2921}
            height={1620}
          />
        }
      />
      <Feature
        eyebrow="Heatmap"
        title="A year of usage at a glance."
        body="A GitHub-style calendar of daily spend across your full history. Hover any square for the exact number."
        media={
          <Shot
            src="/media/activity-heatmap.png"
            alt="Activity heatmap of daily spend across weeks"
            width={1055}
            height={406}
          />
        }
      />
      <Feature
        eyebrow="Privacy"
        reverse
        title="Presenter mode for the room."
        body="One toggle blurs spend figures and track names so you can screen-share without exposing your bill. Usage stays local, with optional iCloud backup that merges across your machines."
        media={
          <Shot
            src="/media/privacy-presenter.png"
            alt="Usage KPIs in presenter mode with sensitive numbers blurred"
            width={2921}
            height={430}
          />
        }
      />
      <Feature
        eyebrow="Music"
        title="Your local music folder, done right."
        body="Cover thumbnails, drag-to-seek, crossfades, auto-advance, and media keys. No cloud, no accounts, no ads."
        media={
          <Shot
            src="/media/music-player.png"
            alt="Edith music player with track list and now-playing transport controls"
            width={2921}
            height={2078}
          />
        }
      />
      <Feature
        eyebrow="System"
        reverse
        title="Prevent sleep. Lock the keyboard."
        body="Keep your Mac awake for a long build. Lock the keyboard to wipe it down without triggering shortcuts. Auto-restores in sixty seconds so you can't lock yourself out."
        media={
          <Shot
            src="/media/system-tools.png"
            alt="Quick actions: clean keys, keep awake and presenter mode"
            width={1445}
            height={464}
          />
        }
      />
      <ExtraFeatures />
      <Performance />
      <Local />
      <Pricing />
      <Download />
      <Footer />
    </div>
  );
}

function Nav() {
  return (
    <header className="sticky top-0 z-40 border-b border-border/70 bg-background/70 backdrop-blur-xl">
      <div className="container-page flex h-14 items-center justify-between">
        <a href="#top" className="flex items-center gap-2">
          <IconMark />
          <span className="text-[15px] font-semibold tracking-tight">Edith</span>
        </a>
        <nav className="hidden items-center gap-8 md:flex">
          {[
            ["Features", "#features"],
            ["Performance", "#performance"],
            ["Pricing", "#pricing"],
          ].map(([l, h]) => (
            <a
              key={h}
              href={h}
              className="text-[13px] text-muted-foreground transition-colors hover:text-foreground"
            >
              {l}
            </a>
          ))}
        </nav>
        <a
          href={DOWNLOAD_HREF}
          className="rounded-full bg-foreground px-4 py-1.5 text-[13px] font-medium text-background transition-opacity hover:opacity-90"
        >
          Download
        </a>
      </div>
    </header>
  );
}

function IconMark({ size = 28 }: { size?: number }) {
  return (
    <img
      src="/media/app-icon-512.png"
      alt="Edith app icon"
      width={size}
      height={size}
      className="rounded-[22%] shadow-[0_0_0_1px_rgba(255,255,255,0.06)]"
      style={{ width: size, height: size }}
      decoding="async"
    />
  );
}

function Hero() {
  return (
    <section id="top" className="relative overflow-hidden">
      <div className="hero-glow pointer-events-none absolute inset-0" aria-hidden />
      <div className="container-page relative pt-24 pb-20 md:pt-36 md:pb-32">
        <div className="reveal mb-8">
          <img
            src="/media/app-icon.png"
            alt="Edith app icon"
            width={88}
            height={88}
            className="h-[72px] w-[72px] rounded-[22%] shadow-[0_20px_60px_-20px_rgba(0,0,0,0.7)] md:h-[88px] md:w-[88px]"
            decoding="async"
          />
        </div>
        <p className="reveal mb-6 text-[12px] font-medium uppercase tracking-[0.18em] text-accent">
          For macOS
        </p>
        <h1 className="reveal text-balance text-4xl font-semibold leading-[1.05] tracking-[-0.03em] md:text-6xl lg:text-7xl">
          One menu bar app
          <br />
          instead of five subscriptions.
        </h1>
        <p className="reveal mt-6 max-w-2xl text-balance text-lg text-muted-foreground md:text-xl">
          Edith is a native Mac app for AI rate-limit tracking, usage analytics, local music, and
          system tools. Pay once. Own it forever.
        </p>
        <div className="reveal mt-10 flex flex-wrap items-center gap-3">
          <a
            href={DOWNLOAD_HREF}
            className="inline-flex items-center gap-2 rounded-full bg-foreground px-6 py-3 text-[14px] font-medium text-background transition-transform hover:scale-[1.02]"
          >
            <AppleGlyph />
            Download for macOS
          </a>
          <a
            href="#pricing"
            className="inline-flex items-center gap-1 rounded-full border border-border-strong px-6 py-3 text-[14px] font-medium text-foreground transition-colors hover:bg-surface"
          >
            ${PRICE_USD}, one time
          </a>
        </div>
        <p className="reveal mt-4 text-[12px] text-subtle">Requires macOS. Apple Silicon and Intel.</p>

        <div className="reveal mt-16 md:mt-24">
          <p className="mb-3 text-center text-[12px] text-subtle">
            Live demo. Try the presenter toggle.
          </p>
          <EdithDemo />
        </div>
      </div>
    </section>
  );
}

function AppleGlyph() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <path d="M16.365 1.43c0 1.14-.42 2.23-1.24 3.05-.83.83-2.19 1.45-3.31 1.36-.14-1.1.43-2.24 1.2-2.98.85-.83 2.32-1.42 3.35-1.43zM20.5 17.29c-.57 1.31-.85 1.9-1.59 3.06-1.03 1.61-2.48 3.62-4.28 3.63-1.6.01-2.01-1.05-4.18-1.04-2.17.01-2.62 1.06-4.22 1.05-1.8-.02-3.18-1.83-4.21-3.44C-.36 16.72-1.02 10.6 2.87 8.4c1.4-.8 2.86-1.24 4.24-1.26 1.61-.03 3.13 1.09 4.19 1.09 1.05 0 2.87-1.35 4.85-1.15.83.03 3.16.33 4.66 2.52-.12.08-2.78 1.62-2.75 4.82.03 3.83 3.36 5.1 3.4 5.11-.03.09-.53 1.82-1.96 3.76z" />
    </svg>
  );
}

function Pitch() {
  return (
    <section className="container-page py-24 md:py-32">
      <div className="grid gap-10 md:grid-cols-12">
        <div className="md:col-span-5">
          <p className="reveal text-[12px] font-medium uppercase tracking-[0.18em] text-accent">
            The pitch
          </p>
        </div>
        <div className="md:col-span-7">
          <h2 className="reveal text-balance text-3xl font-semibold leading-[1.1] tracking-[-0.02em] md:text-5xl">
            Stop renting five menu bar utilities. Buy one. Own it forever.
          </h2>
          <p className="reveal mt-6 max-w-xl text-lg text-muted-foreground">
            Every feature in Edith is normally its own app with its own subscription. We built the
            whole shelf into a single native binary that idles at twenty-two megabytes.
          </p>
        </div>
      </div>
    </section>
  );
}

function ReplacesTable() {
  const rows: [string, string, string][] = [
    ["A Claude usage and rate-limit tracker", "Live session and weekly rings with countdowns", "$8/mo"],
    ["A menu bar stats readout", "Session and weekly %, tinted by a risk model", "$5/mo"],
    ["A usage-alerts service", "Threshold, ahead-of-pace, burn, back-to-green, pre-reset", "$6/mo"],
    ["An analytics dashboard", "KPIs, per-day and per-model charts, sortable table", "$12/mo"],
    ["A GitHub-style heatmap tool", "Daily spend calendar across your full history", "$4/mo"],
    ["A local music player", "Thumbnails, drag-to-seek, fades, auto-advance, media keys", "$5/mo"],
    ["Focus and system utilities", "Prevent-sleep toggle, 60-second keyboard-clean lock", "$6/mo"],
  ];
  return (
    <section id="features" className="container-page pb-24 md:pb-32">
      <div className="reveal overflow-hidden rounded-2xl border border-border bg-surface">
        <div className="grid grid-cols-[1.4fr_1.4fr_auto] gap-6 border-b border-border bg-surface-elevated px-6 py-4 text-[12px] font-medium uppercase tracking-[0.14em] text-muted-foreground md:px-8">
          <span>Instead of paying monthly for</span>
          <span>Edith includes it</span>
          <span className="text-right">Their price</span>
        </div>
        {rows.map(([a, b, price], i) => (
          <div
            key={a}
            className={`grid grid-cols-[1.4fr_1.4fr_auto] items-start gap-6 px-6 py-5 md:px-8 md:py-6 ${
              i !== rows.length - 1 ? "border-b border-border" : ""
            }`}
          >
            <span className="text-[15px] text-muted-foreground line-through decoration-subtle/60">
              {a}
            </span>
            <span className="text-[15px] font-medium text-foreground">{b}</span>
            <span className="text-right font-mono text-[14px] text-subtle line-through tabular-nums">
              {price}
            </span>
          </div>
        ))}
      </div>

      <div className="reveal mt-10 flex flex-col items-center gap-3 text-center">
        <p className="font-mono text-[15px] text-subtle line-through tabular-nums">
          $46/mo · roughly $552 a year across seven separate apps
        </p>
        <p className="text-balance text-2xl font-semibold tracking-[-0.02em] md:text-4xl">
          <span className="text-accent">${PRICE_USD} once.</span> Everything above, forever.
        </p>
        <p className="text-[14px] text-muted-foreground">
          A one-time fee. No subscription, no account, no nonsense.
        </p>
      </div>
    </section>
  );
}

function Feature({
  eyebrow,
  title,
  body,
  media,
  reverse,
}: {
  eyebrow: string;
  title: string;
  body: string;
  media: ReactNode;
  reverse?: boolean;
}) {
  return (
    <section className="border-t border-border/60">
      <div className="container-page grid items-center gap-12 py-24 md:grid-cols-2 md:gap-16 md:py-32">
        <div className={`reveal ${reverse ? "md:order-2" : ""}`}>
          <p className="text-[12px] font-medium uppercase tracking-[0.18em] text-accent">{eyebrow}</p>
          <h3 className="mt-4 text-balance text-3xl font-semibold leading-[1.1] tracking-[-0.02em] md:text-4xl">
            {title}
          </h3>
          <p className="mt-5 max-w-md text-[17px] leading-relaxed text-muted-foreground">{body}</p>
        </div>
        <div className={`reveal ${reverse ? "md:order-1" : ""}`}>{media}</div>
      </div>
    </section>
  );
}

function Shot({
  src,
  alt,
  width,
  height,
}: {
  src: string;
  alt: string;
  width: number;
  height: number;
}) {
  return (
    <img
      src={src}
      alt={alt}
      width={width}
      height={height}
      loading="lazy"
      decoding="async"
      className="w-full rounded-2xl border border-border-strong shadow-[0_30px_80px_-30px_rgba(0,0,0,0.7)]"
      style={{ aspectRatio: `${width} / ${height}`, background: "#141110" }}
    />
  );
}

function MenubarMock() {
  return (
    <div className="rounded-2xl border border-border-strong bg-surface p-6 shadow-[0_30px_80px_-30px_rgba(0,0,0,0.7)]">
      <div className="flex h-9 items-center justify-end gap-4 rounded-lg border border-border/60 bg-background/60 px-4 font-mono text-[12px] text-muted-foreground">
        <span className="tabular-nums">
          <span style={{ color: "var(--sage)" }}>38%</span>
          <span className="text-subtle"> · </span>
          <span className="text-accent">62%</span>
        </span>
        <span className="text-subtle">Wed 14:22</span>
      </div>
      <div className="mt-6 grid grid-cols-3 gap-3 text-[11px] text-muted-foreground">
        {[
          ["Safe", "var(--sage)"],
          ["Close", "var(--accent)"],
          ["Over", "var(--danger)"],
        ].map(([l, c]) => (
          <div
            key={l}
            className="flex items-center gap-2 rounded-md border border-border/60 bg-background/40 px-3 py-2"
          >
            <span className="h-2 w-2 rounded-full" style={{ background: c }} />
            {l}
          </div>
        ))}
      </div>
    </div>
  );
}

function NotificationsMock() {
  const items: [string, string, string][] = [
    ["Ahead of pace", "You're using this session faster than usual. 72% with 2h 47m left.", "var(--accent)"],
    ["Approaching weekly limit", "Week usage at 85%. Resets Sunday 4:00 PM.", "var(--danger)"],
    ["Back in the green", "Session dropped below 60%. Room to keep going.", "var(--sage)"],
  ];
  return (
    <div className="flex flex-col gap-3">
      {items.map(([title, body, dot]) => (
        <div
          key={title}
          className="flex items-start gap-3 rounded-2xl border border-border-strong bg-surface/90 p-4 shadow-[0_20px_50px_-24px_rgba(0,0,0,0.7)] backdrop-blur"
        >
          <span className="mt-0.5 flex h-9 w-9 flex-none items-center justify-center rounded-[10px] bg-gradient-to-b from-accent to-[#b3543a]">
            <span className="h-3.5 w-3.5 rounded bg-white/90" />
          </span>
          <div className="flex-1">
            <div className="flex items-baseline justify-between">
              <span className="text-[14px] font-semibold">{title}</span>
              <span className="font-mono text-[11px] text-subtle">Edith · now</span>
            </div>
            <p className="mt-0.5 text-[13px] leading-snug text-muted-foreground">{body}</p>
          </div>
          <span
            className="mt-1.5 h-2 w-2 flex-none rounded-full"
            style={{ background: dot, boxShadow: `0 0 10px ${dot}` }}
          />
        </div>
      ))}
    </div>
  );
}

function ExtraFeatures() {
  const items = [
    {
      title: "Global shortcut",
      body: "Toggle the panel from anywhere. Defaults to ⌥⌘E. Re-record it to whatever fits your muscle memory.",
    },
    {
      title: "Presenter mode",
      body: "One toggle blurs track names and spend figures. Safe to screen-share without exposing your bill.",
    },
    {
      title: "Local first",
      body: "Usage data never leaves your Mac. Optional iCloud backup merges cleanly across machines.",
    },
  ];
  return (
    <section className="border-t border-border/60">
      <div className="container-page py-24 md:py-32">
        <div className="grid gap-8 md:grid-cols-3">
          {items.map((it) => (
            <div key={it.title} className="reveal rounded-2xl border border-border bg-surface p-8">
              <h4 className="text-xl font-semibold tracking-tight">{it.title}</h4>
              <p className="mt-3 text-[15px] leading-relaxed text-muted-foreground">{it.body}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function Performance() {
  const rows: [string, string, string][] = [
    ["Idle, panel closed", "~0%", "~22 MB"],
    ["Music playing, panel closed", "~1%", "~40 MB"],
    ["Paused", "<1%", "~40 MB"],
  ];
  return (
    <section id="performance" className="border-t border-border/60">
      <div className="container-page py-24 md:py-32">
        <div className="grid gap-12 md:grid-cols-12">
          <div className="md:col-span-5">
            <p className="reveal text-[12px] font-medium uppercase tracking-[0.18em] text-accent">
              24/7, quietly
            </p>
            <h2 className="reveal mt-4 text-balance text-3xl font-semibold leading-[1.1] tracking-[-0.02em] md:text-5xl">
              Built to sit in your menu bar forever.
            </h2>
            <p className="reveal mt-6 max-w-md text-[17px] leading-relaxed text-muted-foreground">
              Native SwiftUI, not Electron. Work stops when it isn't seen. Disabling a tab tears down
              its timers and background jobs. Per-frame UI only redraws while the panel is open.
            </p>
            <p className="reveal mt-4 text-[13px] text-subtle">
              Measured on Apple M4 Pro. CPU as a share of one core, memory as physical footprint.
            </p>
          </div>
          <div className="md:col-span-7">
            <div className="reveal overflow-hidden rounded-2xl border border-border bg-surface">
              <div className="grid grid-cols-[1.4fr_1fr_1fr] border-b border-border bg-surface-elevated px-6 py-4 text-[12px] font-medium uppercase tracking-[0.14em] text-muted-foreground">
                <span>State</span>
                <span className="text-right">CPU</span>
                <span className="text-right">Memory</span>
              </div>
              {rows.map(([s, c, m], i) => (
                <div
                  key={s}
                  className={`grid grid-cols-[1.4fr_1fr_1fr] items-center px-6 py-6 font-mono text-[15px] tabular-nums ${
                    i !== rows.length - 1 ? "border-b border-border" : ""
                  }`}
                >
                  <span className="font-sans text-[15px] text-foreground">{s}</span>
                  <span className="text-right text-muted-foreground">{c}</span>
                  <span className="text-right text-muted-foreground">{m}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function Local() {
  return (
    <section className="border-t border-border/60">
      <div className="container-page py-24 text-center md:py-32">
        <p className="reveal text-[12px] font-medium uppercase tracking-[0.18em] text-accent">
          Local first
        </p>
        <h2 className="reveal mx-auto mt-4 max-w-3xl text-balance text-3xl font-semibold leading-[1.1] tracking-[-0.02em] md:text-5xl">
          Your usage never leaves your Mac.
        </h2>
        <p className="reveal mx-auto mt-6 max-w-xl text-[17px] leading-relaxed text-muted-foreground">
          No account. No telemetry. Optional iCloud backup merges cleanly across machines so your
          history follows you between a MacBook and a Mac mini.
        </p>
      </div>
    </section>
  );
}

function Pricing() {
  return (
    <section id="pricing" className="border-t border-border/60">
      <div className="container-page py-24 md:py-32">
        <div className="mx-auto max-w-xl text-center">
          <p className="reveal text-[12px] font-medium uppercase tracking-[0.18em] text-accent">
            Pricing
          </p>
          <h2 className="reveal mt-4 text-balance text-3xl font-semibold leading-[1.1] tracking-[-0.02em] md:text-5xl">
            One payment. Yours forever.
          </h2>
        </div>

        <div className="reveal mx-auto mt-14 max-w-md rounded-3xl border border-border-strong bg-surface p-8 shadow-[0_30px_80px_-30px_rgba(0,0,0,0.7)]">
          <div className="flex items-baseline gap-1">
            <span className="text-6xl font-semibold tracking-[-0.03em] tabular-nums">
              ${PRICE_USD}
            </span>
            <span className="text-lg text-muted-foreground">USD</span>
          </div>
          <p className="mt-2 text-[15px] text-muted-foreground">
            One time. Lifetime license. Free updates.
          </p>

          <ul className="mt-8 space-y-3 text-[15px] text-foreground">
            {[
              "Rate-limit rings and menu bar readout",
              "Full analytics dashboard and heatmap",
              "Smart notifications",
              "Local music player",
              "Prevent-sleep and keyboard lock",
              "No subscription. No account. Ever.",
            ].map((f) => (
              <li key={f} className="flex items-start gap-3">
                <Check />
                <span>{f}</span>
              </li>
            ))}
          </ul>

          <a
            href={DOWNLOAD_HREF}
            className="mt-10 flex w-full items-center justify-center gap-2 rounded-full bg-foreground px-6 py-3.5 text-[14px] font-medium text-background transition-transform hover:scale-[1.01]"
          >
            <AppleGlyph />
            Download for macOS
          </a>
          <p className="mt-3 text-center text-[12px] text-subtle">
            Requires macOS. Apple Silicon and Intel.
          </p>
        </div>

        <p className="reveal mx-auto mt-10 max-w-md text-center text-[13px] text-subtle">
          Compare to roughly $46 a month across seven separate menu bar utilities. Edith pays for
          itself in about seven weeks.
        </p>
      </div>
    </section>
  );
}

function Check() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" className="mt-1 shrink-0" aria-hidden>
      <path
        d="M5 12.5l4.5 4.5L19 7"
        stroke="var(--accent)"
        strokeWidth="2.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function Download() {
  return (
    <section id="download" className="border-t border-border/60">
      <div className="container-page py-24 text-center md:py-28">
        <h2 className="reveal mx-auto max-w-2xl text-balance text-3xl font-semibold leading-[1.1] tracking-[-0.02em] md:text-5xl">
          Try Edith on your Mac.
        </h2>
        <div className="reveal mt-8 flex justify-center">
          <a
            href={DOWNLOAD_HREF}
            className="inline-flex items-center gap-2 rounded-full bg-accent px-7 py-3.5 text-[14px] font-medium text-accent-foreground transition-transform hover:scale-[1.02]"
          >
            <AppleGlyph />
            Download for macOS
          </a>
        </div>
        <p className="reveal mt-3 text-[12px] text-subtle">Requires macOS. Apple Silicon and Intel.</p>
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="border-t border-border/60">
      <div className="container-page flex flex-col items-start justify-between gap-6 py-10 md:flex-row md:items-center">
        <div className="flex items-center gap-2">
          <IconMark />
          <span className="text-[13px] text-muted-foreground">
            © {new Date().getFullYear()} Edith. Made for macOS.
          </span>
        </div>
        <div className="flex items-center gap-6 text-[13px] text-muted-foreground">
          <a href="#features" className="hover:text-foreground">
            Features
          </a>
          <a href="#pricing" className="hover:text-foreground">
            Pricing
          </a>
          <a href={DOWNLOAD_HREF} className="hover:text-foreground">
            Download
          </a>
        </div>
      </div>
    </footer>
  );
}
