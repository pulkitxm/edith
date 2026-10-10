import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { runExtensionPackageTests } from "./test-extension-package.mjs";

test("optional test packages run only the selected extension's declared targets", () => {
  const calls = [];
  runExtensionPackageTests(
    { testTargets: ["ci-extension-studio", "ci-extension-studio-native"] },
    (...args) => calls.push(args),
  );
  expect(calls).toEqual([
    [
      "make",
      ["ci-extension-studio", "ci-extension-studio-native"],
      { stdio: "inherit" },
    ],
  ]);
  runExtensionPackageTests({}, (...args) => calls.push(args));
  expect(calls).toHaveLength(1);
});

test("untrusted target lists cannot inject make options or shell commands", () => {
  for (const testTargets of [
    "ci-extension-studio",
    ["--eval=malicious"],
    ["ci-extension-studio;unexpected"],
    ["ci-extension-../other"],
    ["ci-extension-studio", "ci-extension-studio"],
    [null],
    Array.from({ length: 5 }, (_, index) => `ci-extension-package${index}`),
  ]) {
    let called = false;
    expect(() =>
      runExtensionPackageTests({ testTargets }, () => {
        called = true;
      }),
    ).toThrow("Invalid extension test targets");
    expect(called).toBe(false);
  }
});

test("failed isolated tests stop the extension release build", () => {
  const failure = new Error("synthetic native test failure");
  expect(() =>
    runExtensionPackageTests({ testTargets: ["ci-extension-machines"] }, () => {
      throw failure;
    }),
  ).toThrow(failure);
});

test("Notch's actual manifest runs its standalone browser and panel tests only", () => {
  const definitions = JSON.parse(
    readFileSync(
      new URL("../Extensions/manifest.json", import.meta.url),
      "utf8",
    ),
  );
  const notch = definitions.find(({ id }) => id === "notchShelf");
  expect(notch.testTargets).toEqual(["ci-extension-notch-native"]);
  const calls = [];
  runExtensionPackageTests(notch, (...args) => calls.push(args));
  expect(calls).toEqual([
    ["make", ["ci-extension-notch-native"], { stdio: "inherit" }],
  ]);
});
