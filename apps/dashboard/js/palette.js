import { ALL_MODELS, SOURCES } from "./data.js";

export let SOURCE_COLOR = { cli: "#2f4858", cowork: "#d97757" };
export const sourceColor = (s) => SOURCE_COLOR[s] || "#b8b0a4";

export const PALETTES = {
  light: {
    slate: "#2f4858",
    cat: [
      "#d97757",
      "#2f4858",
      "#c89b3c",
      "#6a8d73",
      "#8c5e58",
      "#4a6b8a",
      "#b07156",
      "#7d6b9e",
      "#9aa05c",
      "#5f7a7a",
    ],
  },
  dark: {
    slate: "#7ea7be",
    cat: [
      "#e08a6a",
      "#7ea7be",
      "#d8b04f",
      "#85ab8e",
      "#b07d74",
      "#6f97bd",
      "#c98a6c",
      "#9c8bc0",
      "#b3bb6e",
      "#7fa0a0",
    ],
  },
};
export const OTHER_COLOR = "#b8b0a4";
export let PALETTE, SLATE, TOKEN_COLORS;
export const MODEL_COLOR = {};

export function setPalette(theme) {
  const p = PALETTES[theme] || PALETTES.light;
  PALETTE = p.cat;
  SLATE = p.slate;
  TOKEN_COLORS = {
    input: p.slate,
    output: p.cat[0],
    cacheCreate: "#c89b3c",
    cacheRead: "#6a8d73",
  };
  SOURCE_COLOR = {};
  SOURCES.forEach(
    (s, i) =>
      (SOURCE_COLOR[s] = i === 0 ? p.slate : p.cat[(i - 1) % p.cat.length]),
  );
  ALL_MODELS.forEach((m, i) => (MODEL_COLOR[m] = PALETTE[i % PALETTE.length]));
}

export const systemTheme = (() => {
  try {
    return matchMedia("(prefers-color-scheme: dark)").matches
      ? "dark"
      : "light";
  } catch (_e) {
    return "light";
  }
})();
