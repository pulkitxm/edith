import { useEffect, useMemo, useState } from "react";

type Track = { title: string; artist: string; from: string; to: string };

const TRACKS: Track[] = [
  { title: "Weightless", artist: "Marconi Union", from: "#e08a6a", to: "#b3543a" },
  { title: "Nightcall", artist: "Kavinsky", from: "#6a8d9e", to: "#2f4a63" },
  { title: "Strobe", artist: "deadmau5", from: "#7a9e83", to: "#2f5c3f" },
  { title: "Teardrop", artist: "Massive Attack", from: "#9e6a97", to: "#5c2f56" },
  { title: "Intro", artist: "The xx", from: "#c89b3c", to: "#7a5c14" },
];

const HEAT_LEVELS = [
  "rgba(241,233,220,0.05)",
  "color-mix(in oklab, var(--accent) 28%, transparent)",
  "color-mix(in oklab, var(--accent) 50%, transparent)",
  "color-mix(in oklab, var(--accent) 72%, transparent)",
  "var(--accent)",
];

const NAV = ["Home", "Agent Usage", "Music", "Calendar"];

function Ring({ pct, color, label, sub }: { pct: number; color: string; label: string; sub: string }) {
  const r = 34;
  const c = 2 * Math.PI * r;
  const offset = c * (1 - pct / 100);
  return (
    <div className="flex flex-col items-center gap-1.5">
      <div className="relative h-[86px] w-[86px]">
        <svg width="86" height="86" viewBox="0 0 86 86">
          <circle cx="43" cy="43" r={r} fill="none" stroke="rgba(241,233,220,0.1)" strokeWidth="7" />
          <circle
            cx="43"
            cy="43"
            r={r}
            fill="none"
            stroke={color}
            strokeWidth="7"
            strokeLinecap="round"
            strokeDasharray={c}
            strokeDashoffset={offset}
            transform="rotate(-90 43 43)"
          />
        </svg>
        <span className="absolute inset-0 flex items-center justify-center font-mono text-lg font-semibold tabular-nums">
          {pct}%
        </span>
      </div>
      <span className="text-[9px] font-medium uppercase tracking-[0.16em] text-subtle">{label}</span>
      <span className="font-mono text-[10px] text-subtle">{sub}</span>
    </div>
  );
}

