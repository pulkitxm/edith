import { describe, expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildExtensionPackage } from "./build-extension-package.mjs";
import {
  ghosttyBuildInputs,
  ghosttyNativeFingerprint,
  ghosttyNativeInputs,
  recordGhosttyArtifacts,
  verifyExtensionNativeDependencies,
  verifyGhosttyArtifacts,
} from "./extension-ghostty-native.mjs";
import {
  extensionFingerprint,
  planExtensionBuilds,
  planUnpublishedExtensions,
} from "./extension-release-plan.mjs";

const architecture = process.arch === "arm64" ? "arm64" : "x86_64";
const toolchain = {
  platform: "darwin",
  architecture,
  zig: "0.16.0",
  sdk: "fixture",
};
const api = [
  "ghostty_config_new",
  "ghostty_surface_new",
  "ghostty_surface_free",
  "ghostty_surface_key",
  "ghostty_surface_external_output",
  "ghostty_surface_external_set_termios",
  "ghostty_surface_external_exit",
];
const consumer = (id) => ({
  id,
  version: "1.0.0",
  hostABI: "fixture",
  inputs: [`Extensions/${id}/Runtime.swift`],
  sharedInputs: [],
  dependencies: [],
  nativeProduct: "GhosttyTerminal",
  nativePackage: "Extensions/terminal/Native",
});

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "ghostty-native-cache-"));
  for (const path of ghosttyBuildInputs) {
    await mkdir(join(root, path, ".."), { recursive: true });
    await writeFile(join(root, path), `input:${path}`);
  }
  return root;
}

async function artifacts(root, exported = api) {
  const vendor = join(root, "Extensions/terminal/Native/vendor");
  const framework = join(vendor, "GhosttyKit.xcframework");
  const library = join(framework, `macos-${architecture}`);
  await mkdir(join(library, "Headers"), { recursive: true });
  await writeFile(
    join(framework, "Info.plist"),
    JSON.stringify({
      AvailableLibraries: [
        {
          LibraryIdentifier: `macos-${architecture}`,
          LibraryPath: "libghostty-internal.a",
          HeadersPath: "Headers",
          SupportedArchitectures: [architecture],
          SupportedPlatform: "macos",
        },
      ],
    }),
  );
  execFileSync("plutil", ["-convert", "xml1", join(framework, "Info.plist")]);
  await writeFile(
    join(library, "Headers/ghostty.h"),
    `ghostty_external_io_s ${api.join(" ")}`,
  );
  await writeFile(
    join(library, "Headers/module.modulemap"),
    "module GhosttyKit {}",
  );
  const source = join(root, "exports.c");
  await writeFile(
    source,
    exported.map((name) => `void ${name}(void) {}`).join("\n"),
  );
  execFileSync("xcrun", [
    "clang",
    "-mmacosx-version-min=14.0",
    "-c",
    source,
    "-o",
    join(root, "exports.o"),
  ]);
  await rm(join(library, "libghostty-internal.a"), { force: true });
  execFileSync("xcrun", [
    "ar",
    "rcs",
    join(library, "libghostty-internal.a"),
    join(root, "exports.o"),
  ]);
  for (const path of [
    "GhosttyResources/ghostty/shell-integration/zsh/ghostty-integration",
    "GhosttyResources/terminfo/78/xterm-ghostty",
  ]) {
    await mkdir(join(vendor, path, ".."), { recursive: true });
    await writeFile(join(vendor, path), "synthetic resource");
  }
  return vendor;
}

const nativeTest = process.platform === "darwin" ? test : test.skip;

