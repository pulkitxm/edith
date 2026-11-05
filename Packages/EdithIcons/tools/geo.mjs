import { createRequire } from "module";
const require = createRequire(import.meta.url);
delete globalThis.fetch;
const init = require("pathkit-wasm/bin/pathkit.js");
export const PK = await init({ locateFile: (f) => require.resolve("pathkit-wasm/bin/" + f) });

const K = 0.5522847498;
const SCALE = 64;
const big = (p) => { p.transform(SCALE, 0, 0, 0, SCALE, 0, 0, 0, 1); return p; };
const fromD = (d) => { const p = PK.FromSVGString(d); return p; };

const n = (v) => +v.toFixed(5);

function arcCubics(cx, cy, rx, ry, a0, a1) {
  const out = [];
  const total = a1 - a0;
  const segs = Math.max(1, Math.ceil(Math.abs(total) / 90 - 1e-9));
  const step = (total / segs) * Math.PI / 180;
  const k = (4 / 3) * Math.tan(step / 4);
  let a = a0 * Math.PI / 180;
  for (let i = 0; i < segs; i++) {
    const b = a + step;
    const x0 = Math.cos(a), y0 = Math.sin(a), x1 = Math.cos(b), y1 = Math.sin(b);
    out.push(`C${n(cx + rx * (x0 - k * y0))} ${n(cy + ry * (y0 + k * x0))} ${n(cx + rx * (x1 + k * y1))} ${n(cy + ry * (y1 - k * x1))} ${n(cx + rx * x1)} ${n(cy + ry * y1)}`);
    a = b;
  }
  return out.join("");
}
export const arcD = (cx, cy, r, a0, a1, start = true, ry = r) => {
  const x = cx + r * Math.cos(a0 * Math.PI / 180), y = cy + ry * Math.sin(a0 * Math.PI / 180);
  return `${start ? "M" : "L"}${n(x)} ${n(y)}` + arcCubics(cx, cy, r, ry, a0, a1);
};

export const P = (d) => big(fromD(d));
export const E = (cx, cy, rx, ry = rx) => P(arcD(cx, cy, rx, 0, 360, true, ry) + "Z");
export const C = E;
export const R = (x, y, w, h, r = 0) => {
  const [a, b, c, d] = Array.isArray(r) ? r : [r, r, r, r];
  let s = `M${x + a} ${y}L${x + w - b} ${y}`;
  if (b) s += arcCubics(x + w - b, y + b, b, b, -90, 0);
  s += `L${x + w} ${y + h - c}`;
  if (c) s += arcCubics(x + w - c, y + h - c, c, c, 0, 90);
  s += `L${x + d} ${y + h}`;
  if (d) s += arcCubics(x + d, y + h - d, d, d, 90, 180);
  s += `L${x} ${y + a}`;
  if (a) s += arcCubics(x + a, y + a, a, a, 180, 270);
  return P(s + "Z");
};
export const Poly = (pts, r = 0) => {
  const m = pts.length;
  if (!r) return P("M" + pts.map((p) => p.join(" ")).join("L") + "Z");
  const rs = Array.isArray(r) ? r : pts.map(() => r);
  let s = "";
  for (let i = 0; i < m; i++) {
    const p = pts[i], a = pts[(i - 1 + m) % m], b = pts[(i + 1) % m];
    const v1 = [a[0] - p[0], a[1] - p[1]], v2 = [b[0] - p[0], b[1] - p[1]];
    const l1 = Math.hypot(...v1), l2 = Math.hypot(...v2);
    const u1 = [v1[0] / l1, v1[1] / l1], u2 = [v2[0] / l2, v2[1] / l2];
    const cos = u1[0] * u2[0] + u1[1] * u2[1];
    const ang = Math.acos(Math.max(-1, Math.min(1, cos)));
    const rad = rs[i];
    if (!rad) { s += (i ? "L" : "M") + `${n(p[0])} ${n(p[1])}`; continue; }
    const t = rad / Math.tan(ang / 2);
    const p1 = [p[0] + u1[0] * t, p[1] + u1[1] * t], p2 = [p[0] + u2[0] * t, p[1] + u2[1] * t];
    const sweep = Math.PI - ang;
    const k = (4 / 3) * Math.tan(sweep / 4) * rad;
    const c1 = [p1[0] - u1[0] * k, p1[1] - u1[1] * k], c2 = [p2[0] - u2[0] * k, p2[1] - u2[1] * k];
    s += (i ? "L" : "M") + `${n(p1[0])} ${n(p1[1])}C${n(c1[0])} ${n(c1[1])} ${n(c2[0])} ${n(c2[1])} ${n(p2[0])} ${n(p2[1])}`;
  }
  return P(s + "Z");
};
export const S = (d, width, { cap = "butt", join = "miter", miter = 8 } = {}) => {
  const p = P(d);
  p.stroke({
    width: width * SCALE, miter_limit: miter,
    cap: { butt: PK.StrokeCap.BUTT, round: PK.StrokeCap.ROUND, square: PK.StrokeCap.SQUARE }[cap],
    join: { miter: PK.StrokeJoin.MITER, round: PK.StrokeJoin.ROUND, bevel: PK.StrokeJoin.BEVEL }[join],
    res_scale: 8,
  });
  p.simplify();
  return p;
};
export const U = (...ps) => {
  const list = ps.flat().filter(Boolean);
  const r = list[0].copy();
  for (const q of list.slice(1)) r.op(q, PK.PathOp.UNION);
  r.simplify();
  return r;
};
export const minus = (a, ...bs) => {
  const r = a.copy();
  for (const q of bs.flat().filter(Boolean)) r.op(q, PK.PathOp.DIFFERENCE);
  return r;
};
export const inter = (a, b) => { const r = a.copy(); r.op(b, PK.PathOp.INTERSECT); return r; };
export const grow = (p, d, join = "miter") => {
  const o = p.copy();
  o.stroke({ width: 2 * d * SCALE, miter_limit: 8, join: join === "round" ? PK.StrokeJoin.ROUND : PK.StrokeJoin.MITER, cap: PK.StrokeCap.BUTT, res_scale: 8 });
  o.simplify();
  o.setFillType?.(PK.FillType.WINDING);
  const r = U(o, p);
  return r;
};
export const T = (p, dx, dy) => { const q = p.copy(); q.transform(1, 0, dx * SCALE, 0, 1, dy * SCALE, 0, 0, 1); return q; };
export const rot = (p, deg, cx, cy) => {
  const a = deg * Math.PI / 180, c = Math.cos(a), s = Math.sin(a);
  const X = cx * SCALE, Y = cy * SCALE;
  const q = p.copy();
  q.transform(c, -s, X - c * X + s * Y, s, c, Y - s * X - c * Y, 0, 0, 1);
  return q;
};

