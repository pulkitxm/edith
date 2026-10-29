import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
    mkdir,
    mkdtemp,
    readFile,
    rename,
    rm,
    symlink,
    writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
    extensionFingerprint,
    extensionReleaseTag,
    planExtensionBuilds,
    planPullRequestBuilds,
    planPullRequestExtensions,
    planUnpublishedExtensions,
    readPullRequestBaseline,
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

async function resolverLockFixture(run, repository = false) {
    const directory = await mkdtemp(
        join(tmpdir(), "extension-resolver-inputs-"),
    );
    let root = directory;
    const entries = [
        {
            id: "keepAwake",
            version: "1.0.0",
            hostABI: "edith-host-2",
            inputs: ["Extensions/keepAwake"],
            sharedInputs: [
                "Extensions/fixtureSupport",
                "Packages/EdithHost",
                "Packages/ExtensionSupport",
            ],
            dependencies: [],
        },
        {
            id: "follower",
            version: "1.0.0",
            hostABI: "edith-host-2",
            inputs: ["Extensions/follower"],
            sharedInputs: [],
            dependencies: ["keepAwake"],
        },
        {
            id: "independent",
            version: "1.0.0",
            hostABI: "edith-host-2",
            inputs: ["Extensions/independent"],
            sharedInputs: [],
            dependencies: [],
        },
    ];
    const generated = [
        "Extensions/keepAwake/Package.resolved",
        "Extensions/fixtureSupport/Package.resolved",
        "Extensions/keepAwake/NativeRuntime/Package.resolved",
    ];
    const git = (...args) =>
        execFileSync("git", args, { cwd: root, encoding: "utf8" });
    const fingerprints = () =>
        Promise.all(
            entries.map((entry) => extensionFingerprint(root, entry, entries)),
        );
    const published = (fingerprints) =>
        entries.map((entry, index) => ({
            ...entry,
            architecture: "arm64",
            sourceFingerprint: fingerprints[index],
        }));
    try {
        for (const path of [
            "Extensions/keepAwake/Runtime.swift",
            "Extensions/keepAwake/NativeRuntime/Engine.swift",
            "Extensions/fixtureSupport/Admission.swift",
            "Extensions/follower/Runtime.swift",
            "Extensions/independent/Runtime.swift",
            "Packages/EdithHost/Package.resolved",
            "Packages/ExtensionSupport/Package.resolved",
        ]) {
            await mkdir(join(root, path, ".."), { recursive: true });
            await writeFile(join(root, path), path);
        }
        if (repository) {
            git("init", "--quiet");
            git("add", ".");
            if (repository === "worktree") {
                git(
                    "-c",
                    "user.name=Synthetic Fixture",
                    "-c",
                    "user.email=fixture@example.test",
                    "commit",
                    "--quiet",
                    "-m",
                    "Resolver fixture",
                );
                git(
                    "worktree",
                    "add",
                    "--quiet",
                    "--detach",
                    join(directory, "linked"),
                );
                root = join(directory, "linked");
            }
        }
        await run({ root, entries, generated, git, fingerprints, published });
    } finally {
        await rm(directory, { recursive: true, force: true });
    }
}

describe("generated extension resolver locks", () => {
    test.each([false, true, "worktree"])(
        "resolver output keeps the pristine source plan stable with Git=%s",
        async (repository) => {
            await resolverLockFixture(async (fixture) => {
                const { root, entries, generated, fingerprints, published } =
                    fixture;
                const initial = await fingerprints();
                for (const path of generated)
                    await writeFile(join(root, path), '{"pins":[]}\n');
                expect(await fingerprints()).toEqual(initial);
                for (const path of generated)
                    await writeFile(
                        join(root, path),
                        '{"pins":["resolved"]}\n',
                    );
                expect(await fingerprints()).toEqual(initial);
                expect(
                    await planUnpublishedExtensions(
                        root,
                        entries,
                        published(initial),
                    ),
                ).toEqual([]);
                await writeFile(
                    join(root, "Extensions/fixtureSupport/Admission.swift"),
                    "changed production admission",
                );
                expect(
                    (
                        await planUnpublishedExtensions(
                            root,
                            entries,
                            published(initial),
                        )
                    ).map(({ id }) => id),
                ).toEqual(["keepAwake", "follower"]);
            }, repository);
        },
    );

    test.each([
        "Extensions/keepAwake/NativeRuntime/Package.resolved",
        "Extensions/Package.resolved",
    ])(
        "tracking %s and changing its physical bytes rebuilds its consumers",
        async (path) => {
            await resolverLockFixture(async (fixture) => {
                const { root, entries, git, fingerprints, published } = fixture;
                if (path === "Extensions/Package.resolved")
                    entries[0].sharedInputs.push("Extensions");
                const initial = await fingerprints();
                await writeFile(join(root, path), "reviewed dependency pins");
                expect(await fingerprints()).toEqual(initial);
                git("add", path);
                const tracked = await fingerprints();
                expect(tracked[0]).not.toBe(initial[0]);
                expect(tracked[1]).not.toBe(initial[1]);
                expect(tracked[2]).toBe(initial[2]);
                expect(
                    (
                        await planUnpublishedExtensions(
                            root,
                            entries,
                            published(initial),
                        )
                    ).map(({ id }) => id),
                ).toEqual(["keepAwake", "follower"]);
                await writeFile(
                    join(root, path),
                    "changed physical dependency pins",
                );
                expect(git("show", `:${path}`)).toBe(
                    "reviewed dependency pins",
                );
                const changed = await fingerprints();
                expect(changed[0]).not.toBe(tracked[0]);
                expect(changed[1]).not.toBe(tracked[1]);
                expect(changed[2]).toBe(tracked[2]);
                expect(
                    (
                        await planUnpublishedExtensions(
                            root,
                            entries,
                            published(tracked),
                        )
                    ).map(({ id }) => id),
                ).toEqual(["keepAwake", "follower"]);
            }, true);
        },
    );

    test.each(["Packages/EdithHost", "Packages/ExtensionSupport"])(
        "%s dependency pins retain their contribution without Git",
        async (directory) => {
            await resolverLockFixture(async ({ root, fingerprints }) => {
                const initial = await fingerprints();
                await writeFile(
                    join(root, directory, "Package.resolved"),
                    "changed dependency pins",
                );
                const changed = await fingerprints();
                expect(changed[0]).not.toBe(initial[0]);
                expect(changed[1]).not.toBe(initial[1]);
                expect(changed[2]).toBe(initial[2]);
            });
        },
    );

    test("an untracked extension resolver symlink cannot be ignored", async () => {
        await resolverLockFixture(async ({ root, generated, fingerprints }) => {
            await symlink(
                join(root, "Packages/EdithHost/Package.resolved"),
                join(root, generated[0]),
            );
            await expect(fingerprints()).rejects.toThrow(
                "Symlink in extension input",
            );
        });
    });
});

