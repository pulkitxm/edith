import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { nativeCIWorkflowsEqual, planSwiftTests } from "./ci-test-plan.mjs";
import {
  extensionFingerprint,
  planExtensionBuilds,
  planPullRequestBuilds,
} from "./extension-release-plan.mjs";

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
  [
    "notchShelf",
    "Tests/BrowserCLITests.swift",
    "ci-extension-notch-native",
    false,
  ],
])(
  "test-only edits select the exact standalone owner %s",
  (id, path, targets, ghostty) => {
    const changed = [`Extensions/${id}/${path}`];
    const owners = definitions.map((definition) => ({
      ...definition,
      sameExecutableWorker: false,
    }));
    expect(planSwiftTests(changed).include).toEqual([
      { lane: `extension-${id}`, extension: id, targets, ghostty },
    ]);
    expect(planExtensionBuilds(owners, changed).map(({ id }) => id)).toEqual([
      id,
    ]);
    expect(planPullRequestBuilds(definitions, changed, definitions)).toEqual(
      [],
    );
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
      lane: "extension-notchShelf",
      extension: "notchShelf",
      targets: "ci-extension-notch-native",
      ghostty: false,
    },
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
      targets: "ci-extension-support",
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
  expect(planSwiftTests([], { all: true, extensions: [] }).include).toEqual([
    expected[0],
    {
      lane: "feature-models",
      targets: "ci-extension-support ci-extension-docs",
    },
    expected[2],
  ]);
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

test("full verification preserves every declared check exactly once", () => {
  const expectedTargets = [
    ...new Set([
      "ci-host",
      "ci-marketplace-runtime",
      "ci-extension-support",
      "ci-extension-docs",
      "ci-music-native",
      ...definitions.flatMap((definition) => definition.testTargets ?? []),
    ]),
  ].sort();
  for (const [paths, options] of [
    [[], { all: true }],
    [[".github/workflows/ci.yml"], {}],
    [[".github/actions/cache-host/action.yml"], {}],
    [["Makefile"], {}],
  ]) {
    const lanes = planSwiftTests(paths, options).include;
    expect(
      lanes.filter((lane) => lane.extension).map((lane) => lane.extension),
    ).toEqual(standaloneOwners);
    expect(lanes.flatMap((lane) => lane.targets.split(" ")).sort()).toEqual(
      expectedTargets,
    );
    expect(lanes.every((lane) => lane.targets.length > 0)).toBe(true);
  }
});

test("shared account contracts run once while both owning native lanes remain", () => {
  const paths = [
    "Extensions/herdr/Runtime.swift",
    "Extensions/usage/Runtime.swift",
  ];
  const owners = definitions.filter(({ id }) =>
    ["herdr", "usage"].includes(id),
  );
  const lanes = planSwiftTests(paths).include.filter((lane) =>
    ["herdr", "usage"].includes(lane.extension),
  );
  expect(lanes.map((lane) => lane.extension)).toEqual(
    owners.map(({ id }) => id),
  );
  expect(lanes.flatMap((lane) => lane.targets.split(" ")).sort()).toEqual(
    [...new Set(owners.flatMap(({ testTargets }) => testTargets))].sort(),
  );
  for (const owner of owners) {
    const selected = planSwiftTests([
      `Extensions/${owner.id}/Runtime.swift`,
    ]).include;
    expect(selected.flatMap((lane) => lane.targets.split(" "))).toEqual(
      owner.testTargets,
    );
  }
});

test("the local account helper never enters hosted native plans", () => {
  expect(readFileSync("Makefile", "utf8")).toMatch(
    /^ci-extension-accounts-local:/m,
  );
  for (const [paths, options] of [
    [[], { all: true }],
    [["Makefile"], {}],
    [[".github/workflows/ci.yml"], {}],
    [[], { all: true, shipping: true }],
  ]) {
    expect(
      planSwiftTests(paths, options).include.flatMap((lane) =>
        lane.targets.split(" "),
      ),
    ).not.toContain("ci-extension-accounts-local");
  }
  expect(() =>
    planSwiftTests([], {
      all: true,
      extensions: [
        { id: "synthetic", testTargets: ["ci-extension-accounts-local"] },
      ],
    }),
  ).toThrow("Local account checks cannot enter hosted lanes");
});

test("Docs changes retain both actual packages in one owning lane", () => {
  for (const path of [
    "Extensions/docs/Runtime.swift",
    "Extensions/docs/Tests/DocsTests.swift",
    "Packages/EdithDocsWorker/Sources/EdithDocsWorker/DocsWorker.swift",
    "Packages/EdithDocsWorker/Tests/EdithDocsWorkerTests/DocsTests.swift",
  ]) {
    expect(planSwiftTests([path]).include).toEqual([
      {
        lane: "extension-docs",
        extension: "docs",
        targets: "ci-extension-docs ci-extension-docs-native",
        ghostty: false,
      },
    ]);
  }
  const mixed = planSwiftTests([
    "Extensions/docs/Runtime.swift",
    "Packages/EdithHost/Tests/EdithHostCoreTests/HostWorkerTests.swift",
    "Packages/ExtensionSupport/Tests/UITests/DeliveryTests.swift",
  ]).include;
  expect(mixed.map((lane) => lane.lane)).toEqual([
    "host-runtime",
    "feature-models",
    "extension-docs",
  ]);
  expect(mixed.flatMap((lane) => lane.targets.split(" "))).toEqual([
    "ci-host",
    "ci-marketplace-runtime",
    "ci-extension-support",
    "ci-extension-docs",
    "ci-extension-docs-native",
  ]);
});

test("shared Docs checks remain when no selected owner runs them", () => {
  const withoutDocs = definitions.filter(({ id }) => id !== "docs");
  expect(
    planSwiftTests(["Extensions/docs/Runtime.swift"], {
      extensions: withoutDocs,
    }).include,
  ).toEqual([{ lane: "feature-models", targets: "ci-extension-docs" }]);
  const docs = definitions.find(({ id }) => id === "docs");
  expect(
    planSwiftTests(["Extensions/docs/Runtime.swift"], {
      extensions: [{ ...docs, testTargets: ["ci-extension-docs-native"] }],
    }).include,
  ).toEqual([
    { lane: "feature-models", targets: "ci-extension-docs" },
    {
      lane: "extension-docs",
      extension: "docs",
      targets: "ci-extension-docs-native",
      ghostty: false,
    },
  ]);
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

test.each(["refs/pull/1/merge", "refs/heads/main"])(
  "a child behind its base routes the tested merge revision with the current planner (%s)",
  (ref) => {
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
      save(
        "scripts/ci-test-plan.mjs",
        readFileSync("scripts/ci-test-plan.mjs"),
      );
      save(
        "scripts/test-extension-package.mjs",
        readFileSync("scripts/test-extension-package.mjs"),
      );
      for (const path of [
        "scripts/extension-release-plan.mjs",
        "scripts/build-extension-support.mjs",
        "scripts/extension-ghostty-native.mjs",
        "scripts/extension-host-abi.mjs",
        "scripts/shipping-extension-policy.mjs",
      ])
        save(path, readFileSync(path));
      save(
        "Extensions/manifest.json",
        readFileSync("Extensions/manifest.json"),
      );
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
            GITHUB_REF: ref,
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
      const shipping = ref === "refs/heads/main";
      expect(values.get("swift_tests")).toBe(String(!shipping));
      expect(JSON.parse(values.get("swift_matrix"))).toEqual({
        include: shipping
          ? []
          : [{ lane: "feature-models", targets: "ci-extension-support" }],
      });
      expect(() => git("show", `${head}:scripts/ci-test-plan.mjs`)).toThrow();
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  },
);

test("standalone owners keep their runtime tests outside the utility umbrella", () => {
  const umbrella = readFileSync("Extensions/Package.swift", "utf8");
  const paths = umbrella
    .split(/\n {8}\.(?:target|testTarget)\(/)
    .slice(1)
    .map((block) => block.match(/path: "([^"]+)"/)?.[1])
    .filter(Boolean);
  for (const path of paths.filter((path) => !path.startsWith("..")))
    expect(existsSync(join("Extensions", path, "Package.swift")), path).toBe(
      false,
    );
  for (const id of ["machines", "music", "usage", "notchShelf", "docs"]) {
    const definition = definitions.find((entry) => entry.id === id);
    expect(definition.testTargets.length).toBeGreaterThan(0);
    expect(
      planSwiftTests([
        `Extensions/${id}/Tests/RuntimeTests.swift`,
      ]).include.some(
        (lane) =>
          lane.extension === id &&
          definition.testTargets.every((target) =>
            lane.targets.split(" ").includes(target),
          ),
      ),
    ).toBe(true);
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
    if (id === "fixtureSupport") {
      expect(planSwiftTests([path]).include).toEqual([
        { lane: "feature-models", targets: "ci-extension-support" },
      ]);
      expect(definitions.some((definition) => definition.id === id)).toBe(
        false,
      );
      continue;
    }
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

test("shared fixture test sources select one umbrella without a release build", async () => {
  const paths = [
    "Extensions/fixtureSupport/Tests/WorkerFixtureAdmissionTests.swift",
    "Extensions/fixtureSupport/Tests/Support/EngineFixture.swift",
  ];
  expect(planSwiftTests(paths).include).toEqual([
    { lane: "feature-models", targets: "ci-extension-support" },
  ]);
  expect(planPullRequestBuilds(definitions, paths, definitions)).toEqual([]);
  expect(planExtensionBuilds(definitions, paths)).toEqual(definitions);
  expect(definitions).toHaveLength(39);
  for (const path of [
    "Packages/EdithHost/Sources/EdithHost/HostWorkerStartAdmission.swift",
    "Packages/EdithHost/Sources/EdithHostCore/HostCoreAdmission.swift",
    "Extensions/fixtureSupport/Package.swift",
    "Extensions/fixtureSupport/WorkerFixtureAdmission.swift",
    "Extensions/fixtureSupport/FutureAdmission.swift",
  ])
    expect(planPullRequestBuilds(definitions, [path], definitions)).toEqual(
      definitions,
    );
  const root = mkdtempSync(join(tmpdir(), "fixture-test-fingerprint-"));
  const definition = {
    id: "focusDim",
    inputs: ["Extensions/focusDim"],
    sharedInputs: ["Extensions/fixtureSupport"],
    dependencies: [],
  };
  try {
    mkdirSync(join(root, "Extensions/focusDim"), { recursive: true });
    mkdirSync(join(root, "Extensions/fixtureSupport/Tests"), {
      recursive: true,
    });
    writeFileSync(
      join(root, "Extensions/focusDim/Runtime.swift"),
      "owned runtime",
    );
    const helper = join(
      root,
      "Extensions/fixtureSupport/WorkerFixtureAdmission.swift",
    );
    writeFileSync(helper, "owned admission");
    const original = await extensionFingerprint(root, definition, [definition]);
    for (const path of paths) {
      mkdirSync(join(root, path, ".."), { recursive: true });
      writeFileSync(join(root, path), "updated admission regression");
      expect(await extensionFingerprint(root, definition, [definition])).toBe(
        original,
      );
    }
    writeFileSync(helper, "updated production admission");
    expect(await extensionFingerprint(root, definition, [definition])).not.toBe(
      original,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("Notch CLI and native browser edits select their standalone owner without release builds", () => {
  for (const paths of [
    ["Extensions/notchShelf/CLI/BrowserCommands.swift"],
    ["Extensions/notchShelf/Browser/Remote/NotchBrowserCommandClient.swift"],
    [
      "Extensions/notchShelf/Tests/BrowserCLITests.swift",
      "Extensions/notchShelf/Tests/NotchBrowserCLIIntegrationTests.swift",
    ],
  ])
    expect(planSwiftTests(paths).include).toEqual([
      {
        lane: "extension-notchShelf",
        extension: "notchShelf",
        targets: "ci-extension-notch-native",
        ghostty: false,
      },
    ]);
});

function nativeWorkflowFixture() {
  return Bun.YAML.parse(`name: Synthetic CI
on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      release:
        type: boolean
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      swift_matrix: "synthetic-matrix"
    steps:
      - run: node scripts/ci-test-plan.mjs
  swift-build:
    needs: changes
    runs-on: macos-latest
    timeout-minutes: 90
    steps:
      - run: make ci-host
  swift-test:
    needs: changes
    runs-on: macos-latest
    timeout-minutes: 90
    strategy:
      max-parallel: 2
      matrix:
        include: []
    steps:
      - run: make ci-extension-music
  release:
    needs: changes
    runs-on: ubuntu-latest
    steps:
      - run: node scripts/publish-release-state.mjs
`);
}

function releaseWorkflowChange() {
  const previous = nativeWorkflowFixture();
  const current = structuredClone(previous);
  current.on.workflow_dispatch.inputs.coordinated_release = {
    type: "string",
    default: "",
  };
  current.jobs.release.steps.push({
    run: "node scripts/validate-coordinated-release.mjs",
  });
  return { previous, current };
}

test("release-only pull request workflow edits keep native jobs and triggers identical", () => {
  const ciWorkflow = releaseWorkflowChange();
  expect(nativeCIWorkflowsEqual(ciWorkflow.previous, ciWorkflow.current)).toBe(
    true,
  );
  expect(
    planSwiftTests(
      [".github/workflows/ci.yml", "scripts/publish-release-helper.mjs"],
      { ciWorkflow },
    ),
  ).toEqual({ include: [] });
  const paths = [
    ".github/workflows/ci.yml",
    "Extensions/music/Tests/PlaybackTests.swift",
  ];
  expect(planSwiftTests(paths, { ciWorkflow })).toEqual(
    planSwiftTests(paths.slice(1)),
  );
});

test("default full and shipping checks retain every original workflow lane", () => {
  const ciWorkflow = releaseWorkflowChange();
  const paths = [".github/workflows/ci.yml"];
  for (const options of [
    {},
    { all: true },
    { shipping: true },
    { all: true, shipping: true },
  ]) {
    expect(
      planSwiftTests(paths, {
        ...options,
        ciWorkflow: options.all || options.shipping ? ciWorkflow : undefined,
      }),
    ).toEqual(planSwiftTests(paths, options));
  }
  expect(
    planSwiftTests([".github/actions/cache-swift/action.yml"], { ciWorkflow }),
  ).toEqual(planSwiftTests([], { all: true }));
  expect(
    planSwiftTests([".github/workflows/new-native.yml"], { ciWorkflow }),
  ).toEqual(planSwiftTests([], { all: true }));
  expect(planSwiftTests(["Makefile"], { ciWorkflow })).toEqual(
    planSwiftTests([], { all: true }),
  );
});

test("native job budgets steps matrix and global execution changes retain full validation", () => {
  for (const mutate of [
    (workflow) => {
      workflow.jobs["swift-test"]["timeout-minutes"] = 91;
    },
    (workflow) => {
      workflow.jobs["swift-test"].strategy["max-parallel"] = 3;
    },
    (workflow) => {
      workflow.jobs["swift-test"].steps[0].run = "make ci-extension-terminal";
    },
    (workflow) => {
      workflow.jobs.changes.outputs.swift_matrix = "changed-matrix";
    },
    (workflow) => {
      workflow.on.pull_request = { paths: ["Extensions/**"] };
    },
    (workflow) => {
      workflow.on.push.branches = ["main", "release"];
    },
    (workflow) => {
      workflow.permissions = { contents: "write" };
    },
    (workflow) => {
      workflow.concurrency = { "cancel-in-progress": true };
    },
    (workflow) => {
      workflow.jobs.additional = {
        "runs-on": "ubuntu-latest",
        steps: [{ run: "make ci-host" }],
      };
    },
    (workflow) => {
      delete workflow.jobs.release;
    },
  ]) {
    const previous = nativeWorkflowFixture();
    const current = structuredClone(previous);
    mutate(current);
    expect(nativeCIWorkflowsEqual(previous, current)).toBe(false);
    expect(
      planSwiftTests([".github/workflows/ci.yml"], {
        ciWorkflow: { previous, current },
      }),
    ).toEqual(planSwiftTests([], { all: true }));
  }
});

test("transitive native dependencies remain part of the exact workflow scope", () => {
  const previous = nativeWorkflowFixture();
  previous.jobs.generated = {
    "runs-on": "ubuntu-latest",
    steps: [{ run: "generate original native inputs" }],
  };
  previous.jobs["swift-test"].needs = ["changes", "generated"];
  const current = structuredClone(previous);
  current.jobs.generated.steps[0].run = "generate changed native inputs";
  expect(nativeCIWorkflowsEqual(previous, current)).toBe(false);
  expect(
    planSwiftTests([".github/workflows/ci.yml"], {
      ciWorkflow: { previous, current },
    }),
  ).toEqual(planSwiftTests([], { all: true }));
});

test("incomplete cyclic and unknown native workflow inputs fail closed", () => {
  const original = nativeWorkflowFixture();
  for (const current of [
    undefined,
    {},
    { jobs: {} },
    { ...original, on: "pull_request" },
  ])
    expect(nativeCIWorkflowsEqual(original, current)).toBe(false);
  for (const mutate of [
    (workflow) => {
      delete workflow.jobs["swift-test"];
    },
    (workflow) => {
      workflow.jobs["swift-test"].needs = ["missing"];
    },
    (workflow) => {
      workflow.jobs.changes.needs = "swift-test";
    },
    (workflow) => {
      workflow.jobs["swift-test"].needs = { unexpected: "changes" };
    },
  ]) {
    const current = structuredClone(original);
    mutate(current);
    expect(nativeCIWorkflowsEqual(original, current)).toBe(false);
  }
});

test("CLI absent base commits stay full and symbolic base arguments are rejected", () => {
  const result = execFileSync(
    "bun",
    ["scripts/ci-test-plan.mjs", `--pull-request-base=${"0".repeat(40)}`],
    { input: ".github/workflows/ci.yml\n", encoding: "utf8" },
  );
  expect(JSON.parse(result)).toEqual(planSwiftTests([], { all: true }));
  expect(() =>
    execFileSync(
      "bun",
      ["scripts/ci-test-plan.mjs", "--pull-request-base=HEAD"],
      {
        input: ".github/workflows/ci.yml\n",
        encoding: "utf8",
        stdio: ["pipe", "pipe", "pipe"],
      },
    ),
  ).toThrow();
});

test("the actual change job scopes release-only PRs and preserves main shipping validation", () => {
  const directory = mkdtempSync(join(tmpdir(), "native-workflow-route-"));
  const git = (...args) =>
    execFileSync(
      "git",
      [
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "-c",
        "core.hooksPath=/dev/null",
        ...args,
      ],
      { cwd: directory, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    ).trim();
  const save = (path, content) => {
    const target = join(directory, path);
    mkdirSync(join(target, ".."), { recursive: true });
    writeFileSync(target, content);
  };
  try {
    git("init", "-b", "main");
    for (const path of [
      "scripts/ci-test-plan.mjs",
      "scripts/test-extension-package.mjs",
      "scripts/extension-release-plan.mjs",
      "scripts/build-extension-support.mjs",
      "scripts/extension-ghostty-native.mjs",
      "scripts/extension-host-abi.mjs",
      "scripts/shipping-extension-policy.mjs",
      "Extensions/manifest.json",
    ])
      save(path, readFileSync(path));
    const ciWorkflow = releaseWorkflowChange();
    save(".github/workflows/ci.yml", JSON.stringify(ciWorkflow.previous));
    git("add", ".");
    git("commit", "-m", "fixture native baseline");
    const base = git("rev-parse", "HEAD");
    git("update-ref", "refs/remotes/origin/main", base);
    save(".github/workflows/ci.yml", JSON.stringify(ciWorkflow.current));
    git("add", ".github/workflows/ci.yml");
    git("commit", "-m", "fixture release workflow");
    const workflow = Bun.YAML.parse(
      readFileSync(".github/workflows/ci.yml", "utf8"),
    );
    const command = workflow.jobs.changes.steps.find(
      (step) => step.id === "areas",
    ).run;
    for (const [event, ref, expected] of [
      ["pull_request", "refs/pull/9/merge", { include: [] }],
      [
        "push",
        "refs/heads/main",
        planSwiftTests([".github/workflows/ci.yml"], { shipping: true }),
      ],
    ]) {
      const output = join(directory, `output-${event}`);
      execFileSync("bash", ["-e", "-o", "pipefail", "-c", command], {
        cwd: directory,
        encoding: "utf8",
        env: {
          ...process.env,
          BASE_REF: "main",
          BEFORE: "",
          GITHUB_EVENT_NAME: event,
          GITHUB_REF: ref,
          GITHUB_OUTPUT: output,
        },
      });
      const values = new Map(
        readFileSync(output, "utf8")
          .trim()
          .split("\n")
          .map((line) => {
            const at = line.indexOf("=");
            return [line.slice(0, at), line.slice(at + 1)];
          }),
      );
      expect(JSON.parse(values.get("swift_matrix"))).toEqual(expected);
      expect(values.get("swift_tests")).toBe(
        String(expected.include.length > 0),
      );
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
