import { type ReactNode, useEffect } from "react";
import EdithDemo from "./EdithDemo";
import {
  HeatmapMock,
  MenubarMock,
  MusicMock,
  NotificationsMock,
  PresenterMock,
  RingsMock,
  SystemMock,
} from "./mocks";

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
      <TryIt />
      <Pitch />
      <ReplacesTable />
      <Feature
        eyebrow="Rate limits"
        title="Live rings for session and week."
        body="Second-by-second countdowns to your next 5-hour session reset and to the weekly rollover. A 24-hour spark shows the shape of your day at a glance."
        media={<RingsMock />}
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
        eyebrow="Heatmap"
        reverse
        title="A year of usage at a glance."
        body="A GitHub-style calendar of daily spend across your full history. Every day is a square, shaded by how much you spent. Hover any square for the exact number."
        media={<HeatmapMock />}
      />
      <Feature
        eyebrow="Music"
        title="Your local music folder, done right."
        body="Cover thumbnails, drag-to-seek, crossfades, auto-advance, and media keys. Point it at a folder and press play. No cloud, no accounts, no ads."
        media={<MusicMock />}
      />
      <Feature
        eyebrow="Privacy"
        reverse
        title="Presenter mode for the room."
        body="One toggle blurs spend figures and track names so you can screen-share without exposing your bill. Watch it flip below. Usage stays local, with optional iCloud backup that merges across your machines."
        media={<PresenterMock />}
      />
      <Feature
        eyebrow="System"
        title="Prevent sleep. Lock the keyboard."
        body="Keep your Mac awake for a long build, even with the lid closed on power. Lock the keyboard to wipe it down without triggering shortcuts. Auto-restores in sixty seconds so you can't lock yourself out."
        media={<SystemMock />}
      />
      <MoreFeatures />
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
      <div className="container-page relative pt-24 pb-16 md:pt-36 md:pb-24">
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

        <div className="reveal mt-16 md:mt-20">
          <img
            src="/media/dashboard.png"
            alt="Edith dashboard: total cost, tokens, cache hit rate, activity heatmap and session vs weekly rate-limit chart"
            width={2921}
            height={1620}
            className="w-full rounded-2xl border border-border-strong shadow-[0_50px_120px_-40px_rgba(0,0,0,0.8)] ring-1 ring-white/5"
            decoding="async"
            fetchPriority="high"
          />
          <p className="mt-4 text-center text-[12px] text-subtle">
            The Agent Usage dashboard. A real screenshot, not a mockup.
          </p>
        </div>
      </div>
    </section>
  );
}

