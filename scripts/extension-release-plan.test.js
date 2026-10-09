import { describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  extensionFingerprint,
  planExtensionBuilds,
  supportCacheFingerprint,
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