describe("independent extension releases", () => {
    test("Finder metadata does not rebuild extensions or their dependents", async () => {
        const root = await mkdtemp(join(tmpdir(), "extension-finder-inputs-"));
        const entries = [
            {
                id: "music",
                version: "1.0.0",
                hostABI: "host-1",
                inputs: ["Extensions/music"],
                sharedInputs: ["Packages/Shared"],
                dependencies: [],
            },
            {
                id: "shelf",
                version: "1.0.0",
                hostABI: "host-1",
                inputs: ["Extensions/shelf"],
                sharedInputs: [],
                dependencies: ["music"],
            },
        ];
        const metadata = [
            "Extensions/music/.DS_Store",
            "Extensions/music/Native/.DS_Store",
            "Packages/Shared/.DS_Store",
        ];
        try {
            for (const directory of [
                "Extensions/music/Native",
                "Extensions/shelf",
                "Packages/Shared",
            ])
                await mkdir(join(root, directory), { recursive: true });
            await writeFile(
                join(root, "Extensions/music/Runtime.swift"),
                "runtime",
            );
            await writeFile(
                join(root, "Extensions/shelf/Runtime.swift"),
                "shelf",
            );
            await writeFile(
                join(root, "Packages/Shared/Source.swift"),
                "shared",
            );
            const initial = await Promise.all(
                entries.map((entry) =>
                    extensionFingerprint(root, entry, entries),
                ),
            );
            for (const path of metadata)
                await writeFile(join(root, path), "synthetic Finder metadata");
            expect(
                await Promise.all(
                    entries.map((entry) =>
                        extensionFingerprint(root, entry, entries),
                    ),
                ),
            ).toEqual(initial);
            expect(planExtensionBuilds(entries, metadata)).toEqual([]);
            expect(planPullRequestBuilds(entries, metadata, entries)).toEqual(
                [],
            );
            const published = entries.map((entry, index) => ({
                id: entry.id,
                version: entry.version,
                hostABI: entry.hostABI,
                architecture: "arm64",
                sourceFingerprint: initial[index],
            }));
            expect(
                await planUnpublishedExtensions(root, entries, published),
            ).toEqual([]);
            await writeFile(
                join(root, "Extensions/music/Runtime.swift"),
                "changed runtime",
            );
            const changed = await planUnpublishedExtensions(
                root,
                entries,
                published,
            );
            expect(changed.map(({ id }) => id)).toEqual(["music", "shelf"]);
            for (const [index, row] of changed.entries())
                expect(row.fingerprint).not.toBe(initial[index]);
        } finally {
            await rm(root, { recursive: true, force: true });
        }
    });
    test("a new host contract republishes every extension at its version under a new release tag", async () => {
        const root = await mkdtemp(join(tmpdir(), "extension-abi-bump-"));
        const entry = (id, hostABI) => ({
            id,
            version: "1.0.7",
            hostABI,
            inputs: [`Extensions/${id}`],
            sharedInputs: [],
            dependencies: [],
            usesHostRuntime: false,
        });
        const previous = [
            entry("herdr", "edith-host-5"),
            entry("music", "edith-host-5"),
        ];
        const bumped = previous.map(({ id }) => entry(id, "edith-host-6"));
        try {
            for (const { id } of previous) {
                await mkdir(join(root, `Extensions/${id}`), {
                    recursive: true,
                });
                await writeFile(
                    join(root, `Extensions/${id}/Runtime.swift`),
                    id,
                );
            }
            const published = await Promise.all(
                previous.map(async (item) => ({
                    id: item.id,
                    version: item.version,
                    hostABI: item.hostABI,
                    architecture: "arm64",
                    sourceFingerprint: await extensionFingerprint(
                        root,
                        item,
                        previous,
                    ),
                })),
            );
            expect(
                await planUnpublishedExtensions(root, previous, published),
            ).toEqual([]);
            const plan = await planUnpublishedExtensions(
                root,
                bumped,
                published,
            );
            expect(plan.map(({ id, version }) => `${id}@${version}`)).toEqual([
                "herdr@1.0.7",
                "music@1.0.7",
            ]);
            for (const row of plan)
                expect(row.tag).not.toBe(
                    extensionReleaseTag({
                        id: row.id,
                        version: row.version,
                        fingerprint: published.find(({ id }) => id === row.id)
                            .sourceFingerprint,
                    }),
                );
        } finally {
            await rm(root, { recursive: true, force: true });
        }
    });
    test("immutable release identities include the version and exact source", () => {
        const identity = {
            id: "music",
            version: "1.0.0",
            fingerprint: "a".repeat(64),
        };
        expect(extensionReleaseTag(identity)).toBe(
            `extensions/music/1.0.0-${"a".repeat(20)}`,
        );
        expect(extensionReleaseTag({ ...identity, version: "1.0.1" })).not.toBe(
            extensionReleaseTag(identity),
        );
        for (const invalid of [
            { id: "../music" },
            { version: "1.0" },
            { version: "1.0.9007199254740992" },
            { fingerprint: "a".repeat(63) },
            { fingerprint: "g".repeat(64) },
        ])
            expect(() =>
                extensionReleaseTag({ ...identity, ...invalid }),
            ).toThrow("release identity");
    });
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
            await writeFile(
                join(root, definition.nativeCargo.manifest),
                "package",
            );
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
            expect(
                await extensionFingerprint(root, definition, [definition]),
            ).toBe(original);
            await writeFile(
                join(root, "Extensions/music/Native/Cargo.lock"),
                "new dependencies",
            );
            expect(
                await extensionFingerprint(root, definition, [definition]),
            ).not.toBe(original);
            const dependenciesChanged = await extensionFingerprint(
                root,
                definition,
                [definition],
            );
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
                    const cacheKey = await supportCacheFingerprint(
                        root,
                        definition,
                    );
                    if (consumerIndex >= index) {
                        expect(fingerprint).not.toBe(
                            fingerprints[consumerIndex],
                        );
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
                expect(
                    await supportCacheFingerprint(root, definition),
                ).not.toBe(cacheKeys[index]);
            }
        } finally {
            await rm(root, { recursive: true, force: true });
        }
    });
    test("rebuilds only the changed extension and its dependents", () => {
        expect(
            planExtensionBuilds(definitions, [
                "Extensions/music/Player.swift",
            ]).map(({ id }) => id),
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
                "apps/site/index.html",
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
            planExtensionBuilds(definitions, [
                "Extensions/musicVideo/Player.swift",
            ]),
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
        const { planUnpublishedExtensions } =
            await import("./extension-release-plan.mjs");
        const root = await mkdtemp(join(tmpdir(), "extension-test-inputs-"));
        const definition = {
            id: "music",
            version: "1.0.0",
            hostABI: "edith-host-1",
            inputs: ["Extensions/music"],
            sharedInputs: ["Packages/ExtensionSupport"],
            dependencies: [],
        };
        try {
            for (const directory of [
                "Extensions/music/Tests",
                "Extensions/music/EmbeddedTests",
                "Packages/ExtensionSupport/Tests",
                "Packages/ExtensionSupport/Sources",
            ])
                await mkdir(join(root, directory), { recursive: true });
            await writeFile(
                join(root, "Extensions/music/Runtime.swift"),
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
                    id: "music",
                    version: "1.0.0",
                    hostABI: "edith-host-1",
                    architecture: "arm64",
                    sourceFingerprint: fingerprint,
                },
            ];
            await writeFile(
                join(root, "Extensions/music/Tests/CalendarTests.swift"),
                "new extension test",
            );
            await writeFile(
                join(root, "Packages/ExtensionSupport/Tests/UITests.swift"),
                "new shared test",
            );
            await writeFile(
                join(root, "Extensions/music/EmbeddedTests/SceneTests.swift"),
                "new native scene test",
            );
            for (const name of [
                "test.mjs",
                "Makefile",
                "osv-scanner.toml",
                ".gitignore",
            ])
                await writeFile(
                    join(root, "Extensions/music", name),
                    "test only",
                );
            const { planSwiftTests } = await import("./ci-test-plan.mjs");
            expect(
                planSwiftTests([
                    "Extensions/music/EmbeddedTests/SceneTests.swift",
                ]).include,
            ).toEqual([
                {
                    lane: "extension-music",
                    extension: "music",
                    targets: "ci-extension-music",
                    ghostty: false,
                },
            ]);
            expect(
                await extensionFingerprint(root, definition, [definition]),
            ).toBe(fingerprint);
            expect(
                await planUnpublishedExtensions(root, [definition], published),
            ).toEqual([]);
            definition.testTargets = ["ci-extension-music"];
            expect(
                await extensionFingerprint(root, definition, [definition]),
            ).toBe(fingerprint);
            expect(
                await planUnpublishedExtensions(root, [definition], published),
            ).toEqual([]);
            await writeFile(
                join(root, "Packages/ExtensionSupport/Sources/UI.swift"),
                "changed shared production",
            );
            expect(
                (
                    await planUnpublishedExtensions(
                        root,
                        [definition],
                        published,
                    )
                )[0].version,
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
            await writeFile(
                join(root, "Extensions/music/Player.swift"),
                "first",
            );
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
            await writeFile(
                join(root, "Extensions/music/Player.swift"),
                "second",
            );
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
    const { planUnpublishedExtensions } =
        await import("./extension-release-plan.mjs");
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
        await writeFile(
            join(root, "Extensions/calendar/Runtime.swift"),
            "first",
        );
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
        await writeFile(
            join(root, "Extensions/calendar/Runtime.swift"),
            "second",
        );
        await writeFile(
            join(root, "Extensions/calendar/Runtime.swift"),
            "third",
        );
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

test("returning to earlier source publishes a new immutable version and then reuses it", async () => {
    const { planUnpublishedExtensions } =
        await import("./extension-release-plan.mjs");
    const root = await mkdtemp(join(tmpdir(), "extension-source-revert-"));
    const definition = {
        id: "calendar",
        version: "1.0.0",
        hostABI: "runtime-2",
        inputs: ["Extensions/calendar"],
        sharedInputs: [],
        dependencies: [],
    };
    const records = [];
    try {
        await mkdir(join(root, "Extensions/calendar"), { recursive: true });
        const plans = [];
        for (const source of ["first", "second", "first"]) {
            await writeFile(
                join(root, "Extensions/calendar/Runtime.swift"),
                source,
            );
            const [plan] = await planUnpublishedExtensions(
                root,
                [definition],
                records,
            );
            plans.push(plan);
            records.push({
                id: definition.id,
                hostABI: definition.hostABI,
                architecture: "arm64",
                version: plan.version,
                sourceFingerprint: plan.fingerprint,
            });
        }
        expect(plans.map(({ version }) => version)).toEqual([
            "1.0.0",
            "1.0.1",
            "1.0.2",
        ]);
        expect(plans[2].fingerprint).toBe(plans[0].fingerprint);
        expect(new Set(plans.map(({ tag }) => tag)).size).toBe(3);
        expect(
            await planUnpublishedExtensions(root, [definition], records),
        ).toEqual([]);
        const retry = await planUnpublishedExtensions(
            root,
            [definition],
            records.slice(0, 2),
        );
        expect(retry).toEqual([plans[2]]);
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
        await writeFile(
            join(root, "scripts/argument-parser-source.mjs"),
            await readFile("scripts/argument-parser-source.mjs"),
        );
        const before = await extensionFingerprint(
            root,
            definition,
            definitions,
        );
        const cache = await supportCacheFingerprint(root, definition);
        const core = await extensionFingerprint(root, coreOnly, definitions);
        expect(await supportCacheFingerprint(root, definition)).toBe(cache);
        const commandPath =
            "Packages/ExtensionSupport/Sources/EdithExtensionCommands/Source.swift";
        expect(
            planExtensionBuilds(definitions, [commandPath]).map(({ id }) => id),
        ).toEqual([definition.id]);
        await writeFile(join(root, commandPath), "updated command SDK");
        expect(
            await extensionFingerprint(root, definition, definitions),
        ).not.toBe(before);
        expect(await supportCacheFingerprint(root, definition)).not.toBe(cache);
        expect(await extensionFingerprint(root, coreOnly, definitions)).toBe(
            core,
        );
        const updated = await extensionFingerprint(
            root,
            definition,
            definitions,
        );
        const updatedCache = await supportCacheFingerprint(root, definition);
        await writeFile(
            join(root, "scripts/argument-parser-source.mjs"),
            `${await readFile("scripts/argument-parser-source.mjs", "utf8")}\n`,
        );
        expect(
            await extensionFingerprint(root, definition, definitions),
        ).not.toBe(updated);
        expect(await supportCacheFingerprint(root, definition)).not.toBe(
            updatedCache,
        );
        expect(await extensionFingerprint(root, coreOnly, definitions)).toBe(
            core,
        );
        const parserUpdated = await extensionFingerprint(
            root,
            definition,
            definitions,
        );
        const parserCache = await supportCacheFingerprint(root, definition);
        await writeFile(
            join(
                root,
                "Packages/ExtensionSupport/Sources/EdithExtensionArchive/Source.swift",
            ),
            "unselected archive SDK",
        );
        expect(await extensionFingerprint(root, definition, definitions)).toBe(
            parserUpdated,
        );
        expect(await supportCacheFingerprint(root, definition)).toBe(
            parserCache,
        );
        const onlyOverride = { ...definition, supportProduct: null };
        expect(await supportCacheFingerprint(root, onlyOverride)).not.toBe(
            "none",
        );
    } finally {
        await rm(root, { recursive: true, force: true });
    }
});

test("native private SDK consumers invalidate on every selected support source", async () => {
    const root = await mkdtemp(join(tmpdir(), "extension-native-support-"));
    const definition = {
        id: "attention",
        nativeSupportProduct: "EdithExtensionCommands",
        inputs: [],
        sharedInputs: [],
        dependencies: [],
    };
    try {
        for (const product of [
            "EdithExtensionSupport",
            "EdithExtensionUI",
            "EdithExtensionCommands",
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
        await writeFile(
            join(root, "scripts/argument-parser-source.mjs"),
            await readFile("scripts/argument-parser-source.mjs"),
        );
        const before = await extensionFingerprint(root, definition, [
            definition,
        ]);
        const cache = await supportCacheFingerprint(root, definition);
        expect(cache).not.toBe("none");
        expect(await supportCacheFingerprint(root, definition)).toBe(cache);
        const source =
            "Packages/ExtensionSupport/Sources/EdithExtensionCommands/Source.swift";
        expect(
            planExtensionBuilds([definition], [source]).map(({ id }) => id),
        ).toEqual([definition.id]);
        await writeFile(join(root, source), "updated commands");
        expect(
            await extensionFingerprint(root, definition, [definition]),
        ).not.toBe(before);
        expect(await supportCacheFingerprint(root, definition)).not.toBe(cache);
        const updated = await extensionFingerprint(root, definition, [
            definition,
        ]);
        const updatedCache = await supportCacheFingerprint(root, definition);
        await writeFile(
            join(root, "scripts/argument-parser-source.mjs"),
            `${await readFile("scripts/argument-parser-source.mjs", "utf8")}\n`,
        );
        expect(
            await extensionFingerprint(root, definition, [definition]),
        ).not.toBe(updated);
        expect(await supportCacheFingerprint(root, definition)).not.toBe(
            updatedCache,
        );
    } finally {
        await rm(root, { recursive: true, force: true });
    }
});

test("Database MCP tests run their owner without rebuilding the downloaded engine", async () => {
    const { planUnpublishedExtensions } =
        await import("./extension-release-plan.mjs");
    const { planSwiftTests } = await import("./ci-test-plan.mjs");
    const root = await mkdtemp(join(tmpdir(), "extension-mcp-test-inputs-"));
    const definition = {
        id: "database",
        version: "1.0.0",
        hostABI: "edith-host-2",
        inputs: ["Extensions/database"],
        sharedInputs: [],
        dependencies: [],
    };
    const testPath =
        "Extensions/database/DatabaseEngine/MCPTests/DatabaseMCPServerTests.swift";
    const sourcePath =
        "Extensions/database/DatabaseEngine/Sources/DatabaseMCP/DatabaseMCPServer.swift";
    try {
        for (const directory of [
            "Extensions/database/DatabaseEngine/MCPTests",
            "Extensions/database/DatabaseEngine/Sources/DatabaseMCP",
            "Extensions/database/MCPTests",
        ])
            await mkdir(join(root, directory), { recursive: true });
        await writeFile(join(root, testPath), "initial tests");
        await writeFile(join(root, sourcePath), "production engine");
        const fingerprint = await extensionFingerprint(root, definition, [
            definition,
        ]);
        const published = [
            {
                id: definition.id,
                version: definition.version,
                hostABI: definition.hostABI,
                architecture: "arm64",
                sourceFingerprint: fingerprint,
            },
        ];
        await writeFile(join(root, testPath), "changed MCP tests");
        expect(planSwiftTests([testPath]).include).toEqual([
            {
                lane: "extension-database",
                extension: "database",
                targets: "ci-extension-database",
                ghostty: false,
            },
        ]);
        expect(await extensionFingerprint(root, definition, [definition])).toBe(
            fingerprint,
        );
        expect(
            await planUnpublishedExtensions(root, [definition], published),
        ).toEqual([]);
        await writeFile(join(root, sourcePath), "changed production engine");
        expect(
            await extensionFingerprint(root, definition, [definition]),
        ).not.toBe(fingerprint);
        expect(
            (
                await planUnpublishedExtensions(root, [definition], published)
            ).map(({ id }) => id),
        ).toEqual(["database"]);
        const changedEngine = await extensionFingerprint(root, definition, [
            definition,
        ]);
        await writeFile(
            join(root, "Extensions/database/MCPTests/Production.swift"),
            "neighboring production path",
        );
        expect(
            await extensionFingerprint(root, definition, [definition]),
        ).not.toBe(changedEngine);
    } finally {
        await rm(root, { recursive: true, force: true });
    }
});

const pullRequestDefinitions = definitions.map((entry) => ({
    ...entry,
    version: "1.0.0",
    hostABI: "edith-host-2",
}));

async function pullRequestRepository(run, { legacy = false } = {}) {
    const root = await mkdtemp(join(tmpdir(), "extension-pr-plan-"));
    const git = (...arguments_) =>
        execFileSync(
            "git",
            [
                "-c",
                "user.name=Synthetic Fixture",
                "-c",
                "user.email=fixture@example.test",
                ...arguments_,
            ],
            { cwd: root, encoding: "utf8" },
        ).trim();
    const commit = async () => {
        git("add", ".");
        git("commit", "--quiet", "-m", "Fixture checkpoint");
        return git("rev-parse", "HEAD");
    };
    try {
        git("init", "--quiet");
        for (const entry of pullRequestDefinitions) {
            await mkdir(join(root, entry.inputs[0]), { recursive: true });
            await writeFile(
                join(root, entry.inputs[0], "Runtime.swift"),
                entry.id,
            );
        }
        await mkdir(join(root, "Packages/ExtensionMarketplace"), {
            recursive: true,
        });
        await writeFile(
            join(root, "Packages/ExtensionMarketplace/API.swift"),
            "contract",
        );
        if (!legacy)
            await writeFile(
                join(root, "Extensions/manifest.json"),
                JSON.stringify(pullRequestDefinitions),
            );
        const baseSHA = await commit();
        await run({ root, git, commit, baseSHA });
    } finally {
        await rm(root, { recursive: true, force: true });
    }
}

describe("pull request candidate planning", () => {
    test("the CLI refuses PR planning outside a pull request event before reading source", async () => {
        await pullRequestRepository(async ({ root, baseSHA }) => {
            const command = execFileSync;
            expect(() =>
                command(
                    process.execPath,
                    [
                        join(
                            process.cwd(),
                            "scripts/extension-release-plan.mjs",
                        ),
                        "--pull-request-base",
                        baseSHA,
                    ],
                    {
                        cwd: root,
                        env: { ...process.env, GITHUB_EVENT_NAME: "push" },
                        stdio: "pipe",
                    },
                ),
            ).toThrow("exact pull request event base");
        });
    });
    test("a single owner change includes only its transitive consumers", () => {
        expect(
            planPullRequestBuilds(
                pullRequestDefinitions,
                ["Extensions/music/Player.swift"],
                pullRequestDefinitions,
            ).map(({ id }) => id),
        ).toEqual(["music", "shelf"]);
    });
    test("test and generated inputs do not rebuild production packages", () => {
        for (const path of [
            "Extensions/music/Tests/PlayerTests.swift",
            "Extensions/music/tests/PlayerTests.swift",
            "Extensions/music/EmbeddedTests/PlayerTests.swift",
            "Extensions/music/.build/Player.swift",
            "Extensions/music/vendor/Player.swift",
            "Extensions/music/test.mjs",
            "Extensions/music/Makefile",
            "Extensions/music/Native/Makefile",
            "Extensions/music/Native/osv-scanner.toml",
            "Extensions/music/Native/.gitignore",
            "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift",
        ])
            expect(
                planPullRequestBuilds(
                    pullRequestDefinitions,
                    [path],
                    pullRequestDefinitions,
                ),
            ).toEqual([]);
        const database = [
            {
                id: "database",
                inputs: ["Extensions/database"],
                sharedInputs: [],
                dependencies: [],
            },
        ];
        expect(
            planPullRequestBuilds(
                database,
                [
                    "Extensions/database/DatabaseEngine/MCPTests/ServerTests.swift",
                ],
                database,
            ),
        ).toEqual([]);
        expect(
            planPullRequestBuilds(
                database,
                ["Extensions/database/MCPTests/Production.swift"],
                database,
            ),
        ).toEqual(database);
        for (const path of [
            "Extensions/music/Package.swift",
            "Extensions/music/Resources/test.mjs.json",
            "Extensions/music/Native/Cargo.toml",
        ])
            expect(
                planPullRequestBuilds(
                    pullRequestDefinitions,
                    [path],
                    pullRequestDefinitions,
                ).map(({ id }) => id),
            ).toEqual(["music", "shelf"]);
        expect(
            planPullRequestBuilds(
                pullRequestDefinitions,
                ["Packages/ExtensionMarketplace/Makefile"],
                pullRequestDefinitions,
            ).map(({ id }) => id),
        ).toEqual(["music", "calendar", "shelf"]);
    });
    test("manifest production rows select only the changed owner and consumers", () => {
        const next = structuredClone(pullRequestDefinitions);
        next[0].minimumSystemVersion = "15.0.0";
        expect(
            planPullRequestBuilds(
                next,
                ["Extensions/manifest.json"],
                pullRequestDefinitions,
            ).map(({ id }) => id),
        ).toEqual(["music", "shelf"]);
        next[0] = pullRequestDefinitions[0];
        next[1] = { ...next[1], testTargets: ["ci-calendar"] };
        expect(
            planPullRequestBuilds(
                next,
                ["Extensions/manifest.json"],
                pullRequestDefinitions,
            ),
        ).toEqual([]);
    });
    test("added owners are selected without rebuilding unrelated manifest rows", () => {
        const next = [
            ...pullRequestDefinitions,
            {
                ...pullRequestDefinitions[1],
                id: "newOwner",
                inputs: ["Extensions/newOwner"],
            },
        ];
        expect(
            planPullRequestBuilds(
                next,
                ["Extensions/manifest.json"],
                pullRequestDefinitions,
            ).map(({ id }) => id),
        ).toEqual(["newOwner"]);
    });
    test("changed shared SDK products rebuild only their dependency closure", () => {
        const consumers = [
            "EdithExtensionSupport",
            "EdithExtensionUI",
            "EdithExtensionDocuments",
            "EdithExtensionCommands",
        ].map((supportProduct, index) => ({
            id: `owner${index}`,
            inputs: [`Extensions/owner${index}`],
            sharedInputs: ["Packages/ExtensionSupport"],
            dependencies: [],
            supportProduct,
        }));
        expect(
            planPullRequestBuilds(
                consumers,
                [
                    "Packages/ExtensionSupport/Sources/EdithExtensionUI/Screen.swift",
                ],
                consumers,
            ).map(({ id }) => id),
        ).toEqual(["owner1", "owner2", "owner3"]);
        expect(
            planPullRequestBuilds(
                consumers,
                [
                    "Packages/ExtensionSupport/Sources/EdithExtensionSupport/Runtime.swift",
                ],
                consumers,
            ),
        ).toEqual(consumers);
    });
    test("marketplace runtime sources rebuild all consumers while host presentation changes remain independent", () => {
        const workers = pullRequestDefinitions.map((entry) => ({
            ...entry,
            usesHostRuntime: true,
        }));
        for (const path of [
            "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/ExtensionStore.swift",
            "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/ExtensionBundleRuntime.swift",
        ])
            expect(planPullRequestBuilds(workers, [path], workers)).toEqual(
                workers,
            );
        expect(
            planPullRequestBuilds(
                workers,
                ["Packages/EdithHost/Sources/EdithHost/HostHomePage.swift"],
                workers,
            ),
        ).toEqual([]);
    });
    test("the original legacy baseline selects all39 for the first extraction", async () => {
        const { readFile } = await import("node:fs/promises");
        const current = JSON.parse(
            await readFile("Extensions/manifest.json", "utf8"),
        );
        expect(current).toHaveLength(41);
        expect(planPullRequestBuilds(current, [], null)).toEqual(current);
        await pullRequestRepository(
            async ({ root, commit, baseSHA }) => {
                await writeFile(
                    join(root, "Extensions/manifest.json"),
                    JSON.stringify(pullRequestDefinitions),
                );
                await commit();
                const { priorDefinitions, changes } = readPullRequestBaseline(
                    root,
                    baseSHA,
                );
                expect(priorDefinitions).toBeNull();
                expect(
                    planPullRequestBuilds(current, changes, priorDefinitions),
                ).toEqual(current);
            },
            { legacy: true },
        );
    });
    test("exact git base reads include both sides of a rename and exclude unrelated sources", async () => {
        await pullRequestRepository(async ({ root, commit, baseSHA }) => {
            await rename(
                join(root, "Extensions/music/Runtime.swift"),
                join(root, "Extensions/calendar/Moved.swift"),
            );
            await writeFile(join(root, "README.md"), "presentation only");
            await commit();
            const baseline = readPullRequestBaseline(root, baseSHA);
            expect(baseline.changes).toContain(
                "Extensions/music/Runtime.swift",
            );
            expect(baseline.changes).toContain(
                "Extensions/calendar/Moved.swift",
            );
            expect(
                planPullRequestBuilds(
                    pullRequestDefinitions,
                    baseline.changes,
                    baseline.priorDefinitions,
                ),
            ).toEqual(pullRequestDefinitions);
        });
    });
    test("divergent event base tips use the branch point for both changes and manifest rows", async () => {
        await pullRequestRepository(async ({ root, git, commit, baseSHA }) => {
            const advanced = structuredClone(pullRequestDefinitions);
            advanced[1].minimumSystemVersion = "15.0.0";
            await writeFile(
                join(root, "Extensions/manifest.json"),
                JSON.stringify(advanced),
            );
            await writeFile(
                join(root, "Extensions/calendar/Runtime.swift"),
                "base-only calendar",
            );
            const eventBase = await commit();
            git("checkout", "--quiet", "--detach", baseSHA);
            await writeFile(
                join(root, "Extensions/music/Runtime.swift"),
                "candidate music",
            );
            await commit();
            expect(git("merge-base", "--all", eventBase, "HEAD")).toBe(baseSHA);
            const baseline = readPullRequestBaseline(root, eventBase);
            expect(baseline.priorDefinitions).toEqual(pullRequestDefinitions);
            expect(baseline.changes).toEqual([
                "Extensions/music/Runtime.swift",
            ]);
            const candidates = await planPullRequestExtensions(
                root,
                pullRequestDefinitions,
                eventBase,
            );
            expect(candidates.map(({ id }) => id)).toEqual(["music", "shelf"]);
            for (const candidate of candidates) {
                const definition = pullRequestDefinitions.find(
                    ({ id }) => id === candidate.id,
                );
                expect(candidate.fingerprint).toBe(
                    await extensionFingerprint(
                        root,
                        definition,
                        pullRequestDefinitions,
                    ),
                );
                expect(candidate.version).toBe(definition.version);
                expect(candidate.tag).toBe(extensionReleaseTag(candidate));
            }
        });
    });
    test("git planning rejects malformed absent noncommit and unrelated identities", async () => {
        await pullRequestRepository(async ({ root, git, baseSHA }) => {
            for (const value of [
                "",
                "main",
                "--all",
                "a".repeat(39),
                "g".repeat(40),
            ])
                expect(() => readPullRequestBaseline(root, value)).toThrow(
                    "Invalid pull request base",
                );
            expect(() =>
                readPullRequestBaseline(root, "0".repeat(40)),
            ).toThrow();
            const tree = git("rev-parse", `${baseSHA}^{tree}`);
            expect(() => readPullRequestBaseline(root, tree)).toThrow();
            const unrelated = git(
                "commit-tree",
                tree,
                "-m",
                "Unrelated fixture root",
            );
            expect(() => readPullRequestBaseline(root, unrelated)).toThrow();
        });
    });
    test("criss-cross histories fail closed when two verified merge bases exist", async () => {
        await pullRequestRepository(async ({ root, git, baseSHA }) => {
            const tree = git("rev-parse", `${baseSHA}^{tree}`);
            const left = git(
                "commit-tree",
                tree,
                "-p",
                baseSHA,
                "-m",
                "Left fixture",
            );
            const right = git(
                "commit-tree",
                tree,
                "-p",
                baseSHA,
                "-m",
                "Right fixture",
            );
            const eventBase = git(
                "commit-tree",
                tree,
                "-p",
                left,
                "-p",
                right,
                "-m",
                "Base fixture merge",
            );
            const head = git(
                "commit-tree",
                tree,
                "-p",
                right,
                "-p",
                left,
                "-m",
                "Head fixture merge",
            );
            git("checkout", "--quiet", "--detach", head);
            expect(
                git("merge-base", "--all", eventBase, head).split("\n").sort(),
            ).toEqual([left, right].sort());
            expect(() => readPullRequestBaseline(root, eventBase)).toThrow(
                "unique merge base",
            );
        });
    });
    test("malformed base manifests fail closed instead of producing an empty matrix", async () => {
        await pullRequestRepository(async ({ root, commit }) => {
            await writeFile(join(root, "Extensions/manifest.json"), "invalid");
            const invalid = await commit();
            await writeFile(
                join(root, "Extensions/manifest.json"),
                JSON.stringify(pullRequestDefinitions),
            );
            await commit();
            expect(() => readPullRequestBaseline(root, invalid)).toThrow();
            expect(() =>
                planPullRequestBuilds(pullRequestDefinitions, [], {}),
            ).toThrow("Invalid base");
            expect(() =>
                planPullRequestBuilds(
                    pullRequestDefinitions,
                    [],
                    [pullRequestDefinitions[0], pullRequestDefinitions[0]],
                ),
            ).toThrow("Duplicate");
        });
    });
    test("PR candidates use exact current fingerprints while catalog release planning still bumps published versions", async () => {
        await pullRequestRepository(async ({ root, commit, baseSHA }) => {
            const fingerprints = await Promise.all(
                pullRequestDefinitions.map((entry) =>
                    extensionFingerprint(root, entry, pullRequestDefinitions),
                ),
            );
            const published = pullRequestDefinitions.map((entry, index) => ({
                ...entry,
                architecture: "arm64",
                version: "1.0.7",
                sourceFingerprint: fingerprints[index],
            }));
            expect(
                await planUnpublishedExtensions(
                    root,
                    pullRequestDefinitions,
                    published,
                ),
            ).toEqual([]);
            await writeFile(
                join(root, "Extensions/music/Runtime.swift"),
                "changed engine",
            );
            await commit();
            const candidates = await planPullRequestExtensions(
                root,
                pullRequestDefinitions,
                baseSHA,
            );
            expect(candidates.map(({ id }) => id)).toEqual(["music", "shelf"]);
            expect(candidates.map(({ version }) => version)).toEqual([
                "1.0.0",
                "1.0.0",
            ]);
            expect(candidates[0].fingerprint).toBe(
                await extensionFingerprint(
                    root,
                    pullRequestDefinitions[0],
                    pullRequestDefinitions,
                ),
            );
            const releases = await planUnpublishedExtensions(
                root,
                pullRequestDefinitions,
                published,
            );
            expect(
                releases.map(({ id, version }) => ({ id, version })),
            ).toEqual([
                { id: "music", version: "1.0.8" },
                { id: "shelf", version: "1.0.8" },
            ]);
        });
    });
});