function TryIt() {
  return (
    <section className="container-page pb-8 md:pb-12">
      <div className="reveal mx-auto mb-8 max-w-2xl text-center">
        <p className="text-[12px] font-medium uppercase tracking-[0.18em] text-accent">Try it live</p>
        <h2 className="mt-3 text-balance text-2xl font-semibold tracking-[-0.02em] md:text-3xl">
          An interactive taste of the app.
        </h2>
        <p className="mt-3 text-[15px] text-muted-foreground">
          Toggle presenter mode to blur the numbers. The music widget rotates on its own. This one
          runs in your browser.
        </p>
      </div>
      <div className="reveal mx-auto max-w-4xl">
        <EdithDemo />
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
    ["A clipboard manager", "Clipboard history with instant paste on a hotkey", "$6/mo"],
    ["A color picker", "System loupe on a hotkey, sampled hex to your clipboard", "$5/mo"],
    ["Focus and system utilities", "Focus dim, prevent-sleep, keyboard-clean lock, notch shelf", "$5/mo"],
  ];
  return (
    <section id="features" className="container-page pb-24 md:pb-32">
      <div className="reveal overflow-hidden rounded-2xl border border-border bg-surface">
        <div className="grid grid-cols-[1.3fr_1.5fr_auto] gap-6 border-b border-border bg-surface-elevated px-6 py-4 text-[12px] font-medium uppercase tracking-[0.14em] text-muted-foreground md:px-8">
          <span>Instead of paying monthly for</span>
          <span>Edith includes it</span>
          <span className="text-right">Their price</span>
        </div>
        {rows.map(([a, b, price], i) => (
          <div
            key={a}
            className={`grid grid-cols-[1.3fr_1.5fr_auto] items-start gap-6 px-6 py-5 md:px-8 md:py-6 ${
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
          $56/mo · roughly $672 a year across nine separate apps
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

function MoreFeatures() {
  const items: [ReactNode, string, string][] = [
    [<EyedropperGlyph key="c" />, "Color picker", "A system loupe on a hotkey. Sample any pixel and the hex lands on your clipboard."],
    [<FocusGlyph key="f" />, "Focus dim", "Dims everything behind your active app so one window is all you see."],
    [<NotchGlyph key="n" />, "Notch shelf", "Park files under the notch mid-drag, then drop them wherever they belong."],
    [<ClipboardGlyph key="cl" />, "Clipboard history", "Everything you copied, one shortcut away, with instant paste."],
    [<CalendarGlyph key="ca" />, "Calendar", "Today's schedule in the panel and the app, with one-tap join links."],
    [<ClockGlyph key="w" />, "World clocks", "Local time plus the offices you care about, at a glance."],
    [<CommandGlyph key="s" />, "Global shortcut", "Toggle the panel from anywhere. Defaults to ⌥⌘E and re-records to taste."],
    [<ShieldGlyph key="l" />, "Local first", "Usage never leaves your Mac. Optional iCloud backup merges across machines."],
  ];
  return (
    <section className="border-t border-border/60">
      <div className="container-page py-24 md:py-32">
        <div className="reveal mx-auto mb-14 max-w-2xl text-center">
          <p className="text-[12px] font-medium uppercase tracking-[0.18em] text-accent">And the rest of the shelf</p>
          <h2 className="mt-3 text-balance text-3xl font-semibold leading-[1.1] tracking-[-0.02em] md:text-5xl">
            Nine more tools you'd otherwise install one by one.
          </h2>
        </div>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {items.map(([glyph, title, body]) => (
            <div key={title} className="reveal rounded-2xl border border-border bg-surface p-6">
              <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-accent/12 text-accent">
                {glyph}
              </div>
              <h4 className="mt-5 text-[17px] font-semibold tracking-tight">{title}</h4>
              <p className="mt-2 text-[14px] leading-relaxed text-muted-foreground">{body}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function glyphProps() {
  return {
    width: 22,
    height: 22,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.7,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
  };
}
function EyedropperGlyph() {
  return (
    <svg {...glyphProps()} aria-hidden>
      <path d="M13 7l4 4M4 20l1-4 9-9 3 3-9 9-4 1zM15 5l2-2a2 2 0 0 1 3 3l-2 2" />
    </svg>
  );
}
function FocusGlyph() {
  return (
    <svg {...glyphProps()} aria-hidden>
      <circle cx="12" cy="12" r="4" />
      <path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3" />
    </svg>
  );
}
function NotchGlyph() {
  return (
    <svg {...glyphProps()} aria-hidden>
      <path d="M3 6h6a2 2 0 0 0 2 2h2a2 2 0 0 0 2-2h6" />
      <rect x="7" y="12" width="10" height="7" rx="1.5" />
      <path d="M12 12v-2" />
    </svg>
  );
}
function ClipboardGlyph() {
  return (
    <svg {...glyphProps()} aria-hidden>
      <rect x="6" y="4" width="12" height="17" rx="2" />
      <path d="M9 4a3 3 0 0 1 6 0M9 11h6M9 15h4" />
    </svg>
  );
}
function CalendarGlyph() {
  return (
    <svg {...glyphProps()} aria-hidden>
      <rect x="4" y="5" width="16" height="16" rx="2" />
      <path d="M4 9h16M8 3v4M16 3v4" />
    </svg>
  );
}
function ClockGlyph() {
  return (
    <svg {...glyphProps()} aria-hidden>
      <circle cx="12" cy="12" r="8" />
      <path d="M12 8v4l3 2" />
    </svg>
  );
}
function CommandGlyph() {
  return (
    <svg {...glyphProps()} aria-hidden>
      <path d="M9 6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3z" />
    </svg>
  );
}
function ShieldGlyph() {
  return (
    <svg {...glyphProps()} aria-hidden>
      <path d="M12 3l7 3v5c0 4.5-3 7-7 8.5C8 18 5 15.5 5 11V6z" />
      <path d="M9 12l2 2 4-4" />
    </svg>
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
              "Clipboard, color picker, focus dim, notch shelf",
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
          Compare to roughly $56 a month across nine separate menu bar utilities. Edith pays for
          itself in under a week.
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