export default function EdithDemo() {
  const [presenter, setPresenter] = useState(false);
  const [ti, setTi] = useState(0);
  const [progress, setProgress] = useState(18);

  useEffect(() => {
    const id = setInterval(() => {
      setProgress((p) => {
        if (p >= 100) {
          setTi((t) => (t + 1) % TRACKS.length);
          return 0;
        }
        return p + 100 / 60;
      });
    }, 100);
    return () => clearInterval(id);
  }, []);

  const cols = 18;
  const rows = 7;
  const heat = useMemo(() => {
    const cells: number[] = [];
    for (let c = 0; c < cols; c++) {
      for (let r = 0; r < rows; r++) {
        const i = c * rows + r;
        const rnd = Math.abs(Math.sin(i * 12.9898 + 4.1) * 43758.5453) % 1;
        cells.push(rnd < 0.06 ? 0 : Math.min(4, 1 + Math.floor(rnd * 4.2)));
      }
    }
    return cells;
  }, []);

  const track = TRACKS[ti];
  const blur = presenter ? "blur-[7px] select-none" : "";

  const kpis: [string, string, boolean][] = [
    ["Total cost", "$3.8k", true],
    ["Tokens", "5.19B", true],
    ["Cache hit", "99.5%", false],
    ["Top model", "opus-4-8", false],
  ];

  return (
    <div className="overflow-hidden rounded-2xl border border-border-strong bg-surface shadow-[0_50px_120px_-40px_rgba(0,0,0,0.8)] ring-1 ring-white/5">
      <div className="flex items-center gap-3 border-b border-border/70 px-5 py-3">
        <div className="flex gap-2">
          <span className="h-3 w-3 rounded-full bg-[#ff5f57]" />
          <span className="h-3 w-3 rounded-full bg-[#febc2e]" />
          <span className="h-3 w-3 rounded-full bg-[#28c840]" />
        </div>
        <span className="text-[13px] font-medium text-muted-foreground">Edith</span>
        <span className="flex-1" />
        <button
          type="button"
          onClick={() => setPresenter((v) => !v)}
          aria-pressed={presenter}
          className={`inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-[11px] font-medium uppercase tracking-[0.12em] transition-colors ${
            presenter
              ? "border-accent/50 bg-accent/15 text-accent"
              : "border-border-strong text-muted-foreground hover:text-foreground"
          }`}
        >
          <span className={`h-1.5 w-1.5 rounded-full ${presenter ? "bg-accent" : "bg-subtle"}`} />
          Presenter
        </button>
      </div>

      <div className="flex">
        <aside className="hidden w-44 flex-none flex-col gap-1 border-r border-border/60 p-3 md:flex">
          {NAV.map((n) => (
            <span
              key={n}
              className={`rounded-lg px-3 py-2 text-[13px] ${
                n === "Agent Usage"
                  ? "bg-white/5 font-medium text-foreground"
                  : "text-muted-foreground"
              }`}
            >
              {n}
            </span>
          ))}
          <span className="mt-auto rounded-lg px-3 py-2 text-[12px] text-subtle">Settings</span>
        </aside>

        <div className="min-w-0 flex-1 p-5 md:p-6">
          <div className="mb-1 text-2xl font-semibold tracking-[-0.01em]" style={{ fontFamily: "Georgia, 'Iowan Old Style', 'Times New Roman', serif" }}>
            The cost of <span className="italic text-accent">thinking</span>.
          </div>
          <div className="mb-5 text-[12px] text-subtle">
            13 active days · 5 models · Claude Code + Codex + OpenCode
          </div>

          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            {kpis.map(([label, value, sensitive]) => (
              <div key={label} className="rounded-xl border border-border/70 bg-background/40 p-3.5">
                <div className="text-[10px] font-medium uppercase tracking-[0.12em] text-subtle">
                  {label}
                </div>
                <div
                  className={`mt-2 font-mono text-xl font-semibold tabular-nums transition-[filter] ${
                    sensitive ? blur : ""
                  }`}
                >
                  {value}
                </div>
              </div>
            ))}
          </div>

          <div className="mt-4 grid gap-4 md:grid-cols-[auto_1fr]">
            <div className="rounded-xl border border-border/70 bg-background/40 p-4">
              <div className="mb-3 text-[10px] font-medium uppercase tracking-[0.14em] text-subtle">
                Rate limits
              </div>
              <div className="flex gap-5">
                <Ring pct={47} color="var(--sage)" label="Session" sub="2h 47m" />
                <Ring pct={68} color="var(--accent)" label="Week" sub="3d 6h" />
              </div>
            </div>

            <div className="rounded-xl border border-border/70 bg-background/40 p-4">
              <div className="mb-3 flex items-center justify-between">
                <span className="text-[10px] font-medium uppercase tracking-[0.14em] text-subtle">
                  Activity
                </span>
                <span className="font-mono text-[10px] text-subtle">May → Jul</span>
              </div>
              <div className="flex gap-2">
                <div className="flex flex-col justify-between py-[1px] text-[9px] text-subtle">
                  <span>M</span>
                  <span>W</span>
                  <span>F</span>
                  <span>S</span>
                </div>
                <div className="grid flex-1 grid-flow-col grid-rows-7 gap-[4px]">
                  {heat.map((lvl, i) => (
                    <span
                      key={i}
                      className="aspect-square w-full rounded-[3px]"
                      style={{ background: HEAT_LEVELS[lvl] }}
                    />
                  ))}
                </div>
              </div>
            </div>
          </div>

          <div className="mt-4 flex items-center gap-4 rounded-xl border border-border/70 bg-background/40 p-3">
            <div
              className="h-12 w-12 flex-none rounded-lg"
              style={{ background: `linear-gradient(145deg, ${track.from}, ${track.to})` }}
            />
            <div className="min-w-0 flex-1">
              <div className={`truncate text-[14px] font-semibold transition-[filter] ${blur}`}>
                {track.title}
              </div>
              <div className={`truncate text-[12px] text-muted-foreground transition-[filter] ${blur}`}>
                {track.artist}
              </div>
              <div className="mt-2 h-1 overflow-hidden rounded-full bg-white/10">
                <div
                  className="h-full rounded-full bg-accent transition-[width] duration-100 ease-linear"
                  style={{ width: `${progress}%` }}
                />
              </div>
            </div>
            <div className="flex items-center gap-3 text-muted-foreground">
              <span>⏮</span>
              <span className="flex h-8 w-8 items-center justify-center rounded-full bg-foreground text-[12px] text-background">
                ❚❚
              </span>
              <span>⏭</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
