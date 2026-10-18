import { expect, test } from "bun:test";
import {
  discoverHostSizeTests,
  validateHostSizeTestInventory,
} from "./host-size-test-inventory.mjs";

const identifiers = discoverHostSizeTests();

test("standard-library discovery registers every original size case", () => {
  expect(identifiers).toHaveLength(29);
  expect(new Set(identifiers).size).toBe(29);
  expect(identifiers).toContain(
    "HostSizeReportTests.test_unindexed_or_duplicate_extensions_cannot_inflate_coverage",
  );
  expect(Object.isFrozen(identifiers)).toBe(true);
});

test.each([
  ["null", null],
  ["empty", []],
  ["missing", identifiers.slice(1)],
  ["extra", [...identifiers, identifiers[0]]],
  ["duplicate", [identifiers[0], ...identifiers.slice(0, 28)]],
  ["foreign", ["ForeignTests.test_example", ...identifiers.slice(1)]],
  [
    "command",
    ["HostSizeReportTests.test_example;exit", ...identifiers.slice(1)],
  ],
  ["newline", [`${identifiers[0]}\n`, ...identifiers.slice(1)]],
  ["number", [42, ...identifiers.slice(1)]],
  ["object", { tests: identifiers }],
])("%s size inventory fails closed", (_label, value) => {
  expect(() => validateHostSizeTestInventory(value)).toThrow(
    "Expected exactly 29 unique closed host size tests",
  );
});

test("inventory validation seals a copy rather than caller-owned admission", () => {
  const supplied = [...identifiers];
  const admitted = validateHostSizeTestInventory(supplied);
  supplied[0] = "ForeignTests.test_changed";
  expect(admitted).toEqual(identifiers);
  expect(Object.isFrozen(admitted)).toBe(true);
});
