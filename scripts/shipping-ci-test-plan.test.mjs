import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";
import { planSwiftTests } from "./ci-test-plan.mjs";

test("shipping shared changes retain host and original Keep Awake tests", () => {
  const plan = planSwiftTests(["Makefile"], { shipping: true });
  assert.deepEqual(
    plan.include.map((lane) => lane.lane),
    ["host-runtime", "extension-keepAwake"],
  );
  assert.equal(plan.include[0].targets, "ci-host ci-marketplace-runtime");
  assert.equal(plan.include[1].targets, "ci-extension-keep-awake");
});

test("unreleased extension changes do not occupy shipping native runners", () => {
  for (const path of [
    "Extensions/music/Native/Sources/Player.swift",
    "Extensions/terminal/Tests/TerminalTests.swift",
    "Extensions/calendar/Runtime.swift",
  ]) {
    assert.deepEqual(planSwiftTests([path], { shipping: true }), {
      include: [],
    });
    assert(planSwiftTests([path]).include.length > 0);
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

test("shipping CLI bounds a complete rebuild while the full inventory remains testable", () => {
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
  assert.equal(shipping.include.length, 2);
  assert(
    planSwiftTests([], { all: true }).include.length > shipping.include.length,
  );
});
