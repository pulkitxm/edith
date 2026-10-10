import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { planSwiftTests } from "./ci-test-plan.mjs";

test("unscoped features run their owning models without unrelated host lanes", () => {
  expect(planSwiftTests(["Extensions/calendar/Runtime.swift"]).include).toEqual(
    [{ lane: "feature-models", targets: "ci-extension-support" }],
  );
  for (const path of ["docs/cli/README.md", "apps/music-player/src/catalog.rs"])
    expect(planSwiftTests([path])).toEqual({ include: [] });
});

test.each([
  [
    "music",
    "EmbeddedTests/MusicEmbeddedUITests.swift",
    "ci-extension-music",
    false,
  ],
  [
    "attention",
    "NativeRuntime/Tests/RuntimeTests.swift",
    "ci-extension-attention",
    false,
  ],
  [
    "terminal",
    "Native/Tests/TerminalTests.swift",
    "ci-extension-terminal",
    true,
  ],
  [
    "database",
    "DatabaseEngine/Tests/DatabaseTests.swift",
    "ci-extension-database",
    false,
  ],
  ["machines", "Tests/UI/SceneTests.swift", "ci-extension-machines", true],
  ["presenter", "Tests/PresenterTests.swift", "ci-extension-presenter", false],
  ["system", "Tests/SystemTests.swift", "ci-extension-system", false],
  ["downloads", "Tests/DownloadsTests.swift", "ci-extension-downloads", false],
])(
  "test-only edits select the exact standalone owner %s",
  (id, path, targets, ghostty) => {
    expect(planSwiftTests([`Extensions/${id}/${path}`]).include).toEqual([
      { lane: `extension-${id}`, extension: id, targets, ghostty },
    ]);
  },
);

test("multiple edits deduplicate each owner and the umbrella", () => {
  expect(
    planSwiftTests([
      "Extensions/music/EmbeddedTests/SceneTests.swift",
      "Extensions/music/Tests/PlaybackTests.swift",
      "Extensions/calendar/Tests/CalendarTests.swift",
      "Extensions/notchShelf/Tests/LayoutTests.swift",
    ]).include,
  ).toEqual([
    { lane: "feature-models", targets: "ci-extension-support" },
    {
      lane: "extension-music",
      extension: "music",
      targets: "ci-extension-music",
      ghostty: false,
    },
  ]);
});

test("owner boundaries and make arguments reject untrusted selections", () => {
  expect(planSwiftTests(["Extensions/musicSibling/Tests/Test.swift"])).toEqual({
    include: [],
  });
  expect(() =>
    planSwiftTests(["Extensions/sample/Tests/Test.swift"], {
      extensions: [
        { id: "sample", testTargets: ["ci-extension-sample;unexpected"] },
      ],
    }),
  ).toThrow("Invalid extension test targets");
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
    {
      lane: "feature-models",
      targets: "ci-extension-support ci-extension-docs",
    },
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
  expect(planSwiftTests([], { all: true, extensions: [] }).include).toEqual(
    expected,
  );
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
    save(
      "scripts/test-extension-package.mjs",
      readFileSync("scripts/test-extension-package.mjs"),
    );
    save("Extensions/manifest.json", readFileSync("Extensions/manifest.json"));
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
    expect(values.get("swift_tests")).toBe("true");
    expect(JSON.parse(values.get("swift_matrix"))).toEqual({
      include: [{ lane: "feature-models", targets: "ci-extension-support" }],
    });
    expect(() => git("show", `${head}:scripts/ci-test-plan.mjs`)).toThrow();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("explicit full verification includes every declared standalone owner", () => {
  const owners = planSwiftTests([], { all: true }).include.filter(
    (lane) => lane.extension,
  );
  expect(owners.map((lane) => lane.extension)).toEqual([
    "audioMixer",
    "presenter",
    "system",
    "music",
    "terminal",
    "studio",
    "bifrost",
    "lidAwake",
    "attention",
    "machines",
    "downloads",
    "virtualCamera",
    "herdr",
    "quinjet",
    "database",
  ]);
  const makefile = readFileSync("Makefile", "utf8");
  for (const lane of owners)
    for (const target of lane.targets.split(" "))
      expect(makefile).toMatch(new RegExp(`^${target}:`, "m"));
});
