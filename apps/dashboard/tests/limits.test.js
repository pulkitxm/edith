import { expect, test } from "bun:test";
import {
  downsampleLimits,
  parseLimitsJSONL,
  resetMarkers,
  sliceRange,
} from "../limits.mjs";

const H = 36e5;
const NOW = Date.parse("2026-07-04T12:00:00Z");
const iso = (t) => new Date(t).toISOString();
const line = (t, s, w, sr = null, wr = null) =>
  JSON.stringify({ ts: iso(t), s, w, sr: sr && iso(sr), wr: wr && iso(wr) });

test("parseLimitsJSONL skips garbage, sorts, converts to epoch ms", () => {
  const text = [
    line(NOW, 42.1, 67.3),
    "not json",
    "",
    line(NOW - H, 10, 20),
  ].join("\n");
  const rows = parseLimitsJSONL(text);
  expect(rows.length).toBe(2);
  expect(rows[0].t).toBe(NOW - H);
  expect(rows[1].s).toBe(42.1);
  expect(rows[0].sr).toBeNull();
});

test("downsampleLimits keeps recent raw, buckets older to hourly maxima", () => {
  const old = NOW - 8 * 864e5;
  const rows = parseLimitsJSONL(
    [
      line(old, 10, 5),
      line(old + 10 * 60e3, 30, 5),
      line(old + 20 * 60e3, 20, 8),
      line(NOW - H, 42, 67),
      line(NOW, 44, 67),
    ].join("\n"),
  );
  const out = downsampleLimits(rows, NOW);
  expect(out.length).toBe(3);
  expect(out[0].s).toBe(30);
  expect(out[0].w).toBe(8);
  expect(out[1].s).toBe(42);
});

test("sliceRange filters by window; null means all", () => {
  const pts = [{ t: NOW - 2 * 864e5 }, { t: NOW - H }, { t: NOW }];
  expect(sliceRange(pts, NOW, 864e5).length).toBe(2);
  expect(sliceRange(pts, NOW, null).length).toBe(3);
});

test("resetMarkers fires where a reset timestamp changes", () => {
  const sr1 = NOW + 3 * H,
    sr2 = NOW + 8 * H,
    wr = NOW + 5 * 864e5;
  const pts = parseLimitsJSONL(
    [
      line(NOW - 2 * H, 80, 50, sr1, wr),
      line(NOW - H, 5, 50, sr2, wr),
      line(NOW, 10, 51, sr2, wr),
    ].join("\n"),
  );
  const marks = resetMarkers(pts);
  expect(marks.length).toBe(1);
  expect(marks[0].kind).toBe("session");
  expect(marks[0].t).toBe(NOW - H);
});
