import { expect, test } from "bun:test";
import {
  generateDashboardFixture,
  parseArguments,
} from "./generate-dashboard-fixture.mjs";

test("dashboard fixture arguments default to a realistic large data set", () => {
  expect(parseArguments(["--output", "/tmp/dashboard.json"])).toEqual({
    output: "/tmp/dashboard.json",
    days: 730,
    sources: 50,
    models: 100,
    projects: 10_000,
    seed: 7_614,
  });
});

test("dashboard fixture rejects missing output and invalid sizes", () => {
  expect(() => parseArguments([])).toThrow("--output needs a path");
  expect(() =>
    parseArguments(["--output", "/tmp/dashboard.json", "--days", "0"]),
  ).toThrow("--days must be a positive integer");
});

test("dashboard fixture is deterministic and contains exact requested cardinality", () => {
  const options = { days: 4, sources: 3, models: 5, projects: 11, seed: 42 };
  const first = generateDashboardFixture(options);
  const second = generateDashboardFixture(options);
  const projectRows = first.daily.flatMap((day) => day.projects);
  const modelNames = new Set(
    first.daily.flatMap((day) =>
      Object.values(day.bySource).flatMap((rows) =>
        rows.map((row) => row.modelName),
      ),
    ),
  );

  expect(first).toEqual(second);
  expect(first.daily).toHaveLength(4);
  expect(first.sources).toHaveLength(3);
  expect(projectRows).toHaveLength(11);
  expect(modelNames).toEqual(
    new Set(["model-0", "model-1", "model-2", "model-3", "model-4"]),
  );
  expect(first.totals).toEqual({ tokens: 1360025, cost: 4.703433 });
});

test("dashboard fixture contains only synthetic paths and hosts", () => {
  const fixture = generateDashboardFixture({
    days: 2,
    sources: 2,
    models: 2,
    projects: 3,
    seed: 7,
  });
  const serialized = JSON.stringify(fixture);

  expect(serialized).toContain("/synthetic/");
  expect(serialized).toContain("example.invalid");
  expect(serialized).not.toContain(process.env.HOME ?? "/Users/");
});
