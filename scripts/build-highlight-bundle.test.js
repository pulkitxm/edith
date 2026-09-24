import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  entrySource,
  languages,
  licenseHeader,
} from "./build-highlight-bundle.mjs";

test("registers every listed language once from the given package", () => {
  const source = entrySource("/tmp/highlight.js");
  expect(new Set(languages).size).toBe(languages.length);
  for (const name of languages) {
    expect(source).toContain(`/tmp/highlight.js/lib/languages/${name}.js`);
    expect(source).toContain(`hljs.registerLanguage("${name}"`);
  }
  expect(source).toContain("globalThis.hljs = hljs;");
});

test("keeps the file preview languages and the license notice", () => {
  for (const name of ["swift", "markdown", "javascript", "python", "bash"]) {
    expect(languages).toContain(name);
  }
  const bundle = readFileSync(
    resolve(
      import.meta.dir,
      "../Packages/Edith/Vendor/Highlighter/Resources/highlight.min.js",
    ),
    "utf8",
  );
  expect(bundle.startsWith(licenseHeader("11.11.1"))).toBe(true);
});
