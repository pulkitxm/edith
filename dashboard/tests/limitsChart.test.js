import { expect, test } from "bun:test";

globalThis.__constructed = [];
globalThis.Chart = class {
  constructor(el, cfg) {
    globalThis.__constructed.push({ el, cfg });
  }
  destroy() {}
};
globalThis.Chart.defaults = { font: {}, color: undefined };
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "" });
globalThis.matchMedia = () => ({ matches: false });
globalThis.document = {
  body: {},
  getElementById: () => null,
  querySelectorAll: () => [],
};

const { initLimitsCard } = await import("../js/limitsChart.js");

function makeDOM(limitsJSON) {
  const el = (extra = {}) => ({
    style: {},
    setAttribute() {},
    addEventListener() {},
    ...extra,
  });
  const card = el();
  const canvas = el({ id: "c-limits" });
  globalThis.document.getElementById = (id) =>
    id === "limits-card"
      ? card
      : id === "c-limits"
        ? canvas
        : id === "limits-data"
          ? limitsJSON == null
            ? null
            : { textContent: limitsJSON }
          : el();
  globalThis.document.querySelectorAll = () => [];
  globalThis.__constructed.length = 0;
  return { card, canvas, constructed: globalThis.__constructed };
}

test("no limits-data block: card is hidden and no chart is constructed", () => {
  const { card, constructed } = makeDOM(null);
  initLimitsCard();
  expect(card.style.display).toBe("none");
  expect(constructed.length).toBe(0);
});

test("limits-data with points: card stays visible and a 2-dataset stepped chart mounts", () => {
  const now = Date.parse("2026-07-04T12:00:00Z");
  const points = [
    { t: now - 36e5, s: 10, w: 20 },
    { t: now, s: 15, w: 25 },
  ];
  const { card, canvas, constructed } = makeDOM(JSON.stringify({ points }));

  initLimitsCard();

  expect(card.style.display).not.toBe("none");
  expect(constructed.length).toBe(1);
  expect(constructed[0].el).toBe(canvas);
  const datasets = constructed[0].cfg.data.datasets;
  expect(datasets.length).toBe(2);
  expect(datasets[0].label).toBe("Session (5h)");
  expect(datasets[1].label).toBe("Weekly");
  for (const ds of datasets) expect(ds.stepped).toBe(true);
});
