import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  indexPath,
  orderedIndex,
  parseShortcut,
  renderIndex,
  sidebarGroups,
  validateDeclaration,
} from "./extension-index.mjs";

const declaration = {
  id: "sample",
  title: "Sample",
  icon: "appTile",
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

test("a page takes its title, icon and group from the extension itself", () => {
  const paged = { ...declaration, category: "utilities", page: true };
  expect(validateDeclaration(paged, "sample").page).toEqual({
    detachable: true,
  });
  expect(
    validateDeclaration({ ...paged, page: { detachable: false } }, "sample")
      .page,
  ).toEqual({ detachable: false });
  expect("page" in validateDeclaration(declaration, "sample")).toBe(false);
  for (const [page, reason] of [
    [{ title: "Packages" }, "title must not be set"],
    [{ title: "Sample" }, "title must not be set"],
    [{ icon: "bookmark" }, "icon must not be set"],
    [{ id: "samplePage" }, "id must not be set"],
    [{ order: 1 }, "order must not be set"],
    [{ group: "appMaintenance" }, "group must not be set"],
    [{ parent: "appMaintenance" }, "parent must not be set"],
    [{ category: "agents" }, "category must not be set"],
    [{ detachable: "no" }, "detachable must be a boolean"],
    [{ logoName: "sample" }, "unknown keys logoName"],
    [{ extra: 1 }, "unknown keys extra"],
    [false, "must be true or an object"],
    [[{}], "must be true or an object"],
  ])
    expect(() => validateDeclaration({ ...paged, page }, "sample")).toThrow(
      reason,
    );
  for (const category of ["desk", "labs"])
    expect(() => validateDeclaration({ ...paged, category }, "sample")).toThrow(
      `${category} extensions have no sidebar group`,
    );
  expect(() =>
    validateDeclaration(
      {
        ...paged,
        pages: [{ id: "sample", title: "Packages", icon: "box", order: 1 }],
      },
      "sample",
    ),
  ).toThrow("pages is not supported");
  expect(() =>
    validateDeclaration(
      {
        ...paged,
        sections: [
          {
            page: "appMaintenance",
            id: "Packages",
            title: "Packages",
            icon: "box",
            summary: "A synthetic section.",
            order: 1,
          },
        ],
      },
      "sample",
    ),
  ).toThrow("sections is not supported");
});

test("every bundled page belongs to a sidebar group and no page id collides with a built-in page", async () => {
  const index = JSON.parse(await renderIndex());
  for (const entry of index.filter((item) => item.page))
    expect(sidebarGroups).toContain(entry.category);
  for (const entry of index) {
    expect(Object.keys(entry)).not.toContain("pages");
    expect(Object.keys(entry)).not.toContain("sections");
  }
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
