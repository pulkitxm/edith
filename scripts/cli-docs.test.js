import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

const root = "docs/cli";

const markdownFiles = (directory) =>
  readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return markdownFiles(path);
    return entry.name.endsWith(".md") ? [path] : [];
  });

const pages = new Map(
  markdownFiles(root).map((path) => [
    relative(root, path),
    readFileSync(path, "utf8"),
  ]),
);

const groups = [
  ...new Set(
    [...pages.keys()].flatMap((name) =>
      name.includes("/") ? [name.split("/")[0]] : [],
    ),
  ),
].sort();

const resolve = (link, page) => {
  const parts = page.split("/").slice(0, -1);
  for (const piece of link.split("/")) {
    if (piece === ".") continue;
    if (piece === "..") {
      parts.pop();
      continue;
    }
    parts.push(piece);
  }
  return parts.join("/");
};

test("every CLI documentation group is listed in the index", () => {
  const index = pages.get("README.md");
  expect(index).toBeDefined();
  const flat = [...pages.keys()].filter(
    (name) => !name.includes("/") && name !== "README.md",
  );
  const unlisted = [
    ...groups.filter((group) => !index.includes(`(./${group}/README.md)`)),
    ...flat.filter((name) => !index.includes(`(./${name})`)),
  ];
  expect(unlisted).toEqual([]);
});

test("every CLI command page is listed by its group", () => {
  const unlisted = [];
  for (const name of pages.keys()) {
    const parts = name.split("/");
    if (parts.length !== 2 || parts[1] === "README.md") continue;
    if (!pages.get(`${parts[0]}/README.md`)?.includes(`(./${parts[1]})`)) {
      unlisted.push(name);
    }
  }
  expect(unlisted).toEqual([]);
});

test("every CLI documentation page links back to its index", () => {
  const orphans = [...pages.entries()].flatMap(([name, text]) => {
    if (name === "README.md") return [];
    const back = name.includes("/") ? "(../README.md)" : "(./README.md)";
    return text.includes(back) ? [] : [name];
  });
  expect(orphans).toEqual([]);
});

test("every relative CLI documentation link resolves", () => {
  const broken = [];
  for (const [name, text] of pages) {
    for (const match of text.matchAll(/\]\((\.{1,2}\/[^)#\s]+\.md)/g)) {
      if (!pages.has(resolve(match[1], name)))
        broken.push(`${name} -> ${match[1]}`);
    }
  }
  expect(broken).toEqual([]);
});

test("every CLI documentation page opens with a title", () => {
  const untitled = [...pages.entries()].flatMap(([name, text]) => {
    const first = text.split("\n").find((line) => line.trim() !== "") ?? "";
    return first.startsWith("# ") ? [] : [name];
  });
  expect(untitled).toEqual([]);
});
