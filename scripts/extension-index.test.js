import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  indexPath,
  orderedIndex,
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
  expect(validateDeclaration(declaration, "sample")).toBe(declaration);
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
