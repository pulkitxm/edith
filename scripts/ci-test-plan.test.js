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

const definitions = JSON.parse(
  readFileSync("Extensions/manifest.json", "utf8"),
);
const standaloneOwners = definitions
  .filter((definition) => definition.testTargets?.length)
  .map(({ id }) => id);

function declaredSupportConsumers(product) {
  const consumes = (definition, seen = new Set()) => {
    if (seen.has(definition.id)) return false;
    seen.add(definition.id);
    const products = [
      definition.supportProduct,
      definition.nativeSupportProduct,
      ...Object.values(definition.supportProducts ?? {}),
    ].flat();
    return (
      products.includes(product) ||
      (definition.dependencies ?? []).some((id) => {
        const dependency = definitions.find((candidate) => candidate.id === id);
        return dependency && consumes(dependency, seen);
      })
    );
  };
  return definitions
    .filter(
      (definition) => definition.testTargets?.length && consumes(definition),
    )
    .map(({ id }) => id);
}

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
  ["terminal", "Tests/TerminalTests.swift", "ci-extension-terminal", true],
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

test("host tests select runtime checks without feature compilation fanout", () => {
  for (const path of [
    "Packages/EdithHost/Tests/EdithHostCoreTests/HostWorkerTests.swift",
    "Packages/ExtensionMarketplace/Tests/ExtensionMarketplaceTests/StoreTests.swift",
  ]) {
    expect(planSwiftTests([path]).include).toEqual([
      { lane: "host-runtime", targets: "ci-host ci-marketplace-runtime" },
    ]);
  }
  for (const path of [
    "Packages/EdithHost/Sources/EdithHost/HostApplication.swift",
    "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/PackageStore.swift",
  ]) {
    expect(planSwiftTests([path]).include).toEqual([
      { lane: "host-runtime", targets: "ci-host ci-marketplace-runtime" },
      {
        lane: "extension-virtualCamera",
        extension: "virtualCamera",
        targets:
          "ci-extension-camera ci-extension-camera-carrier ci-extension-camera-voice",
        ghostty: false,
      },
    ]);
  }
});

test("shared support changes select consumers while commands stay outside the empty host", () => {
  const ui = planSwiftTests([
    "Packages/ExtensionSupport/Sources/EdithExtensionUI/PageScaffold.swift",
  ]).include;
  expect(ui.slice(0, 2)).toEqual([
    { lane: "host-runtime", targets: "ci-host ci-marketplace-runtime" },
    { lane: "feature-models", targets: "ci-extension-support" },
  ]);
  expect(ui.slice(2).map((lane) => lane.extension)).toEqual(standaloneOwners);
  const commands = planSwiftTests([
    "Packages/ExtensionSupport/Sources/EdithExtensionCommands/ExtensionCLIExecution.swift",
  ]).include;
  expect(commands[0]).toEqual({
    lane: "feature-models",
    targets: "ci-extension-support",
  });
  const commandOwners = commands.slice(1).map((lane) => lane.extension);
  expect(commandOwners).toContain("attention");
  expect(commandOwners).toEqual(
    declaredSupportConsumers("EdithExtensionCommands"),
  );
  const documents = planSwiftTests([
    "Packages/ExtensionSupport/Sources/EdithExtensionDocuments/DocumentView.swift",
  ]).include;
  expect(documents[0]).toEqual({
    lane: "feature-models",
    targets: "ci-extension-support",
  });
  const documentOwners = documents.slice(1).map((lane) => lane.extension);
  for (const owner of ["machines", "herdr", "quinjet"])
    expect(documentOwners).toContain(owner);
  expect(documentOwners).toEqual(
    declaredSupportConsumers("EdithExtensionDocuments"),
  );
  expect(
    planSwiftTests([
      "Packages/ExtensionSupport/Tests/UITests/DeliveryTests.swift",
    ]).include,
  ).toEqual([{ lane: "feature-models", targets: "ci-extension-support" }]);
});

