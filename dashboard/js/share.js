import { activeWindow, derive } from "./compute.js";
import { fmtTok, fmtUSD, MON, shortModel } from "./format.js";
import { workSummary } from "./render.js";
import { charts, state } from "./state.js";
import { statsSummary } from "./stats.js";
import { toast } from "./toast.js";

const cssVar = (n, fallback) =>
  getComputedStyle(document.body).getPropertyValue(n).trim() || fallback;
function cardTheme() {
  return {
    bg: cssVar("--paper-2", "#fffdf8"),
    ink: cssVar("--ink", "#241f1a"),
    soft: cssVar("--ink-soft", "#5c5247"),
    faint: cssVar("--ink-faint", "#9a8f80"),
    gold: cssVar("--gold", "#c89b3c"),
    accent: cssVar("--accent", "#d97757"),
    mono: cssVar("--mono", "monospace"),
    serif: cssVar("--serif", "Georgia, serif"),
    line: cssVar("--line-strong", "#e7ddcb"),
  };
}

const dlabel = (d, withYear) =>
  `${d.getDate()} ${MON[d.getMonth()]}` +
  (withYear ? ` ${d.getFullYear()}` : "");

export function rangeLabel() {
  if (state.range.mode === "all") return "All time";
  const w = activeWindow();
  const sameYear = w.from.getFullYear() === w.to.getFullYear();
  return `${dlabel(w.from, !sameYear)} – ${dlabel(w.to, true)}`;
}

const fileYmd = (d) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

function cardFilename() {
  if (state.range.mode === "all") return "cc-usage_all.png";
  const w = activeWindow();
  return `cc-usage_${fileYmd(w.from)}_${fileYmd(w.to)}.png`;
}

function triggerDownload(canvas, filename) {
  canvas.toBlob((blob) => {
    if (!blob) return;
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  }, "image/png");
}

function drawFlexGrid(ctx, t, cells, { PAD, W, blurCost, blurred }) {
  const n = cells.length;
  if (!n) return;
  const contentW = W - PAD * 2;
  const maxPerRow = 3;
  const rows = Math.ceil(n / maxPerRow);
  const cols = Math.ceil(n / rows);
  const cellW = contentW / cols;
  const rowH = 112;
  const bandTop = 318,
    bandBottom = 560;
  const blockH = (rows - 1) * rowH + 60;
  const firstLabelY =
    Math.round(bandTop + (bandBottom - bandTop - blockH) / 2) + 14;

  for (let i = 0; i < n; i++) {
    const r = Math.floor(i / cols);
    const rowStart = r * cols;
    const rowCount = Math.min(cols, n - rowStart);
    const rowLeft = PAD + (contentW - rowCount * cellW) / 2;
    const x = rowLeft + (i - rowStart) * cellW;
    const yLabel = firstLabelY + r * rowH;

    ctx.fillStyle = t.faint;
    ctx.font = `15px ${t.mono}`;
    ctx.fillText(cells[i].label, x, yLabel);
    const drawVal = () => {
      ctx.fillStyle = t.ink;
      ctx.font = `600 42px ${t.mono}`;
      ctx.fillText(cells[i].value, x, yLabel + 46);
    };
    if (blurCost && cells[i].cost) blurred(14, drawVal);
    else drawVal();
  }
}

export function drawShareCard(opts = {}) {
  const { blurCost = false } = opts;
  const s = statsSummary(derive());
  const work = workSummary();
  const t = cardTheme();
  const W = 1200,
    H = 630,
    SCALE = 2;
  const canvas = document.createElement("canvas");
  canvas.width = W * SCALE;
  canvas.height = H * SCALE;
  const ctx = canvas.getContext("2d");
  ctx.scale(SCALE, SCALE);

  const blurred = (radius, fn, stamps = 3) => {
    ctx.save();
    ctx.filter = `blur(${radius}px)`;
    for (let i = 0; i < stamps; i++) fn();
    ctx.restore();
  };

  ctx.fillStyle = t.bg;
  ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = t.accent;
  ctx.fillRect(0, 0, W, 6);

  const PAD = 72,
    COL2 = PAD + 470;

  ctx.fillStyle = t.ink;
  ctx.font = `600 38px ${t.serif}`;
  ctx.fillText("Claude Code · Usage", PAD, 96);
  ctx.fillStyle = t.soft;
  ctx.font = `19px ${t.mono}`;
  ctx.fillText(rangeLabel(), PAD, 128);

  ctx.font = `700 84px ${t.mono}`;
  const drawCost = () => {
    ctx.fillStyle = t.gold;
    ctx.fillText(fmtUSD(s.totalCost), PAD, 232);
  };
  if (blurCost) blurred(38, drawCost);
  else drawCost();
  ctx.fillStyle = t.ink;
  ctx.fillText(fmtTok(s.totalTokens), COL2, 232);
  ctx.fillStyle = t.faint;
  ctx.font = `13px ${t.mono}`;
  ctx.fillText("TOTAL COST", PAD, 262);
  ctx.fillText("TOTAL TOKENS", COL2, 262);

  ctx.fillStyle = t.line;
  ctx.fillRect(PAD, 296, W - PAD * 2, 1);

  const cells = [
    {
      label: "INPUT / OUTPUT",
      value: `${fmtTok(s.input)} / ${fmtTok(s.output)}`,
    },
    { label: "SESSIONS", value: String(work.sessions) },
    { label: "PROJECTS", value: String(work.projects) },
    { label: "TOP MODEL", value: s.topModel ? shortModel(s.topModel) : "-" },
  ];
  drawFlexGrid(ctx, t, cells, { PAD, W, blurCost, blurred });

  return canvas;
}

