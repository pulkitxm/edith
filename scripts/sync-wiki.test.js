import { expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildPages, collect, mapTarget, rewriteLinks } from "./sync-wiki.mjs";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

const docs = collect();
const slugMap = new Map(docs.map((d) => [d.src, d.slug]));
const dirMap = new Map([
  ["docs/cli", "CLI"],
  ["docs", "Guides"],
]);
for (const doc of docs) {
  if (doc.isGroup) dirMap.set(path.posix.dirname(doc.src), doc.slug);
}
const options = {
  root: repoRoot,
  slugMap,
  dirMap,
  blobBase: "https://github.com/pulkitxm/edith/blob/main",
};

function markdownUnder(dir) {
  let count = 0;
  for (const entry of readdirSync(path.join(repoRoot, dir), {
    withFileTypes: true,
  })) {
    if (entry.isDirectory()) count += markdownUnder(`${dir}/${entry.name}`);
    else if (entry.name.endsWith(".md")) count += 1;
  }
  return count;
}

test("every markdown file under docs becomes a page", () => {
  expect(docs.length).toBe(markdownUnder("docs"));
});

test("a top level doc becomes a guide page", () => {
  const internals = docs.find((d) => d.src === "docs/homebrew-internals.md");
  expect(internals.slug).toBe("Guides-Homebrew-Internals");
  expect(internals.section).toBe("Guides");
  expect(internals.depth).toBe(0);
});

test("guides link to each other by slug", () => {
  expect(mapTarget("homebrew-internals.md", "docs", options)).toBe(
    "Guides-Homebrew-Internals",
  );
  expect(mapTarget("homebrew.md", "docs", options)).toBe("Guides-Homebrew");
});

test("a command page nests under its group", () => {
  const ps = docs.find((d) => d.src === "docs/cli/machines-docker/ps.md");
  expect(ps.slug).toBe("CLI-Machines-Docker-Ps");
  expect(ps.depth).toBe(1);
  expect(ps.parent).toBe("CLI-Machines-Docker");
});

test("a group README keeps the group slug", () => {
  const group = docs.find(
    (d) => d.src === "docs/cli/machines-docker/README.md",
  );
  expect(group.slug).toBe("CLI-Machines-Docker");
  expect(group.isGroup).toBe(true);
  expect(group.depth).toBe(0);
});

test("the index page is the section slug and comes first", () => {
  const index = docs.find((d) => d.src === "docs/cli/README.md");
  expect(index.slug).toBe("CLI");
  expect(index.isIndex).toBe(true);
  expect(index.order).toBe(-1);
});

test("page slugs are prefixed and title cased", () => {
  const conventions = docs.find((d) => d.src === "docs/cli/conventions.md");
  expect(conventions.slug).toBe("CLI-Conventions");
  expect(conventions.title).toBe("Conventions");
});

test("slugs are unique", () => {
  const slugs = docs.map((d) => d.slug);
  expect(new Set(slugs).size).toBe(slugs.length);
});

test("sibling doc links become wiki slugs", () => {
  expect(mapTarget("./conventions.md", "docs/cli", options)).toBe(
    "CLI-Conventions",
  );
  expect(mapTarget("./README.md", "docs/cli", options)).toBe("CLI");
});

test("a group directory link resolves to the group page", () => {
  expect(mapTarget("./config/README.md", "docs/cli", options)).toBe(
    "CLI-Config",
  );
  expect(mapTarget("../machines/README.md", "docs/cli/usage", options)).toBe(
    "CLI-Machines",
  );
});

test("a link between siblings in a group resolves", () => {
  expect(mapTarget("./daily.md", "docs/cli/usage", options)).toBe(
    "CLI-Usage-Daily",
  );
  expect(mapTarget("./README.md", "docs/cli/usage", options)).toBe("CLI-Usage");
});

test("anchors and link titles survive rewriting", () => {
  expect(mapTarget("./daily.md#examples", "docs/cli/usage", options)).toBe(
    "CLI-Usage-Daily#examples",
  );
});

test("external and anchor-only links are left alone", () => {
  expect(mapTarget("https://example.com", "docs/cli", options)).toBeNull();
  expect(mapTarget("#install", "docs/cli", options)).toBeNull();
  expect(
    mapTarget("mailto:someone@example.com", "docs/cli", options),
  ).toBeNull();
});

test("links to repo files outside docs become blob urls", () => {
  expect(mapTarget("../../README.md", "docs/cli", options)).toBe(
    "https://github.com/pulkitxm/edith/blob/main/README.md",
  );
});

test("links inside fenced blocks are not rewritten", () => {
  const source = [
    "```",
    "[a](./conventions.md)",
    "```",
    "[b](./conventions.md)",
  ].join("\n");
  const rewritten = rewriteLinks(source, "docs/cli", options);
  expect(rewritten).toContain("[a](./conventions.md)");
  expect(rewritten).toContain("[b](CLI-Conventions)");
});

test("wiki build emits Home, sidebar and footer", () => {
  const pages = buildPages();
  expect(pages.has("Home.md")).toBe(true);
  expect(pages.has("_Sidebar.md")).toBe(true);
  expect(pages.has("_Footer.md")).toBe(true);
  expect(pages.has("CLI.md")).toBe(true);
});

test("the sidebar lists getting started before the machine pages", () => {
  const sidebar = buildPages().get("_Sidebar.md");
  expect(sidebar.indexOf("CLI-Getting-Started")).toBeLessThan(
    sidebar.indexOf("CLI-Machines-Docker"),
  );
});

test("every page ends with exactly one newline", () => {
  for (const [name, content] of buildPages()) {
    expect(content.endsWith("\n")).toBe(true);
    expect(content.endsWith("\n\n")).toBe(false);
    expect(name.endsWith(".md")).toBe(true);
  }
});