test("Docs and native Music select their actual owning checks", () => {
  const docs = planSwiftTests(["Extensions/docs/Runtime.swift"]).include;
  expect(
    docs.some((lane) => lane.targets.split(" ").includes("ci-extension-docs")),
  ).toBe(true);
  if (standaloneOwners.includes("docs"))
    expect(docs.some((lane) => lane.extension === "docs")).toBe(true);
  else
    expect(
      docs.some((lane) =>
        lane.targets.split(" ").includes("ci-extension-support"),
      ),
    ).toBe(true);
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
    const lanes = planSwiftTests([path]).include;
    expect(lanes.slice(0, 3)).toEqual(expected);
    expect(lanes.slice(3).map((lane) => lane.extension)).toEqual(
      standaloneOwners,
    );
  }
  expect(planSwiftTests([], { all: true, extensions: [] }).include).toEqual(
    expected,
  );
  const lanes = planSwiftTests([
    "Packages/ExtensionSupport/Package.swift",
    "Extensions/docs/Runtime.swift",
    "Extensions/docs/Views/DocsPage.swift",
  ]).include;
  expect(lanes.slice(0, 2)).toEqual(expected.slice(0, 2));
  expect(lanes.slice(2).map((lane) => lane.extension)).toEqual(
    standaloneOwners,
  );
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

test("shared native renderer changes exercise every owning consumer", () => {
  for (const path of [
    "Extensions/terminal/Native/Sources/GhosttyTerminal/TerminalSurface.swift",
    "Extensions/terminal/Native/Tests/GhosttyTerminalTests/TerminalTests.swift",
    "scripts/patches/ghostty-external-io.patch",
    "scripts/build-ghostty.sh",
  ]) {
    const lanes = planSwiftTests([path]).include;
    expect(lanes.map((lane) => lane.extension)).toEqual([
      "terminal",
      "machines",
      "herdr",
      "quinjet",
    ]);
    expect(lanes.every((lane) => lane.ghostty === true)).toBe(true);
  }
});

test("manifest and SDK package inputs cannot silently omit native owners", () => {
  for (const path of [
    "Extensions/manifest.json",
    "Packages/ExtensionSupport/Package.swift",
    "Packages/ExtensionSupport/Package.resolved",
  ]) {
    const lanes = planSwiftTests([path]).include;
    expect(
      lanes.filter((lane) => lane.extension).map((lane) => lane.extension),
    ).toEqual(standaloneOwners);
    expect(lanes.filter((lane) => lane.lane === "feature-models")).toHaveLength(
      1,
    );
  }
  for (const path of [
    "Extensions/Package.swift",
    "Extensions/Package.resolved",
  ])
    expect(planSwiftTests([path]).include).toEqual([
      { lane: "feature-models", targets: "ci-extension-support" },
    ]);
  expect(
    planSwiftTests(["scripts/prepare-extension-native-support.mjs"]).include,
  ).toEqual([
    {
      lane: "extension-attention",
      extension: "attention",
      targets: "ci-extension-attention",
      ghostty: false,
    },
  ]);
});

test("SDK selection follows role composition and transitive consumers", () => {
  const extensions = [
    {
      id: "composed",
      supportProduct: "EdithExtensionUI",
      supportProducts: {
        app: ["EdithExtensionDocuments", "EdithExtensionCommands"],
        privileged: null,
      },
      testTargets: ["ci-extension-composed"],
    },
    {
      id: "dependent",
      dependencies: ["composed"],
      testTargets: ["ci-extension-dependent"],
    },
    {
      id: "unrelated",
      supportProduct: "EdithExtensionArchive",
      testTargets: ["ci-extension-unrelated"],
    },
  ];
  const paths = [
    "Packages/ExtensionSupport/Sources/EdithExtensionCommands/Execution.swift",
    "Packages/ExtensionSupport/Sources/EdithExtensionDocuments/Document.swift",
  ];
  expect(
    planSwiftTests(paths, { extensions }).include.map((lane) => lane.extension),
  ).toEqual([undefined, "composed", "dependent"]);
  expect(
    planSwiftTests(
      ["Packages/EdithHost/Sources/EdithHostCore/HostWorker.swift"],
      {
        extensions,
      },
    ).include,
  ).toEqual([
    { lane: "host-runtime", targets: "ci-host ci-marketplace-runtime" },
  ]);
});

test("every extension test directory selects a deduplicated executable lane", () => {
  const definitions = JSON.parse(
    readFileSync("Extensions/manifest.json", "utf8"),
  );
  expect(definitions).toHaveLength(39);
  for (const { id } of definitions) {
    const paths = [
      `Extensions/${id}/Tests/RegressionTests.swift`,
      `Extensions/${id}/Tests/RegressionTests.swift`,
    ];
    const lanes = planSwiftTests(paths).include;
    expect(lanes.length, id).toBeGreaterThan(0);
    expect(new Set(lanes.map((lane) => lane.lane)).size, id).toBe(lanes.length);
    expect(
      lanes.every((lane) => lane.targets.length > 0),
      id,
    ).toBe(true);
  }
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
    for (const path of [
      "scripts/extension-release-plan.mjs",
      "scripts/build-extension-support.mjs",
      "scripts/extension-ghostty-native.mjs",
      "scripts/extension-host-abi.mjs",
    ])
      save(path, readFileSync(path));
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
  expect(owners.map((lane) => lane.extension)).toEqual(standaloneOwners);
  const makefile = readFileSync("Makefile", "utf8");
  for (const lane of owners)
    for (const target of lane.targets.split(" "))
      expect(makefile).toMatch(new RegExp(`^${target}:`, "m"));
});

test("every tracked standalone package declares an executable owning test target", () => {
  const packages = execFileSync(
    "git",
    ["ls-files", "Extensions/*/Package.swift", "Extensions/*/*/Package.swift"],
    { encoding: "utf8" },
  )
    .trim()
    .split("\n")
    .filter(Boolean);
  expect(packages.length).toBeGreaterThan(0);
  for (const path of packages) {
    const id = path.split("/")[1];
    const definition = definitions.find((candidate) => candidate.id === id);
    expect(definition, path).toBeDefined();
    expect(definition.testTargets?.length, path).toBeGreaterThan(0);
    const lanes = planSwiftTests([path]).include;
    expect(
      lanes.some((lane) => lane.extension === id),
      path,
    ).toBe(true);
  }
});
