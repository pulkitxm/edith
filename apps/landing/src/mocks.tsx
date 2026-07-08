import { type ReactNode, useEffect, useState } from "react";

const HEAT_LEVELS = [
  "rgba(241,233,220,0.05)",
  "color-mix(in oklab, var(--accent) 28%, transparent)",
  "color-mix(in oklab, var(--accent) 50%, transparent)",
  "color-mix(in oklab, var(--accent) 72%, transparent)",
  "var(--accent)",
];

function Card({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <div
      className={`rounded-2xl border border-border-strong bg-surface p-6 shadow-[0_30px_80px_-30px_rgba(0,0,0,0.7)] ${className}`}
    >
      {children}
    </div>
  );
}

function MiniRing({ pct, color, label, sub }: { pct: number; color: string; label: string; sub: string }) {
  const r = 38;
  const c = 2 * Math.PI * r;
  return (
    <div className="flex flex-1 flex-col items-center gap-2">
      <div className="relative h-24 w-24">
        <svg width="96" height="96" viewBox="0 0 96 96">
          <circle cx="48" cy="48" r={r} fill="none" stroke="rgba(241,233,220,0.1)" strokeWidth="8" />
          <circle
            cx="48"
            cy="48"
            r={r}
            fill="none"
            stroke={color}
            strokeWidth="8"
            strokeLinecap="round"
            strokeDasharray={c}
            strokeDashoffset={c * (1 - pct / 100)}
            transform="rotate(-90 48 48)"
          />
        </svg>
        <span className="absolute inset-0 flex items-center justify-center font-mono text-xl font-semibold tabular-nums">
          {pct}%
        </span>
      </div>
      <span className="text-[10px] font-medium uppercase tracking-[0.16em] text-subtle">{label}</span>
      <span className="font-mono text-[11px] text-subtle">{sub}</span>
    </div>
  );
}

export function RingsMock() {
  return (
    <Card>
      <div className="mb-6 flex items-baseline justify-between">
        <span className="text-[11px] font-medium uppercase tracking-[0.16em] text-subtle">Rate limits</span>
        <span className="font-mono text-[11px] text-subtle">session · weekly</span>
      </div>
      <div className="flex gap-4">
        <MiniRing pct={47} color="var(--sage)" label="Session (5h)" sub="resets 2h 47m" />
        <MiniRing pct={68} color="var(--accent)" label="Weekly" sub="resets 3d 6h" />
      </div>
      <div className="mt-6 flex h-10 items-end gap-[3px]">
        {[18, 22, 20, 26, 30, 28, 34, 40, 37, 44, 48, 46, 53, 58, 55, 61, 66, 64, 68].map((h, i) => (
          <span
            key={i}
            className="flex-1 rounded-sm"
            style={{ height: `${h}%`, background: "color-mix(in oklab, var(--accent) 55%, transparent)" }}
          />
        ))}
      </div>
      <div className="mt-2 text-center font-mono text-[10px] text-subtle">24-hour spark</div>
    </Card>
  );
}

export function MenubarMock() {
  return (
    <Card>
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
    </Card>
  );
}