function openCardModal() {
  const overlay = document.createElement("div");
  overlay.className = "card-modal-overlay";
  overlay.innerHTML = `
      <div class="card-modal" role="dialog" aria-modal="true" aria-label="Share card preview">
        <div class="card-modal-preview"><img alt="Share card preview"></div>
        <div class="card-modal-bar">
          <label class="card-modal-toggle"><input type="checkbox" id="cm-blur"> Blur cost ($)</label>
          <div class="card-modal-actions">
            <button type="button" class="btn-reset" id="cm-cancel">Cancel</button>
            <button type="button" class="btn-reset cm-primary" id="cm-download">⤓ Download PNG</button>
          </div>
        </div>
      </div>`;
  document.body.appendChild(overlay);

  const img = overlay.querySelector("img");
  const blur = overlay.querySelector("#cm-blur");
  let canvas = null;
  const refresh = () => {
    canvas = drawShareCard({ blurCost: blur.checked });
    img.src = canvas.toDataURL("image/png");
  };
  refresh();
  blur.addEventListener("change", refresh);

  const close = () => {
    overlay.remove();
    document.removeEventListener("keydown", onKey);
  };
  const onKey = (e) => {
    if (e.key === "Escape") close();
  };
  document.addEventListener("keydown", onKey);
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) close();
  });
  overlay.querySelector("#cm-cancel").addEventListener("click", close);
  overlay.querySelector("#cm-download").addEventListener("click", () => {
    triggerDownload(canvas, cardFilename());
    toast("Card downloaded");
    close();
  });
}

