import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";
import { planSwiftTests } from "./ci-test-plan.mjs";

test("shipping shared changes retain host, Keep Awake and every other extension lane", () => {
  const plan = planSwiftTests(["Makefile"], { shipping: true });
  assert.deepEqual(plan, planSwiftTests(["Makefile"]));
  const lanes = plan.include.map((lane) => lane.lane);
  assert.equal(lanes[0], "host-runtime");
  assert.equal(plan.include[0].targets, "ci-host ci-marketplace-runtime");
  const keepAwake = plan.include.find(
    (lane) => lane.lane === "extension-keepAwake",
  );
  assert.equal(keepAwake.targets, "ci-extension-keep-awake");
  for (const lane of ["extension-music", "extension-terminal", "native-music"])
    assert(lanes.includes(lane), lane);
});

test("every shipping extension change occupies its own native runners on main", () => {
  for (const path of [
    "Extensions/music/Native/Sources/Player.swift",
    "Extensions/terminal/Tests/TerminalTests.swift",
    "Extensions/calendar/Runtime.swift",
  ]) {
    const plan = planSwiftTests([path], { shipping: true });
    assert(plan.include.length > 0, path);
    assert.deepEqual(plan, planSwiftTests([path]));
  }
});

test("the original Keep Awake suite stays selected for its own test changes", () => {
  const plan = planSwiftTests(
    ["Extensions/keepAwake/Tests/RuntimeTests.swift"],
    {
      shipping: true,
    },
  );
  assert.equal(plan.include.length, 1);
  assert.equal(plan.include[0].extension, "keepAwake");
  assert.equal(plan.include[0].targets, "ci-extension-keep-awake");
});

test("shipping CLI rebuilds the full shipping inventory", () => {
  const shipping = JSON.parse(
    execFileSync(
      process.execPath,
      ["scripts/ci-test-plan.mjs", "--shipping", "--all"],
      {
        input: "",
        encoding: "utf8",
      },
    ),
  );
  assert.deepEqual(shipping, planSwiftTests([], { all: true, shipping: true }));
  assert.deepEqual(shipping, planSwiftTests([], { all: true }));
  assert(shipping.include.length > 2);
});
