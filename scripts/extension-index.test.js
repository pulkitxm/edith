import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  indexPath,
  orderedIndex,
  parseShortcut,
  renderIndex,
  validateDeclaration,
} from "./extension-index.mjs";

const declaration = {
  id: "sample",
  title: "Sample",
  symbolName: "square",
  category: "desk",
  background: false,
  commands: ["sample"],
};

test("the committed host index matches every extension declaration", async () => {
  expect(await renderIndex()).toBe(readFileSync(indexPath, "utf8"));
});

test("declarations reject unknown keys, mismatched ids and invalid commands", () => {
  expect(validateDeclaration(declaration, "sample")).toEqual({
    ...declaration,
    launchWhen: [],
    hotkeys: [],
    pages: [],
    sections: [],
    homeCards: [],
    notchCards: [],
    notchTabs: [],
  });
  for (const [value, directory] of [
    [{ ...declaration, hotkey: "x" }, "sample"],
    [declaration, "other"],
    [{ ...declaration, category: "games" }, "sample"],
    [{ ...declaration, background: "yes" }, "sample"],
    [{ ...declaration, commands: ["Sample"] }, "sample"],
    [{ ...declaration, commands: ["sample", "sample"] }, "sample"],
    [{ ...declaration, title: "" }, "sample"],
  ])
    expect(() => validateDeclaration(value, directory)).toThrow();
});

test("the index keeps category order and the previous order within a category", () => {
  const entry = (id, category) => ({ ...declaration, id, category });
  expect(
    orderedIndex(
      [
        entry("zeta", "desk"),
        entry("new", "desk"),
        entry("alpha", "desk"),
        entry("first", "agents"),
      ],
      [{ id: "zeta" }, { id: "alpha" }],
    ).map(({ id }) => id),
  ).toEqual(["first", "zeta", "alpha", "new"]);
});

test("shortcuts render Carbon codes, modifiers and a label", () => {
  expect(parseShortcut("control+shift+e", "emoji")).toEqual({
    code: 14,
    modifiers: 4608,
    label: "⌃⇧E",
  });
  expect(parseShortcut("option+space", "bifrost").label).toBe("⌥␣");
  for (const invalid of ["e", "control+f13", "control+control+e", "hyper+e"])
    expect(() => parseShortcut(invalid, "sample")).toThrow();
});

test("launch conditions need a key and a boolean default and exclude background", () => {
  const conditional = {
    ...declaration,
    launchWhen: [{ key: "sampleActive", default: false }],
  };
  expect(validateDeclaration(conditional, "sample").launchWhen).toEqual([
    { key: "sampleActive", default: false },
  ]);
  for (const launchWhen of [
    [{ key: "sampleActive" }],
    [{ key: "", default: true }],
    [{ key: "sampleActive", default: true, extra: 1 }],
  ])
    expect(() =>
      validateDeclaration({ ...declaration, launchWhen }, "sample"),
    ).toThrow();
  expect(() =>
    validateDeclaration({ ...conditional, background: true }, "sample"),
  ).toThrow();
});

test("pages default to detachable and sections name a known page", () => {
  const paged = {
    ...declaration,
    category: "agents",
    pages: [
      { id: "samplePage", title: "Sample", symbolName: "star", order: 1 },
    ],
    sections: [
      {
        page: "appMaintenance",
        id: "Sample",
        title: "Sample",
        symbolName: "star",
        summary: "A synthetic section.",
        order: 1,
      },
    ],
  };
  const validated = validateDeclaration(paged, "sample");
  expect(validated.pages).toEqual([
    {
      id: "samplePage",
      title: "Sample",
      symbolName: "star",
      order: 1,
      detachable: true,
    },
  ]);
  expect(validated.sections).toEqual(paged.sections);
  for (const pages of [
    [{ id: "samplePage", title: "Sample", symbolName: "star" }],
    [{ id: "samplePage", title: "Sample", symbolName: "star", order: 1.5 }],
    [
      {
        id: "samplePage",
        title: "Sample",
        symbolName: "star",
        order: 1,
        extra: 1,
      },
    ],
    [
      {
        id: "samplePage",
        title: "Sample",
        symbolName: "star",
        order: 1,
        detachable: "no",
      },
    ],
  ])
    expect(() => validateDeclaration({ ...paged, pages }, "sample")).toThrow();
  expect(() =>
    validateDeclaration(
      {
        ...paged,
        sections: [{ ...paged.sections[0], page: "settings" }],
      },
      "sample",
    ),
  ).toThrow();
  expect(() =>
    validateDeclaration({ ...paged, category: "desk" }, "sample"),
  ).toThrow();
});

test("surface declarations register independent Home cards, Notch cards and tabs", () => {
  const surfaces = {
    ...declaration,
    homeCards: ["music", "extension:sample"],
    notchCards: ["actions"],
    notchTabs: ["audio"],
  };
  const validated = validateDeclaration(surfaces, "sample");
  expect(validated.homeCards).toEqual(surfaces.homeCards);
  expect(validated.notchCards).toEqual(surfaces.notchCards);
  expect(validated.notchTabs).toEqual(surfaces.notchTabs);
  for (const field of ["homeCards", "notchCards", "notchTabs"])
    for (const value of ["music", ["unknown"], ["music", "music"], [null]])
      expect(() =>
        validateDeclaration({ ...surfaces, [field]: value }, "sample"),
      ).toThrow();
  expect(() =>
    validateDeclaration(
      { ...surfaces, homeCards: ["extension:other"] },
      "sample",
    ),
  ).toThrow();
});
