import { expect, test } from "bun:test";
import { cycleEnd, cycleStart, cyclesFromBounds } from "../js/cycles.js";

const d = (s) => {
  const [y, m, day] = s.split("-").map(Number);
  return new Date(y, m - 1, day);
};
const iso = (dt) =>
  `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, "0")}-${String(dt.getDate()).padStart(2, "0")}`;

test("cycleStart: before/on/after the billing day", () => {
  expect(iso(cycleStart(d("2026-06-06"), 26))).toBe("2026-05-26");
  expect(iso(cycleStart(d("2026-06-26"), 26))).toBe("2026-06-26");
  expect(iso(cycleStart(d("2026-06-30"), 26))).toBe("2026-06-26");
});

test("cycleStart: crosses year boundary backwards", () => {
  expect(iso(cycleStart(d("2026-01-06"), 26))).toBe("2025-12-26");
});

test("cycleStart: clamps when the month is shorter than the billing day", () => {
  expect(iso(cycleStart(d("2026-02-15"), 31))).toBe("2026-01-31");
  expect(iso(cycleStart(d("2026-03-01"), 31))).toBe("2026-02-28");
});

test("cycleEnd: day before the next anchor, inclusive", () => {
  expect(iso(cycleEnd(d("2026-05-26"), 26))).toBe("2026-06-25");
  expect(iso(cycleEnd(d("2025-12-26"), 26))).toBe("2026-01-25");
  expect(iso(cycleEnd(d("2026-01-31"), 31))).toBe("2026-02-27");
});

test("cyclesFromBounds: newest-first list with labels", () => {
  const cs = cyclesFromBounds(d("2026-05-01"), d("2026-06-06"), 26);
  expect(cs.map((c) => c.start)).toEqual(["2026-05-26", "2026-04-26"]);
  expect(cs[0]).toEqual({
    start: "2026-05-26",
    end: "2026-06-25",
    label: "26 May – 25 Jun 2026",
  });
});

test("cyclesFromBounds: labels show both years when a cycle spans New Year", () => {
  const cs = cyclesFromBounds(d("2025-12-30"), d("2026-01-02"), 26);
  expect(cs[0].label).toBe("26 Dec 2025 – 25 Jan 2026");
});
