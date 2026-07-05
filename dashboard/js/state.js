import { DEFAULT_MODELS, DEFAULT_SOURCES } from "./data.js";
import { systemTheme } from "./palette.js";

export const DEFAULT_BILLING_DAY = 26;
export const state = {
  range: { mode: "all" },
  billingDay: DEFAULT_BILLING_DAY,
  models: new Set(DEFAULT_MODELS),
  sources: new Set(DEFAULT_SOURCES),
  theme: systemTheme,
  sort: { key: "cost", dir: -1 },
  projSort: { key: "cost", dir: -1 },
  projListOpen: false,
  projExpanded: new Set(),
};

export const charts = {};
