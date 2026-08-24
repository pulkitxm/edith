import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { validatePerformanceAudit } from "./check-performance-audit.mjs";

const audit = JSON.parse(readFileSync("performance/audit.json", "utf8"));

test("the performance audit covers every required area with live evidence", () => {
  expect(validatePerformanceAudit(audit)).toEqual([]);
});

test("the performance audit rejects missing coverage", () => {
  const incomplete = {
    ...audit,
    scenarios: audit.scenarios.filter(({ area }) => area !== "slowNetwork"),
  };

  expect(validatePerformanceAudit(incomplete)).toContain(
    "slowNetwork: scenario is missing",
  );
});
