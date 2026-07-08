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
  "rgba(241,233,220,0.06)",
  "color-mix(in oklab, var(--accent) 30%, transparent)",
  "color-mix(in oklab, var(--accent) 52%, transparent)",
  "color-mix(in oklab, var(--accent) 74%, transparent)",
  "var(--accent)",
];

function Ring({ pct, color, label, sub }: { pct: number; color: string; label: string; sub: string }) {
  const r = 42;
  const c = 2 * Math.PI * r;
  const offset = c * (1 - pct / 100);
  return (
    <div className="flex flex-col items-center gap-2">
      <div className="relative h-[104px] w-[104px]">
        <svg width="104" height="104" viewBox="0 0 104 104">
          <circle cx="52" cy="52" r={r} fill="none" stroke="rgba(241,233,220,0.1)" strokeWidth="8" />
          <circle
            cx="52"
            cy="52"
            r={r}
            fill="none"
            stroke={color}
            strokeWidth="8"
            strokeLinecap="round"
            strokeDasharray={c}
            strokeDashoffset={offset}
            transform="rotate(-90 52 52)"
          />
        </svg>
        <span className="absolute inset-0 flex items-center justify-center font-mono text-2xl font-semibold tabular-nums">
          {pct}%
        </span>
      </div>
      <span className="text-[10px] font-medium uppercase tracking-[0.16em] text-subtle">{label}</span>
      <span className="font-mono text-[11px] text-muted-foreground">{sub}</span>
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

  const heat = useMemo(
    () =>
      Array.from({ length: 98 }, (_, i) => {
        const r = Math.abs(Math.sin(i * 12.9898 + 4.1) * 43758.5453);
        const f = r - Math.floor(r);
        return f < 0.1 ? 0 : Math.min(4, 1 + Math.floor(f * 4.2));
      }),
    [],
  );

  const track = TRACKS[ti];
  const blur = presenter ? "blur-[7px] select-none" : "";

  const kpis: [string, string, boolean][] = [
    ["Cost this cycle", "$3.8k", true],
    ["Tokens", "5.19B", true],
    ["Cache hit", "99.5%", false],
    ["Top model", "opus-4-8", false],
  ];

  return (
    <div className="overflow-hidden rounded-2xl border border-border-strong bg-surface shadow-[0_50px_120px_-40px_rgba(0,0,0,0.8)] ring-1 ring-white/5">
      <div className="flex items-center gap-3 border-b border-border/70 px-5 py-3.5">
        <div className="flex gap-2">
          <span className="h-3 w-3 rounded-full bg-[#ff5f57]" />
          <span className="h-3 w-3 rounded-full bg-[#febc2e]" />
          <span className="h-3 w-3 rounded-full bg-[#28c840]" />
        </div>
        <span className="text-[13px] font-medium text-muted-foreground">Edith · Dashboard</span>
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

      <div className="grid gap-4 p-5 md:p-6">
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

        <div className="grid gap-4 md:grid-cols-[auto_1fr]">
          <div className="rounded-xl border border-border/70 bg-background/40 p-5">
            <div className="mb-4 text-[10px] font-medium uppercase tracking-[0.14em] text-subtle">
              Rate limits
            </div>
            <div className="flex gap-6">
              <Ring pct={47} color="var(--sage)" label="Session" sub="resets 2h 47m" />
              <Ring pct={68} color="var(--accent)" label="Week" sub="resets 3d 6h" />
            </div>
          </div>

          <div className="rounded-xl border border-border/70 bg-background/40 p-5">
            <div className="mb-4 flex items-center justify-between">
              <span className="text-[10px] font-medium uppercase tracking-[0.14em] text-subtle">
                Activity
              </span>
              <span className="font-mono text-[10px] text-subtle">May → Jul</span>
            </div>
            <div className="grid grid-flow-col grid-rows-7 gap-[5px]">
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

        <div className="flex items-center gap-4 rounded-xl border border-border/70 bg-background/40 p-3.5">
          <div
            className="h-14 w-14 flex-none rounded-lg"
            style={{ background: `linear-gradient(145deg, ${track.from}, ${track.to})` }}
          />
          <div className="min-w-0 flex-1">
            <div className={`truncate text-[15px] font-semibold transition-[filter] ${blur}`}>
              {track.title}
            </div>
            <div className={`truncate text-[13px] text-muted-foreground transition-[filter] ${blur}`}>
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
            <span className="text-lg">⏮</span>
            <span className="flex h-9 w-9 items-center justify-center rounded-full bg-foreground text-[13px] text-background">
              ❚❚
            </span>
            <span className="text-lg">⏭</span>
          </div>
        </div>
      </div>
    </div>
  );
}
