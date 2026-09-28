import { expect, test } from "bun:test";
import { checkDatabaseSizes } from "./check-database-size.mjs";

const budget = { maxLines: 3, exceptions: { "Existing.swift": 5 } };
const file = (path, count) => ({ path, text: "line\n".repeat(count) });

test("new database files cannot grow past the component budget", () => {
  expect(checkDatabaseSizes([file("New.swift", 3)], budget)).toEqual([]);
  expect(checkDatabaseSizes([file("New.swift", 4)], budget)).toEqual([
    "New.swift: 4 lines exceeds 3",
  ]);
});

test("existing large files can shrink but cannot grow", () => {
  expect(checkDatabaseSizes([file("Existing.swift", 4)], budget)).toEqual([]);
  expect(checkDatabaseSizes([file("Existing.swift", 6)], budget)).toEqual([
    "Existing.swift: 6 lines exceeds 5",
  ]);
});

test("renaming a large file does not carry its exception", () => {
  expect(checkDatabaseSizes([file("Renamed.swift", 5)], budget)).toHaveLength(
    1,
  );
});
