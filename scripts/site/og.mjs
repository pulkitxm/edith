import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { escapeHtml, icon, setIconRoot } from "./layout.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const site = join(root, "apps/site");
const chrome =
  process.env.CHROME ??
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const only = process.argv.slice(2);

setIconRoot(join(root, "Packages/EdithIcons/svg"));

const appIcon = `data:image/png;base64,${readFileSync(join(site, "app-icon-512.png")).toString("base64")}`;

function card({ kicker, title, subtitle, icon: glyph, mark, extension }) {
  const art = mark
    ? `<img class="mark" src="${appIcon}" alt="" />`
    : `<div class="tile${extension ? " ext" : ""}">${icon(glyph)}</div>`;
  const size = title.length > 26 ? 66 : title.length > 16 ? 78 : 92;
  return `<!doctype html><html><head><meta charset="utf-8" /><style>
  * { box-sizing: border-box; margin: 0; }
  html, body { width: 1200px; height: 630px; overflow: hidden; }
  body {
    font-family: -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif;
    color: #f4f1ea;
    background:
      radial-gradient(70% 90% at 88% 22%, rgba(233, 182, 90, 0.16), transparent 60%),
      radial-gradient(80% 120% at 0% 0%, rgba(42, 74, 143, 0.45), transparent 60%),
      linear-gradient(160deg, #0c1428 0%, #070a12 70%);
    position: relative;
  }
  body::after {
    content: ""; position: absolute; inset: 0;
    background-image: linear-gradient(rgba(255,255,255,0.025) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.025) 1px, transparent 1px);
    background-size: 48px 48px;
    mask-image: radial-gradient(70% 70% at 70% 30%, #000, transparent 75%);
  }
  .brand { position: absolute; top: 64px; left: 72px; display: flex; align-items: center; gap: 16px; font-size: 30px; font-weight: 700; letter-spacing: -0.02em; z-index: 1; }
  .brand img { width: 48px; height: 48px; border-radius: 11px; }
  .copy { position: absolute; top: 168px; left: 72px; width: 640px; z-index: 1; }
  .kicker { font-size: 20px; font-weight: 700; letter-spacing: 0.2em; text-transform: uppercase; color: #e9b65a; margin-bottom: 22px; }
  h1 { font-size: ${size}px; line-height: 1.02; font-weight: 800; letter-spacing: -0.045em; }
  p { margin-top: 22px; font-size: 28px; line-height: 1.35; color: #aeb6cc; max-width: 600px; }
  .tile { position: absolute; right: 96px; top: 150px; width: 300px; height: 300px; border-radius: 72px; display: flex; align-items: center; justify-content: center; color: #f7d996; background: linear-gradient(160deg, #233159, #101a33); border: 1.5px solid rgba(233,182,90,0.4); box-shadow: 0 40px 100px rgba(0,0,0,0.55), 0 0 120px rgba(233,182,90,0.18), inset 0 1px 0 rgba(255,255,255,0.12); z-index: 1; }
  .tile svg { width: 150px; height: 150px; }
  .tile svg .secondary { opacity: 0.45; }
  .mark { position: absolute; right: 90px; top: 120px; width: 330px; height: 330px; filter: drop-shadow(0 40px 80px rgba(233,182,90,0.3)); z-index: 1; }
  .domain { position: absolute; right: 72px; bottom: 56px; font-size: 22px; color: rgba(244,241,234,0.5); letter-spacing: 0.01em; z-index: 1; }
</style></head><body>
  <div class="brand"><img src="${appIcon}" alt="" />Edith</div>
  <div class="copy"><div class="kicker">${escapeHtml(kicker)}</div><h1>${escapeHtml(title)}</h1><p>${escapeHtml(subtitle)}</p></div>
  ${art}
  <div class="domain">edith.pulkit.page</div>
</body></html>`;
}

const pages = JSON.parse(
  readFileSync(join(here, "og-pages.json"), "utf8"),
).filter((entry) => only.length === 0 || only.includes(entry.slug));
const work = mkdtempSync(join(tmpdir(), "edith-og-"));
mkdirSync(join(site, "og"), { recursive: true });
try {
  for (const entry of pages) {
    const html = join(work, `${entry.slug}.html`);
    writeFileSync(html, card(entry));
    execFileSync(
      chrome,
      [
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        "--force-device-scale-factor=1",
        `--user-data-dir=${join(work, "profile")}`,
        "--window-size=1200,630",
        `--screenshot=${join(work, `${entry.slug}.png`)}`,
        `file://${html}`,
      ],
      { stdio: "ignore" },
    );
    execFileSync(
      "sips",
      [
        "-s",
        "format",
        "jpeg",
        "-s",
        "formatOptions",
        "90",
        join(work, `${entry.slug}.png`),
        "--out",
        join(site, "og", `${entry.slug}.jpg`),
      ],
      { stdio: "ignore" },
    );
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}
console.log(`rendered ${pages.length} social cards`);
