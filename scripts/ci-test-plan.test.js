import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

test("a child behind its base routes the tested merge revision with the current planner", () => {
  const workflow = Bun.YAML.parse(
    readFileSync(".github/workflows/ci.yml", "utf8"),
  );
  const job = workflow.jobs.changes;
  const checkout = job.steps.find((step) =>
    step.uses?.startsWith("actions/checkout@"),
  );
  expect(checkout.with.ref).toBe(["$", "{{ github.sha }}"].join(""));
  const root = mkdtempSync(join(tmpdir(), "edith-routing-"));
  const git = (...args) =>
    execFileSync("git", ["-c", "core.hooksPath=/dev/null", ...args], {
      cwd: root,
      encoding: "utf8",
      stdio: "pipe",
    });
  const save = (path, contents) => {
    const target = join(root, path);
    mkdirSync(join(target, ".."), { recursive: true });
    writeFileSync(target, contents);
  };
  const commit = (message) => {
    git("add", ".");
    git("-c", "commit.gpgsign=false", "commit", "-m", message);
  };
  try {
    git("init", "--initial-branch=base");
    git("config", "user.name", "Fixture");
    git("config", "user.email", "fixture@example.invalid");
    save("Extensions/calendar/Runtime.swift", "initial\n");
    commit("Initial fixture");
    git("switch", "-c", "feature");
    save("Extensions/calendar/Runtime.swift", "changed\n");
    commit("Change Calendar fixture");
    const head = git("rev-parse", "HEAD").trim();
    git("switch", "base");
    save("scripts/ci-test-plan.mjs", readFileSync("scripts/ci-test-plan.mjs"));
    commit("Add planner fixture");
    git("update-ref", "refs/remotes/origin/base", "HEAD");
    git("merge", "--no-edit", "feature");
    const merge = git("rev-parse", "HEAD").trim();
    expect(merge).not.toBe(head);
    const output = join(root, "routing-output");
    execFileSync(
      "bash",
      ["-e", "-c", job.steps.find((step) => step.id === "areas").run],
      {
        cwd: root,
        stdio: "pipe",
        env: {
          ...process.env,
          BASE_REF: "base",
          BEFORE: "",
          GITHUB_OUTPUT: output,
        },
      },
    );
    const values = new Map(
      readFileSync(output, "utf8")
        .trim()
        .split("\n")
        .map((line) => {
          const split = line.indexOf("=");
          return [line.slice(0, split), line.slice(split + 1)];
        }),
    );
    expect(values.get("swift")).toBe("true");
    expect(values.get("host")).toBe("false");
    expect(values.get("scripts")).toBe("false");
    expect(values.get("swift_tests")).toBe("false");
    expect(JSON.parse(values.get("swift_matrix"))).toEqual({ include: [] });
    expect(() => git("show", `${head}:scripts/ci-test-plan.mjs`)).toThrow();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