export function NotificationsMock() {
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

export function HeatmapMock() {
  const cols = 20;
  const rows = 7;
  const cells: number[] = [];
  for (let c = 0; c < cols; c++) {
    for (let r = 0; r < rows; r++) {
      const i = c * rows + r;
      const rnd = Math.abs(Math.sin(i * 12.9898 + 4.1) * 43758.5453) % 1;
      cells.push(rnd < 0.06 ? 0 : Math.min(4, 1 + Math.floor(rnd * 4.2)));
    }
  }
  return (
    <Card>
      <div className="mb-4 flex items-baseline justify-between">
        <span className="text-[11px] font-medium uppercase tracking-[0.16em] text-subtle">Activity</span>
        <span className="font-mono text-[11px] text-subtle">$1,284 · 13 weeks</span>
      </div>
      <div className="mb-1.5 grid grid-cols-3 font-mono text-[10px] text-subtle">
        <span>May</span>
        <span className="text-center">Jun</span>
        <span className="text-right">Jul</span>
      </div>
      <div className="flex gap-2">
        <div className="flex flex-col justify-between py-[1px] text-[9px] text-subtle">
          <span>M</span>
          <span>W</span>
          <span>F</span>
          <span>S</span>
        </div>
        <div className="grid flex-1 grid-flow-col grid-rows-7 gap-[4px]">
          {cells.map((lvl, i) => (
            <span
              key={i}
              className="aspect-square w-full rounded-[3px]"
              style={{ background: HEAT_LEVELS[lvl] }}
            />
          ))}
        </div>
      </div>
      <div className="mt-4 flex items-center justify-end gap-1.5 font-mono text-[10px] text-subtle">
        Less
        {HEAT_LEVELS.map((bg, i) => (
          <span key={i} className="h-3 w-3 rounded-[3px]" style={{ background: bg }} />
        ))}
        More
      </div>
    </Card>
  );
}

export function MusicMock() {
  const rows: [string, string][] = [
    ["Clair de Lune · Debussy", "5:02"],
    ["Time · Hans Zimmer", "4:35"],
    ["Intro · The xx", "2:07"],
  ];
  return (
    <Card>
      <div className="flex items-center gap-4">
        <div className="h-16 w-16 flex-none rounded-xl bg-gradient-to-br from-[#e08a6a] to-[#b3543a] shadow-[0_10px_30px_-10px_rgba(217,119,87,0.6)]" />
        <div className="min-w-0 flex-1">
          <div className="truncate text-[15px] font-semibold">Weightless</div>
          <div className="truncate text-[13px] text-muted-foreground">Marconi Union</div>
          <div className="relative mt-3 h-1.5 rounded-full bg-white/10">
            <div className="absolute inset-y-0 left-0 w-[42%] rounded-full bg-accent" />
            <div className="absolute left-[42%] top-1/2 h-3.5 w-3.5 -translate-x-1/2 -translate-y-1/2 rounded-full bg-foreground shadow" />
          </div>
          <div className="mt-1.5 flex justify-between font-mono text-[11px] text-subtle">
            <span>2:38</span>
            <span>-3:34</span>
          </div>
        </div>
      </div>
      <div className="mt-4 flex flex-col divide-y divide-border/60">
        {rows.map(([t, d]) => (
          <div key={t} className="flex items-center gap-3 py-2.5">
            <span className="h-8 w-8 flex-none rounded-md bg-gradient-to-br from-[#6a8d9e] to-[#2f4a63]" />
            <span className="flex-1 truncate text-[13px] text-muted-foreground">{t}</span>
            <span className="font-mono text-[11px] text-subtle">{d}</span>
          </div>
        ))}
      </div>
    </Card>
  );
}

export function SystemMock() {
  const tiles: [ReactNode, string, string, boolean][] = [
    [<KeyboardIcon key="k" />, "Clean keys", "Lock the keyboard to wipe it", false],
    [<MoonIcon key="m" />, "Keep awake", "Stop this Mac from sleeping", true],
    [<PresenterIcon key="p" />, "Presenter", "Blur sensitive values", false],
  ];
  return (
    <Card>
      <div className="mb-5 text-[11px] font-medium uppercase tracking-[0.16em] text-subtle">
        Quick actions
      </div>
      <div className="grid grid-cols-3 gap-3">
        {tiles.map(([icon, title, sub, active]) => (
          <div
            key={title}
            className={`flex flex-col items-center gap-2 rounded-xl border p-4 text-center ${
              active
                ? "border-accent/40 bg-accent/15 text-foreground"
                : "border-border/60 bg-background/40 text-muted-foreground"
            }`}
          >
            <span className={active ? "text-accent" : "text-subtle"}>{icon}</span>
            <span className="text-[13px] font-semibold text-foreground">{title}</span>
            <span className="text-[11px] leading-tight text-subtle">{sub}</span>
          </div>
        ))}
      </div>
      <div className="mt-3 flex items-center gap-2 rounded-lg border border-dashed border-border-strong px-3 py-2.5 text-[12px] text-subtle">
        <LockIcon />
        Keyboard relocks for 60s, then restores itself. No way to get stuck.
      </div>
    </Card>
  );
}

function tileIcon() {
  return {
    width: 20,
    height: 20,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.7,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
  };
}
function KeyboardIcon() {
  return (
    <svg {...tileIcon()} aria-hidden>
      <rect x="2.5" y="6" width="19" height="12" rx="2.5" />
      <path d="M6 9.5h.01M9.5 9.5h.01M13 9.5h.01M16.5 9.5h.01M6 13h.01M9.5 13h.01M13 13h.01M16.5 13h.01M8 15.5h8" />
    </svg>
  );
}
function MoonIcon() {
  return (
    <svg {...tileIcon()} aria-hidden>
      <path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z" />
    </svg>
  );
}
function PresenterIcon() {
  return (
    <svg {...tileIcon()} aria-hidden>
      <circle cx="9" cy="8" r="3" />
      <path d="M3.5 19a5.5 5.5 0 0 1 11 0M17 6a4 4 0 0 1 0 5M19.5 4a7 7 0 0 1 0 9" />
    </svg>
  );
}
function LockIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" className="flex-none" aria-hidden>
      <rect x="5" y="10.5" width="14" height="10" rx="2.2" />
      <path d="M8 10.5V7.5a4 4 0 0 1 8 0v3" />
    </svg>
  );
}

export function PresenterMock() {
  const [on, setOn] = useState(true);
  useEffect(() => {
    const id = setInterval(() => setOn((v) => !v), 2200);
    return () => clearInterval(id);
  }, []);
  const stat = (label: string, value: string, blur: boolean) => (
    <div className="rounded-lg border border-border/60 bg-background/40 p-3">
      <div className="text-[9px] font-medium uppercase tracking-[0.12em] text-subtle">{label}</div>
      <div className={`mt-1 font-mono text-lg font-semibold tabular-nums ${blur ? "blur-[6px] select-none" : ""}`}>
        {value}
      </div>
    </div>
  );
  return (
    <Card>
      <div className="mb-4 flex items-center justify-between">
        <span className="text-[11px] font-medium uppercase tracking-[0.16em] text-subtle">Usage</span>
        <span
          className={`inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[10px] font-medium uppercase tracking-[0.12em] transition-colors ${
            on ? "border-accent/50 bg-accent/15 text-accent" : "border-border-strong text-subtle"
          }`}
        >
          <span className={`h-1.5 w-1.5 rounded-full ${on ? "bg-accent" : "bg-subtle"}`} />
          {on ? "Presenter on" : "Presenter off"}
        </span>
      </div>
      <div className="grid grid-cols-2 gap-3">
        {stat("Cost this cycle", "$3.8k", on)}
        {stat("Tokens", "5.19B", on)}
        {stat("Cache hit", "99.5%", false)}
        {stat("Top model", "opus-4-8", false)}
      </div>
      <p className="mt-4 text-center text-[12px] text-subtle">
        {on ? "Spend and track names hidden for the room." : "Everything visible to you."}
      </p>
    </Card>
  );
}