export const flip = (p, grid, x = true, y = false) => {
  const sx = x ? -1 : 1, sy = y ? -1 : 1, c = (grid / 2) * SCALE;
  const q = p.copy();
  q.transform(sx, 0, x ? 2 * c : 0, 0, sy, y ? 2 * c : 0, 0, 0, 1);
  return q;
};

const fmt = (v) => {
  const u = v / SCALE;
  const snapped = Math.abs(u - Math.round(u * 8) / 8) < 0.004 ? Math.round(u * 8) / 8 : u;
  return String(+snapped.toFixed(3));
};
export const toD = (p) => {
  const out = [];
  for (const c of p.toCmds()) {
    const [v, ...a] = c;
    const s = a.map(fmt).join(" ");
    if (v === PK.MOVE_VERB) out.push("M" + s);
    else if (v === PK.LINE_VERB) out.push("L" + s);
    else if (v === PK.QUAD_VERB) out.push("Q" + s);
    else if (v === PK.CUBIC_VERB) out.push("C" + s);
    else if (v === PK.CLOSE_VERB) out.push("Z");
    else throw new Error("verb " + v);
  }
  return out.join("");
};

export const bake = ({ back = [], front = [], cut = [], backCut = [], slit = 1 }) => {
  const f = front.length ? U(front) : null;
  const fr = f && cut.length ? minus(f, cut) : f;
  let b = back.length ? U(back) : null;
  if (b && f && slit) b = minus(b, grow(f, slit));
  if (b && backCut.length) b = minus(b, backCut);
  return { primary: fr ? toD(fr) : "", secondary: b ? toD(b) : "" };
};
export const svg = ({ primary, secondary }, grid, opacity = 0.4) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${grid} ${grid}" fill="currentColor">\n` +
  (secondary ? `  <path id="secondary" fill-rule="evenodd" opacity="${opacity}" d="${secondary}"/>\n` : "") +
  (primary ? `  <path id="primary" fill-rule="evenodd" d="${primary}"/>\n` : "") + `</svg>\n`;
