import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { planSwiftTests } from "./ci-test-plan.mjs";

test("an independent feature uses its extension build without unrelated macOS lanes", () => {
  for (const path of [
    "Extensions/calendar/Runtime.swift",
    "Extensions/studio/CLI/StudioCommands.swift",
    "Extensions/herdr/Views/SessionPage.swift",
    "docs/cli/README.md",
    "apps/music-player/src/catalog.rs",
  ]) {
    expect(planSwiftTests([path])).toEqual({ include: [] });
  }
});

test("host contracts and tests select host runtime checks", () => {
  for (const path of [
    "Packages/EdithHost/Sources/EdithHost/HostApplication.swift",
    "Packages/EdithHost/Tests/EdithHostCoreTests/HostWorkerTests.swift",
    "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/PackageStore.swift",
    "Packages/ExtensionMarketplace/Tests/ExtensionMarketplaceTests/StoreTests.swift",
  ]) {
    expect(planSwiftTests([path]).include).toEqual([
      { lane: "host-runtime", targets: "ci-host ci-marketplace-runtime" },
    ]);
  }
});

test("shared support changes select consumers while commands stay outside the empty host", () => {
  expect(
    planSwiftTests([
      "Packages/ExtensionSupport/Sources/EdithExtensionUI/PageScaffold.swift",
    ]).include,
  ).toEqual([
    { lane: "host-runtime", targets: "ci-host ci-marketplace-runtime" },
    { lane: "feature-models", targets: "ci-extension-support" },
  ]);
  expect(
    planSwiftTests([
      "Packages/ExtensionSupport/Sources/EdithExtensionCommands/ExtensionCLIExecution.swift",
    ]).include,
  ).toEqual([{ lane: "feature-models", targets: "ci-extension-support" }]);
});

test("Docs and native Music select their actual owning checks", () => {
  expect(planSwiftTests(["Extensions/docs/Runtime.swift"]).include).toEqual([
    { lane: "feature-models", targets: "ci-extension-docs" },
  ]);
  expect(
    planSwiftTests(["Extensions/music/Native/Cargo.lock"]).include,
  ).toEqual([{ lane: "native-music", targets: "ci-music-native" }]);
});

test("shared workflow and build inputs exercise all lanes without duplicate targets", () => {
  const expected = [
    { lane: "host-runtime", targets: "ci-host ci-marketplace-runtime" },
    {
      lane: "feature-models",
      targets: "ci-extension-support ci-extension-docs",
    },
    { lane: "native-music", targets: "ci-music-native" },
  ];
  for (const path of [
    "Makefile",
    ".swift-format",
    ".github/workflows/ci.yml",
    ".github/actions/cache-host/action.yml",
    "scripts/ci-test-plan.mjs",
  ]) {
    expect(planSwiftTests([path]).include).toEqual(expected);
  }
  expect(planSwiftTests([], { all: true }).include).toEqual(expected);
  expect(
    planSwiftTests([
      "Packages/ExtensionSupport/Package.swift",
      "Extensions/docs/Runtime.swift",
      "Extensions/docs/Views/DocsPage.swift",
    ]).include,
  ).toEqual(expected.slice(0, 2));
});

test("the actual planner consumes changed paths and rejects unknown options", () => {
  const result = execFileSync("node", ["scripts/ci-test-plan.mjs"], {
    input: "Extensions/music/Native/src/lib.rs\n",
    encoding: "utf8",
  });
  expect(JSON.parse(result)).toEqual({
    include: [{ lane: "native-music", targets: "ci-music-native" }],
  });
  expect(() =>
    execFileSync("node", ["scripts/ci-test-plan.mjs", "--unknown"], {
      input: "",
      stdio: "pipe",
    }),
  ).toThrow();
});