describe("verified native cache", () => {
  nativeTest(
    "production build gate reuses unchanged artifacts and propagates patch-triggered rebuild failure",
    async () => {
      const root = await fixture();
      try {
        for (const path of ghosttyBuildInputs) {
          await copyFile(path, join(root, path));
        }
        await artifacts(root);
        await recordGhosttyArtifacts(
          root,
          await ghosttyNativeFingerprint(root),
        );
        const tools = join(root, "tools");
        await mkdir(tools);
        const marker = join(root, "rebuild-attempted");
        await writeFile(
          join(tools, "git"),
          '#!/bin/sh\nprintf rebuild > "$GHOSTTY_REBUILD_MARKER"\nexit 23\n',
          { mode: 0o755 },
        );
        const options = {
          cwd: root,
          encoding: "utf8",
          env: {
            ...process.env,
            PATH: `${tools}:${process.env.PATH}`,
            GHOSTTY_REBUILD_MARKER: marker,
          },
        };
        const unchanged = spawnSync(
          "bash",
          ["scripts/build-ghostty.sh", "--extension-only"],
          options,
        );
        expect(unchanged.status).toBe(0);
        expect(unchanged.stdout).toContain(
          "Reusing verified Ghostty native fingerprint",
        );
        await expect(readFile(marker)).rejects.toThrow();
        const patch = join(root, "scripts/patches/ghostty-external-io.patch");
        await writeFile(patch, `${await readFile(patch, "utf8")}\n`);
        const changed = spawnSync(
          "bash",
          ["scripts/build-ghostty.sh", "--extension-only"],
          options,
        );
        expect(changed.status).toBe(23);
        expect(await readFile(marker, "utf8")).toBe("rebuild");
        expect(changed.stdout).not.toContain("Reusing verified");
        await expect(
          verifyGhosttyArtifacts(root, await ghosttyNativeFingerprint(root)),
        ).rejects.toThrow("Stale Ghostty");
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    },
  );

  nativeTest(
    "unchanged input reuses a verified archive; source, pin, toolchain and architecture invalidate",
    async () => {
      const root = await fixture();
      try {
        await artifacts(root);
        const fingerprint = await ghosttyNativeFingerprint(root, toolchain);
        await recordGhosttyArtifacts(root, fingerprint);
        await verifyGhosttyArtifacts(
          root,
          await ghosttyNativeFingerprint(root, toolchain),
        );
        const receipt = await readFile(
          join(root, "Extensions/terminal/Native/vendor/.ghostty-native.json"),
          "utf8",
        );
        await verifyGhosttyArtifacts(root, fingerprint);
        expect(
          await readFile(
            join(
              root,
              "Extensions/terminal/Native/vendor/.ghostty-native.json",
            ),
            "utf8",
          ),
        ).toBe(receipt);
        for (const path of ghosttyBuildInputs) {
          const original = await readFile(join(root, path), "utf8");
          await writeFile(
            join(root, path),
            `${original}\nchanged pin or source`,
          );
          const changed = await ghosttyNativeFingerprint(root, toolchain);
          expect(changed).not.toBe(fingerprint);
          await expect(verifyGhosttyArtifacts(root, changed)).rejects.toThrow(
            "Stale Ghostty",
          );
          await writeFile(join(root, path), original);
        }
        for (const change of [
          { zig: "changed" },
          { sdk: "changed" },
          { architecture: "other" },
        ]) {
          expect(
            await ghosttyNativeFingerprint(root, { ...toolchain, ...change }),
          ).not.toBe(fingerprint);
        }
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    },
  );

  nativeTest(
    "missing API symbols cannot acquire a receipt; partial and modified resources fail verification",
    async () => {
      const root = await fixture();
      try {
        const vendor = await artifacts(root, api.slice(0, -1));
        const fingerprint = await ghosttyNativeFingerprint(root, toolchain);
        await expect(recordGhosttyArtifacts(root, fingerprint)).rejects.toThrow(
          "Missing Ghostty symbol",
        );
        await expect(
          readFile(join(vendor, ".ghostty-native.json")),
        ).rejects.toThrow();
        await artifacts(root);
        await recordGhosttyArtifacts(root, fingerprint);
        const terminfo = join(
          vendor,
          "GhosttyResources/terminfo/78/xterm-ghostty",
        );
        await writeFile(terminfo, "corrupted resource");
        await expect(verifyGhosttyArtifacts(root, fingerprint)).rejects.toThrow(
          "contents differ",
        );
        await rm(terminfo);
        await expect(
          verifyGhosttyArtifacts(root, fingerprint),
        ).rejects.toThrow();
        await expect(
          recordGhosttyArtifacts(root, fingerprint),
        ).rejects.toThrow();
        await artifacts(root);
        await rm(
          join(
            vendor,
            "GhosttyKit.xcframework",
            `macos-${architecture}`,
            "Headers/module.modulemap",
          ),
        );
        await expect(
          recordGhosttyArtifacts(root, fingerprint),
        ).rejects.toThrow();
        await expect(
          verifyGhosttyArtifacts(root, fingerprint, "other"),
        ).rejects.toThrow();
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    },
  );

  nativeTest(
    "packaging rejects absent native receipt before touching host, staging or signing",
    async () => {
      const root = await fixture();
      try {
        await writeFile(
          join(root, "Extensions/manifest.json"),
          JSON.stringify([consumer("terminal")]),
        );
        await expect(
          buildExtensionPackage({
            root,
            id: "terminal",
            containedHostApp: "/nonexistent-synthetic-host.app",
          }),
        ).rejects.toThrow(".ghostty-native.json");
        await expect(
          readFile(join(root, "dist/extensions/.staging/terminal")),
        ).rejects.toThrow();
        await verifyExtensionNativeDependencies(root, {
          nativeProduct: "Unrelated",
        });
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    },
  );

  test("patch and native source select all declared consumers and dependents, never unrelated extensions", async () => {
    const root = await fixture();
    const consumers = ["terminal", "machines", "herdr", "quinjet"].map(
      consumer,
    );
    const unrelated = {
      id: "calendar",
      version: "1.0.0",
      hostABI: "fixture",
      inputs: ["Extensions/calendar"],
      sharedInputs: [],
      dependencies: [],
    };
    const dependent = {
      ...unrelated,
      id: "dependent",
      inputs: ["Extensions/dependent"],
      dependencies: ["machines"],
    };
    const definitions = [...consumers, unrelated, dependent];
    try {
      for (const { id } of definitions) {
        await mkdir(join(root, `Extensions/${id}`), { recursive: true });
        await writeFile(
          join(root, `Extensions/${id}/Runtime.swift`),
          "synthetic source",
        );
      }
      const published = await Promise.all(
        definitions.map(async (definition) => ({
          id: definition.id,
          version: definition.version,
          hostABI: definition.hostABI,
          architecture: "arm64",
          sourceFingerprint: await extensionFingerprint(
            root,
            definition,
            definitions,
          ),
        })),
      );
      expect(
        await planUnpublishedExtensions(root, definitions, published),
      ).toEqual([]);
      const nativeFingerprint = await ghosttyNativeFingerprint(root, toolchain);
      const patch = "scripts/patches/ghostty-external-io.patch";
      expect(
        planExtensionBuilds(definitions, [patch]).map(({ id }) => id),
      ).toEqual([...consumers.map(({ id }) => id), "dependent"]);
      expect(
        planExtensionBuilds(definitions, [
          "Extensions/terminal/Native/Sources/GhosttyTerminal/Surface.swift",
        ]).map(({ id }) => id),
      ).toEqual([...consumers.map(({ id }) => id), "dependent"]);
      await writeFile(join(root, patch), "changed maintained patch");
      expect(await ghosttyNativeFingerprint(root, toolchain)).not.toBe(
        nativeFingerprint,
      );
      const releases = await planUnpublishedExtensions(
        root,
        definitions,
        published,
      );
      expect(releases.map(({ id }) => id)).toEqual([
        ...consumers.map(({ id }) => id),
        "dependent",
      ]);
      expect(releases.every(({ version }) => version === "1.0.1")).toBe(true);
      expect(ghosttyNativeInputs(unrelated)).toEqual([]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
