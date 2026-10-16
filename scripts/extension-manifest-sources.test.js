import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const packagedOutside = /\/(Tests|MCPTests|Sources|Native|NativeRuntime)\/|\/Package\.swift$/;

test("every packaged extension source is listed in the extension manifest", () => {
  const manifest = readFileSync("Extensions/manifest.json", "utf8");
  const sources = execFileSync("git", ["ls-files", "Extensions/*.swift"], {
    encoding: "utf8",
  })
    .split("\n")
    .filter((path) => path && !packagedOutside.test(path));
  expect(sources.length).toBeGreaterThan(0);
  expect(sources.filter((path) => !manifest.includes(`"${path}"`))).toEqual([]);
});
