import { expect, test } from "bun:test";
import {
  buildCatalog,
  loadCatalog,
  parseArguments,
} from "./generate-emoji-catalog.mjs";

const fixture = {
  data: [
    {
      label: "Grinning Face",
      hexcode: "1F600",
      emoji: "😀",
      tags: ["grinning face", "smile", "happy"],
      order: 2,
      group: 0,
      version: 1,
    },
    {
      label: "Thumbs Up",
      hexcode: "1F44D",
      emoji: "👍️",
      tags: ["thumb", "+1"],
      order: 1,
      group: 1,
      version: 0.6,
      skins: [
        { emoji: "👍🏿", tone: 5 },
        { emoji: "👍🏻", tone: 1 },
        { emoji: "👩🏻‍🤝‍👩🏿", tone: [1, 5] },
      ],
    },
    {
      label: "Light Skin Tone",
      hexcode: "1F3FB",
      emoji: "🏻",
      order: 3,
      group: 2,
      version: 1,
    },
  ],
  shortcodes: { "1F600": ["grinning"], "1F44D": "thumbsup" },
  sourceVersion: "emojibase-data@17.0.0",
};

test("emoji catalog arguments require an output path", () => {
  expect(parseArguments(["--output", "/tmp/emoji.json"])).toEqual({
    output: "/tmp/emoji.json",
  });
  expect(() => parseArguments([])).toThrow("--output needs a path");
  expect(() => parseArguments(["--verbose"])).toThrow(
    "unknown flag: --verbose",
  );
});

test("emoji catalog drops components and sorts by unicode order", () => {
  const catalog = buildCatalog(fixture);
  expect(catalog.schema).toBe(1);
  expect(catalog.source).toBe("emojibase-data@17.0.0");
  expect(catalog.emoji.map((entry) => entry.e)).toEqual(["👍️", "😀"]);
  expect(catalog.groups[catalog.emoji[0].g].id).toBe("people-body");
});

test("emoji catalog keeps single skin tones in light to dark order", () => {
  const catalog = buildCatalog(fixture);
  const thumbsUp = catalog.emoji.find((entry) => entry.n === "thumbs up");
  expect(thumbsUp.s).toEqual(["👍🏻", "👍🏿"]);
  expect(catalog.emoji.find((entry) => entry.n === "grinning face").s).toBe(
    undefined,
  );
});

test("emoji catalog search terms exclude words already in the name", () => {
  const catalog = buildCatalog(fixture);
  const grinning = catalog.emoji.find((entry) => entry.n === "grinning face");
  expect(grinning.t).toEqual(["happy", "smile"]);
  expect(catalog.emoji.find((entry) => entry.n === "thumbs up").t).toEqual([
    "+1",
    "thumb",
    "thumbsup",
  ]);
});

test("emoji catalog covers every group with a real data set", () => {
  const catalog = loadCatalog();
  expect(catalog.emoji.length).toBeGreaterThan(1500);
  expect(catalog.groups).toHaveLength(9);
  const used = new Set(catalog.emoji.map((entry) => entry.g));
  expect(used.size).toBe(catalog.groups.length);
  expect(catalog.emoji.every((entry) => typeof entry.v === "number")).toBe(
    true,
  );
  expect(new Set(catalog.emoji.map((entry) => entry.e)).size).toBe(
    catalog.emoji.length,
  );
});
