import { describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  extensionFingerprint,
  planExtensionBuilds,
  supportCacheFingerprint,
  workerRuntimeInputs,
} from "./extension-release-plan.mjs";

const definitions = [
  {
    id: "music",
    inputs: ["Extensions/music"],
    sharedInputs: ["Packages/ExtensionMarketplace"],
    dependencies: [],
  },
  {
    id: "calendar",
    inputs: ["Extensions/calendar"],
    sharedInputs: ["Packages/ExtensionMarketplace"],
    dependencies: [],
  },
  {
    id: "shelf",
    inputs: ["Extensions/shelf"],
    sharedInputs: ["Packages/ExtensionMarketplace"],
    dependencies: ["music"],
  },
];

describe("independent extension releases", () => {
  test("native Cargo sources rebuild Music while compiled Cargo outputs do not", async () => {
    const root = await mkdtemp(join(tmpdir(), "extension-cargo-inputs-"));
    const definition = {
      id: "music",
      inputs: ["Extensions/music"],
      sharedInputs: [],
      dependencies: [],
      nativeCargo: {
        manifest: "Extensions/music/Native/Cargo.toml",
        library: "libedith_music_player.dylib",
      },
    };
    try {
      await mkdir(join(root, "Extensions/music/Native/src"), {
        recursive: true,
      });
      await writeFile(join(root, definition.nativeCargo.manifest), "package");
      await writeFile(
        join(root, "Extensions/music/Native/Cargo.lock"),
        "dependencies",
      );
      await writeFile(
        join(root, "Extensions/music/Native/src/lib.rs"),
        "library source",
      );
      const original = await extensionFingerprint(root, definition, [
        definition,
      ]);
      await mkdir(join(root, "Extensions/music/Native/target/release"), {
        recursive: true,
      });
      await writeFile(
        join(
          root,
          "Extensions/music/Native/target/release/libedith_music_player.dylib",
        ),
        "compiled output",
      );
      expect(await extensionFingerprint(root, definition, [definition])).toBe(
        original,
      );
      await writeFile(
        join(root, "Extensions/music/Native/Cargo.lock"),
        "new dependencies",
      );
      expect(
        await extensionFingerprint(root, definition, [definition]),
      ).not.toBe(original);
      const dependenciesChanged = await extensionFingerprint(root, definition, [
        definition,
      ]);
      await writeFile(
        join(root, "Extensions/music/Native/src/lib.rs"),
        "changed library source",
      );
      expect(
        await extensionFingerprint(root, definition, [definition]),
      ).not.toBe(dependenciesChanged);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
  test("rebuilds only consumers of changed support products", async () => {
    const root = await mkdtemp(join(tmpdir(), "extension-support-inputs-"));
    const products = [
      "EdithExtensionSupport",
      "EdithExtensionUI",
      "EdithExtensionDocuments",
    ];
    const consumers = products.map((supportProduct, index) => ({
      id: `consumer${index}`,
      version: "1.0.0",
      hostABI: "edith-host-1",
      supportProduct,
      inputs: [`Extensions/consumer${index}`],
      sharedInputs: [
        "Packages/ExtensionSupport",
        "scripts/build-extension-support.mjs",
      ],
      dependencies: [],
    }));
    try {
      await mkdir(join(root, "scripts"), { recursive: true });
      await writeFile(
        join(root, "scripts/build-extension-support.mjs"),
        "builder",
      );
      for (const [index, product] of products.entries()) {
        await mkdir(join(root, `Extensions/consumer${index}`), {
          recursive: true,
        });
        await writeFile(
          join(root, `Extensions/consumer${index}/Runtime.swift`),
          "runtime",
        );
        const directory = `Packages/ExtensionSupport/Sources/${product}`;
        await mkdir(join(root, directory), { recursive: true });
        await writeFile(join(root, directory, "Source.swift"), product);
      }
      const fingerprints = await Promise.all(
        consumers.map((definition) =>
          extensionFingerprint(root, definition, consumers),
        ),
      );
      const cacheKeys = await Promise.all(
        consumers.map((definition) =>
          supportCacheFingerprint(root, definition),
        ),
      );
      for (const [index, product] of products.entries()) {
        const path = `Packages/ExtensionSupport/Sources/${product}/Source.swift`;
        expect(
          planExtensionBuilds(consumers, [path]).map(({ id }) => id),
        ).toEqual(consumers.slice(index).map(({ id }) => id));
        await writeFile(join(root, path), `changed ${product}`);
        for (const [consumerIndex, definition] of consumers.entries()) {
          const fingerprint = await extensionFingerprint(
            root,
            definition,
            consumers,
          );
          const cacheKey = await supportCacheFingerprint(root, definition);
          if (consumerIndex >= index) {
            expect(fingerprint).not.toBe(fingerprints[consumerIndex]);
            expect(cacheKey).not.toBe(cacheKeys[consumerIndex]);
          } else {
            expect(fingerprint).toBe(fingerprints[consumerIndex]);
            expect(cacheKey).toBe(cacheKeys[consumerIndex]);
          }
        }
        await writeFile(join(root, path), product);
      }
      await writeFile(
        join(root, "scripts/build-extension-support.mjs"),
        "new builder",
      );
      for (const [index, definition] of consumers.entries()) {
        expect(
          await extensionFingerprint(root, definition, consumers),
        ).not.toBe(fingerprints[index]);
        expect(await supportCacheFingerprint(root, definition)).not.toBe(
          cacheKeys[index],
        );
      }
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
  test("rebuilds only the changed extension and its dependents", () => {
    expect(
      planExtensionBuilds(definitions, ["Extensions/music/Player.swift"]).map(
        ({ id }) => id,
      ),
    ).toEqual(["music", "shelf"]);
    expect(
      planExtensionBuilds(definitions, [
        "Extensions/calendar/Calendar.swift",
      ]).map(({ id }) => id),
    ).toEqual(["calendar"]);
  });

  test("a shared contract change rebuilds every consumer", () => {
    expect(
      planExtensionBuilds(definitions, [
        "Packages/ExtensionMarketplace/Sources/API.swift",
      ]),
    ).toEqual(definitions);
  });

  test("unrelated app and documentation changes publish no extension", () => {
    expect(
      planExtensionBuilds(definitions, [
        "README.md",
        "Packages/Edith/Sources/Edith/Features/Home/HomePage.swift",
      ]),
    ).toEqual([]);
  });

  test("deleted and renamed paths invalidate affected packages", () => {
    expect(
      planExtensionBuilds(definitions, [
        "Extensions/music/Old.swift",
        "Extensions/calendar/New.swift",
      ]).map(({ id }) => id),
    ).toEqual(["music", "calendar", "shelf"]);
  });

  test("does not match a sibling directory sharing the prefix", () => {
    expect(
      planExtensionBuilds(definitions, ["Extensions/musicVideo/Player.swift"]),
    ).toEqual([]);
  });

  test("rejects invalid identities and unresolved dependencies", () => {
    expect(() =>
      planExtensionBuilds([...definitions, definitions[0]], []),
    ).toThrow("Duplicate");
    expect(() =>
      planExtensionBuilds(
        [{ ...definitions[0], dependencies: ["missing"] }],
        [],
      ),
    ).toThrow("Unknown");
  });

  test("test-only changes do not publish new extension binaries", async () => {
    const { planUnpublishedExtensions } = await import(
      "./extension-release-plan.mjs"
    );
    const root = await mkdtemp(join(tmpdir(), "extension-test-inputs-"));
    const definition = {
      id: "calendar",
      version: "1.0.0",
      hostABI: "edith-host-1",
      inputs: ["Extensions/calendar"],
      sharedInputs: ["Packages/ExtensionSupport"],
      dependencies: [],
    };
    try {
      for (const directory of [
        "Extensions/calendar/Tests",
        "Packages/ExtensionSupport/Tests",
        "Packages/ExtensionSupport/Sources",
      ])
        await mkdir(join(root, directory), { recursive: true });
      await writeFile(
        join(root, "Extensions/calendar/Runtime.swift"),
        "production",
      );
      await writeFile(
        join(root, "Packages/ExtensionSupport/Sources/UI.swift"),
        "shared production",
      );
      const fingerprint = await extensionFingerprint(root, definition, [
        definition,
      ]);
      const published = [
        {
          id: "calendar",
          version: "1.0.0",
          hostABI: "edith-host-1",
          architecture: "arm64",
          sourceFingerprint: fingerprint,
        },
      ];
      await writeFile(
        join(root, "Extensions/calendar/Tests/CalendarTests.swift"),
        "new extension test",
      );
      await writeFile(
        join(root, "Packages/ExtensionSupport/Tests/UITests.swift"),
        "new shared test",
      );
      expect(await extensionFingerprint(root, definition, [definition])).toBe(
        fingerprint,
      );
      expect(
        await planUnpublishedExtensions(root, [definition], published),
      ).toEqual([]);
      await writeFile(
        join(root, "Packages/ExtensionSupport/Sources/UI.swift"),
        "changed shared production",
      );
      expect(
        (await planUnpublishedExtensions(root, [definition], published))[0]
          .version,
      ).toBe("1.0.1");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("fingerprints content and dependencies instead of commit timestamps", async () => {
    const root = await mkdtemp(join(tmpdir(), "extension-inputs-"));
    try {
      for (const path of [
        "Extensions/music",
        "Extensions/calendar",
        "Extensions/shelf",
        "Packages/ExtensionMarketplace",
      ])
        await mkdir(join(root, path), { recursive: true });
      await writeFile(join(root, "Extensions/music/Player.swift"), "first");
      await writeFile(
        join(root, "Extensions/calendar/Calendar.swift"),
        "calendar",
      );
      const music = await extensionFingerprint(
        root,
        definitions[0],
        definitions,
      );
      const calendar = await extensionFingerprint(
        root,
        definitions[1],
        definitions,
      );
      const shelf = await extensionFingerprint(
        root,
        definitions[2],
        definitions,
      );
      expect(
        await extensionFingerprint(root, definitions[0], definitions),
      ).toBe(music);
      await writeFile(join(root, "Extensions/music/Player.swift"), "second");
      expect(
        await extensionFingerprint(root, definitions[0], definitions),
      ).not.toBe(music);
      expect(
        await extensionFingerprint(root, definitions[1], definitions),
      ).toBe(calendar);
      expect(
        await extensionFingerprint(root, definitions[2], definitions),
      ).not.toBe(shelf);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});

test("publication resumes from released fingerprints after skipped workflow runs", async () => {
  const { planUnpublishedExtensions } = await import(
    "./extension-release-plan.mjs"
  );
  const root = await mkdtemp(join(tmpdir(), "extension-publication-"));
  const definition = {
    id: "calendar",
    version: "1.0.0",
    hostABI: "runtime-1",
    inputs: ["Extensions/calendar"],
    sharedInputs: [],
    dependencies: [],
  };
  try {
    await mkdir(join(root, "Extensions/calendar"), { recursive: true });
    await writeFile(join(root, "Extensions/calendar/Runtime.swift"), "first");
    const initial = await planUnpublishedExtensions(root, [definition], []);
    expect(initial[0].version).toBe("1.0.0");
    const published = [
      {
        id: "calendar",
        version: "1.0.0",
        hostABI: "runtime-1",
        architecture: "arm64",
        sourceFingerprint: initial[0].fingerprint,
      },
    ];
    expect(
      await planUnpublishedExtensions(root, [definition], published),
    ).toEqual([]);
    await mkdir(join(root, "Extensions/calendar/.build"));
    await writeFile(
      join(root, "Extensions/calendar/.build/ignored.o"),
      "compiler output",
    );
    expect(
      await planUnpublishedExtensions(root, [definition], published),
    ).toEqual([]);
    await writeFile(join(root, "Extensions/calendar/Runtime.swift"), "second");
    await writeFile(join(root, "Extensions/calendar/Runtime.swift"), "third");
    const pending = await planUnpublishedExtensions(
      root,
      [definition],
      published,
    );
    expect(pending[0].version).toBe("1.0.1");
    expect(pending[0].fingerprint).not.toBe(initial[0].fingerprint);
    expect(pending[0].tag).not.toBe(initial[0].tag);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("same-executable worker inputs rebuild consumers while host presentation changes remain independent", () => {
  const workers = definitions.map((entry) => ({
    ...entry,
    sameExecutableWorker: true,
  }));
  expect(
    planExtensionBuilds(workers, [
      "Packages/EdithHost/Sources/EdithHost/HostRemoteApplication.swift",
    ]).map((entry) => entry.id),
  ).toEqual(["music", "calendar", "shelf"]);
  expect(
    planExtensionBuilds(workers, [
      "Packages/EdithHost/Sources/EdithHost/HostSidebar.swift",
    ]),
  ).toEqual([]);
  expect(
    planExtensionBuilds(workers, ["Extensions/music/Track.swift"]).map(
      (entry) => entry.id,
    ),
  ).toEqual(["music", "shelf"]);
});

test("shared runtime fingerprints include code fixes and exclude generated legacy compatibility hashes", async () => {
  const root = await mkdtemp(join(tmpdir(), "extension-worker-inputs-"));
  const definition = {
    id: "calendar",
    inputs: ["Extensions/calendar"],
    sharedInputs: [],
    dependencies: [],
    sameExecutableWorker: true,
  };
  try {
    for (const path of workerRuntimeInputs) {
      if (
        path.endsWith(".swift") ||
        path.endsWith(".resolved") ||
        path.endsWith(".mjs") ||
        path.endsWith(".py")
      ) {
        await mkdir(join(root, path, ".."), { recursive: true });
        await writeFile(join(root, path), "synthetic source");
      } else {
        await mkdir(join(root, path), { recursive: true });
        await writeFile(
          join(root, path, "Synthetic.swift"),
          "synthetic source",
        );
      }
    }
    await mkdir(join(root, "Extensions/calendar"), { recursive: true });
    await writeFile(
      join(root, "Extensions/calendar/Calendar.swift"),
      "synthetic calendar",
    );
    const generated = join(
      root,
      "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift",
    );
    await writeFile(generated, "legacy hash one");
    const first = await extensionFingerprint(root, definition, [definition]);
    await writeFile(generated, "legacy hash two");
    expect(await extensionFingerprint(root, definition, [definition])).toBe(
      first,
    );
    await writeFile(
      join(
        root,
        "Packages/EdithHost/Sources/EdithHost/HostRemoteApplication.swift",
      ),
      "changed owned worker runtime",
    );
    expect(await extensionFingerprint(root, definition, [definition])).not.toBe(
      first,
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("role overrides fingerprint the complete selected SDK without changing unrelated consumers", async () => {
  const root = await mkdtemp(join(tmpdir(), "extension-role-support-"));
  const definition = {
    id: "documentsCLI",
    supportProduct: "EdithExtensionDocuments",
    supportProducts: {
      app: ["EdithExtensionDocuments", "EdithExtensionCommands"],
      helper: null,
    },
    inputs: [],
    sharedInputs: ["Packages/ExtensionSupport"],
    dependencies: [],
  };
  const coreOnly = {
    ...definition,
    id: "coreOnly",
    supportProduct: "EdithExtensionSupport",
    supportProducts: {},
  };
  const definitions = [definition, coreOnly];
  try {
    for (const product of [
      "EdithExtensionSupport",
      "EdithExtensionUI",
      "EdithExtensionDocuments",
      "EdithExtensionCommands",
      "EdithExtensionArchive",
    ]) {
      const directory = join(
        root,
        "Packages/ExtensionSupport/Sources",
        product,
      );
      await mkdir(directory, { recursive: true });
      await writeFile(join(directory, "Source.swift"), product);
    }
    await mkdir(join(root, "Packages/ExtensionSupport/Licenses"), {
      recursive: true,
    });
    await writeFile(
      join(
        root,
        "Packages/ExtensionSupport/Licenses/swift-argument-parser-license.txt",
      ),
      "license",
    );
    await mkdir(join(root, "scripts"), { recursive: true });
    await writeFile(
      join(root, "scripts/build-extension-support.mjs"),
      "builder",
    );
    const before = await extensionFingerprint(root, definition, definitions);
    const cache = await supportCacheFingerprint(root, definition);
    const core = await extensionFingerprint(root, coreOnly, definitions);
    expect(await supportCacheFingerprint(root, definition)).toBe(cache);
    const commandPath =
      "Packages/ExtensionSupport/Sources/EdithExtensionCommands/Source.swift";
    expect(
      planExtensionBuilds(definitions, [commandPath]).map(({ id }) => id),
    ).toEqual([definition.id]);
    await writeFile(join(root, commandPath), "updated command SDK");
    expect(await extensionFingerprint(root, definition, definitions)).not.toBe(
      before,
    );
    expect(await supportCacheFingerprint(root, definition)).not.toBe(cache);
    expect(await extensionFingerprint(root, coreOnly, definitions)).toBe(core);
    const updated = await extensionFingerprint(root, definition, definitions);
    const updatedCache = await supportCacheFingerprint(root, definition);
    await writeFile(
      join(
        root,
        "Packages/ExtensionSupport/Sources/EdithExtensionArchive/Source.swift",
      ),
      "unselected archive SDK",
    );
    expect(await extensionFingerprint(root, definition, definitions)).toBe(
      updated,
    );
    expect(await supportCacheFingerprint(root, definition)).toBe(updatedCache);
    const onlyOverride = { ...definition, supportProduct: null };
    expect(await supportCacheFingerprint(root, onlyOverride)).not.toBe("none");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
