#!/usr/bin/env bun
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, relative, sep } from "node:path";

export const docsRoot = "docs/cli";
export const bundlePath =
  "Packages/Edith/Sources/EdithKit/Resources/cli-docs.json";

export const parseArguments = (arguments_) => {
  const options = { check: false };
  for (const flag of arguments_) {
    if (flag !== "--check") throw new Error(`unknown flag: ${flag}`);
    options.check = true;
  }
  return options;
};

const markdownFiles = (directory) =>
  readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    if (entry.name.startsWith("._")) return [];
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return markdownFiles(path);
    return entry.name.endsWith(".md") ? [path] : [];
  });

export const collectPages = (root = docsRoot) =>
  markdownFiles(root)
    .map((path) => ({
      path: relative(root, path).split(sep).join("/"),
      markdown: readFileSync(path, "utf8"),
    }))
    .sort((left, right) => (left.path < right.path ? -1 : 1));

export const renderBundle = (pages) =>
  `[\n${pages.map((page) => JSON.stringify(page)).join(",\n")}\n]\n`;

if (import.meta.main) {
  const options = parseArguments(process.argv.slice(2));
  const expected = renderBundle(collectPages());
  if (options.check) {
    const current = existsSync(bundlePath)
      ? readFileSync(bundlePath, "utf8")
      : "";
    if (current !== expected) {
      process.stderr.write(
        `${bundlePath} is out of date; run bun scripts/generate-cli-docs-bundle.mjs\n`,
      );
      process.exit(1);
    }
  } else {
    writeFileSync(bundlePath, expected);
    process.stderr.write(`wrote ${bundlePath}\n`);
  }
}
