import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const root = "Packages/Edith/Sources";

const files = (directory) => {
  const found = [];
  for (const entry of readdirSync(directory)) {
    const path = join(directory, entry);
    if (entry === ".build" || entry === "checkouts") continue;
    const info = statSync(path);
    if (info.isDirectory()) found.push(...files(path));
    else if (path.endsWith(".swift")) found.push(path);
  }
  return found;
};

const sources = files(root);

test("shared database helpers stay in one file", () => {
  const copies = [];
  for (const path of sources) {
    if (path.endsWith("DatabaseOperationSupport.swift")) continue;
    const text = readFileSync(path, "utf8");
    if (text.includes("(100...599).contains(value) ? value : 500"))
      copies.push(path);
    if (text.includes("value.prefix(while: { $0.isNumber })"))
      copies.push(path);
  }
  expect(copies).toEqual([]);
});
