#!/usr/bin/env bun
import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";

const require_ = createRequire(import.meta.url);

const COMPONENT_GROUP = 2;

const GROUPS = [
  { id: "smileys-emotion", name: "Smileys", symbol: "face.smiling" },
  { id: "people-body", name: "People", symbol: "hand.wave" },
  { id: "animals-nature", name: "Nature", symbol: "leaf" },
  { id: "food-drink", name: "Food", symbol: "fork.knife" },
  { id: "travel-places", name: "Travel", symbol: "airplane" },
  { id: "activities", name: "Activities", symbol: "soccerball" },
  { id: "objects", name: "Objects", symbol: "lightbulb" },
  { id: "symbols", name: "Symbols", symbol: "number" },
  { id: "flags", name: "Flags", symbol: "flag" },
];

export const parseArguments = (arguments_) => {
  const options = { output: null };
  for (let index = 0; index < arguments_.length; index += 1) {
    const flag = arguments_[index];
    if (flag !== "--output") throw new Error(`unknown flag: ${flag}`);
    options.output = arguments_[index + 1];
    index += 1;
  }
  if (!options.output) throw new Error("--output needs a path");
  return options;
};

const searchTerms = (entry, shortcodes) => {
  const codes = shortcodes[entry.hexcode];
  const list = Array.isArray(codes) ? codes : codes ? [codes] : [];
  const terms = new Set();
  for (const tag of entry.tags ?? []) terms.add(tag.toLowerCase());
  for (const code of list) terms.add(code.replaceAll("_", " ").toLowerCase());
  const label = entry.label.toLowerCase();
  terms.delete(label);
  for (const word of label.split(/[^a-z0-9+]+/)) {
    if (word) terms.delete(word);
  }
  return [...terms].sort();
};

const skinTones = (entry) =>
  (entry.skins ?? [])
    .filter((skin) => typeof skin.tone === "number")
    .sort((a, b) => a.tone - b.tone)
    .map((skin) => skin.emoji);

export const buildCatalog = ({ data, shortcodes, sourceVersion }) => {
  const groupIndexByEmojibaseGroup = new Map();
  const emojibaseGroups = require_("emojibase-data/meta/groups.json").groups;
  for (const [key, id] of Object.entries(emojibaseGroups)) {
    const index = GROUPS.findIndex((group) => group.id === id);
    if (index >= 0) groupIndexByEmojibaseGroup.set(Number(key), index);
  }

  const emoji = data
    .filter(
      (entry) => entry.group !== undefined && entry.group !== COMPONENT_GROUP,
    )
    .filter((entry) => groupIndexByEmojibaseGroup.has(entry.group))
    .sort((a, b) => a.order - b.order)
    .map((entry) => {
      const tones = skinTones(entry);
      const terms = searchTerms(entry, shortcodes);
      const record = {
        e: entry.emoji,
        n: entry.label.toLowerCase(),
        g: groupIndexByEmojibaseGroup.get(entry.group),
        v: entry.version,
      };
      if (terms.length > 0) record.t = terms;
      if (tones.length > 0) record.s = tones;
      return record;
    });

  return { schema: 1, source: sourceVersion, groups: GROUPS, emoji };
};

export const loadCatalog = () =>
  buildCatalog({
    data: require_("emojibase-data/en/data.json"),
    shortcodes: require_("emojibase-data/en/shortcodes/cldr.json"),
    sourceVersion: `emojibase-data@${require_("emojibase-data/package.json").version}`,
  });

if (import.meta.main) {
  const options = parseArguments(process.argv.slice(2));
  const catalog = loadCatalog();
  writeFileSync(options.output, `${JSON.stringify(catalog)}\n`);
  process.stderr.write(
    `wrote ${catalog.emoji.length} emoji from ${catalog.source} to ${options.output}\n`,
  );
}