export async function downloadHeatmap() {
  const card =
    document.getElementById("heat") &&
    document.getElementById("heat").closest(".card");
  if (!card) return;
  try {
    const SCALE = 2;
    const pageBg = cssVar("--paper", "#fff");

    const clone = card.cloneNode(true);
    clone.querySelectorAll(".heat-dl").forEach((el) => el.remove());
    clone.querySelectorAll(".heat-wrap").forEach((el) => {
      el.style.overflow = "visible";
    });
    const liveSel = document.getElementById("heat-metric");
    const cloneSel = clone.querySelector("#heat-metric");
    if (liveSel && cloneSel) {
      const chip = document.createElement("span");
      chip.className = cloneSel.className;
      chip.setAttribute("style", cloneSel.getAttribute("style") || "");
      chip.textContent = liveSel.options[liveSel.selectedIndex]
        ? liveSel.options[liveSel.selectedIndex].text
        : "";
      cloneSel.replaceWith(chip);
    }

    clone.style.boxSizing = "border-box";
    clone.style.width = card.offsetWidth + "px";
    clone.style.position = "fixed";
    clone.style.left = "-99999px";
    clone.style.top = "0";
    clone.style.margin = "0";
    document.body.appendChild(clone);
    const W = Math.ceil(Math.max(clone.scrollWidth, clone.offsetWidth));
    clone.style.width = W + "px";
    const cloneTop = clone.getBoundingClientRect().top;
    let maxBottom = clone.getBoundingClientRect().bottom;
    clone.querySelectorAll("*").forEach((el) => {
      const b = el.getBoundingClientRect().bottom;
      if (b > maxBottom) maxBottom = b;
    });
    const H = Math.ceil(maxBottom - cloneTop);
    const _sp = clone.querySelector(".hs-spark");
    const _dbgSparkBottom = _sp
      ? Math.round(_sp.getBoundingClientRect().bottom - cloneTop)
      : -1;
    const _dbgScrollH = clone.scrollHeight;

    const styleText = [...document.querySelectorAll("style")]
      .map((s) => s.textContent)
      .join("\n");
    const bodyCS = getComputedStyle(document.body);
    const varNames = new Set();
    let m;
    const re = /(--[\w-]+)\s*:/g;
    while ((m = re.exec(styleText))) varNames.add(m[1]);
    let vars = "";
    varNames.forEach((n) => {
      const v = bodyCS.getPropertyValue(n);
      if (v) vars += `${n}:${v.trim()};`;
    });

    const inherited =
      `color:${bodyCS.color};font-family:${bodyCS.fontFamily};` +
      `font-size:${bodyCS.fontSize};line-height:${bodyCS.lineHeight};` +
      `color-scheme:${getComputedStyle(document.documentElement).colorScheme || "light"};`;

    clone.style.position = "static";
    clone.style.left = "";
    clone.style.top = "";
    clone.setAttribute(
      "style",
      (clone.getAttribute("style") || "") + ";" + vars + inherited,
    );
    const xhtml = new XMLSerializer().serializeToString(clone);
    clone.remove();

    const svg =
      `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">` +
      `<foreignObject x="0" y="0" width="${W}" height="${H}">` +
      `<div xmlns="http://www.w3.org/1999/xhtml"><style><![CDATA[${styleText}]]></style>${xhtml}</div>` +
      `</foreignObject>` +
      `</svg>`;

    const img = new Image();
    await new Promise((res, rej) => {
      img.onload = res;
      img.onerror = () => rej(new Error("foreignObject render failed"));
      img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
    });
    console.log(
      "[heatmap dbg] img natural=",
      img.naturalWidth,
      "x",
      img.naturalHeight,
    );

    const canvas = document.createElement("canvas");
    canvas.width = W * SCALE;
    canvas.height = H * SCALE;
    const ctx = canvas.getContext("2d");
    ctx.scale(SCALE, SCALE);
    ctx.fillStyle = pageBg;
    ctx.fillRect(0, 0, W, H);
    ctx.drawImage(img, 0, 0, W, H);

    const title =
      (document.getElementById("t-heat") || {}).textContent ||
      "activity calendar";
    const slug = title
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "");
    triggerDownload(canvas, `cc-usage_${slug}.png`);
    toast(
      `H=${H} sparkBot=${_dbgSparkBottom} img=${img.naturalHeight} sh=${_dbgScrollH}`,
    );
  } catch (e) {
    console.error("[heatmap export]", e);
    toast("Couldn't export calendar");
  }
}

export function downloadChart(canvasId) {
  const chart = charts[canvasId];
  if (!chart) return;
  const src = chart.canvas;
  const out = document.createElement("canvas");
  out.width = src.width;
  out.height = src.height;
  const ctx = out.getContext("2d");
  ctx.fillStyle = cssVar("--paper-2", "#fffdf8");
  ctx.fillRect(0, 0, out.width, out.height);
  ctx.drawImage(src, 0, 0);
  const card = src.closest(".card");
  const titleEl = card && card.querySelector(".card-title");
  const slug = ((titleEl && titleEl.textContent) || canvasId)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  triggerDownload(out, `cc-usage_${slug}.png`);
}

export function wireShareButtons() {
  const share = document.getElementById("btn-share");
  if (share) share.addEventListener("click", openCardModal);
  document.querySelectorAll(".card").forEach((card) => {
    const cv = card.querySelector("canvas");
    if (!cv || !cv.id) return;
    const head = card.querySelector(".card-head");
    if (!head) return;
    const btn = document.createElement("button");
    btn.className = "chart-dl";
    btn.type = "button";
    btn.title = "Download PNG";
    btn.setAttribute("aria-label", "Download chart as PNG");
    btn.textContent = "⤓";
    btn.dataset.canvas = cv.id;
    btn.addEventListener("click", () => downloadChart(cv.id));
    head.appendChild(btn);
  });

  const metricSel = document.getElementById("heat-metric");
  if (metricSel && document.getElementById("heat")) {
    const btn = document.createElement("button");
    btn.className = "chart-dl heat-dl";
    btn.type = "button";
    btn.title = "Download PNG";
    btn.setAttribute("aria-label", "Download activity calendar as PNG");
    btn.textContent = "⤓";
    btn.addEventListener("click", downloadHeatmap);
    metricSel.parentElement.appendChild(btn);
  }
}
