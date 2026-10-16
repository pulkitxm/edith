import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  bundlePath,
  collectPages,
  parseArguments,
  renderBundle,
} from "./generate-cli-docs-bundle.mjs";

test("docs bundle arguments accept only --check", () => {
  expect(parseArguments([])).toEqual({ check: false });
  expect(parseArguments(["--check"])).toEqual({ check: true });
  expect(() => parseArguments(["--write"])).toThrow("unknown flag: --write");
});

test("docs bundle renders one sorted page per line", () => {
  const rendered = renderBundle([
    { path: "a.md", markdown: "# A\n" },
    { path: "b/README.md", markdown: "# B\n" },
  ]);
  expect(rendered.split("\n")).toHaveLength(5);
  expect(JSON.parse(rendered).map((page) => page.path)).toEqual([
    "a.md",
    "b/README.md",
  ]);
});

test("the committed docs bundle matches docs/cli", () => {
  const pages = collectPages();
  expect(pages.length).toBeGreaterThan(300);
  expect(pages.map((page) => page.path)).toContain("README.md");
  expect(readFileSync(bundlePath, "utf8")).toBe(renderBundle(pages));
});
