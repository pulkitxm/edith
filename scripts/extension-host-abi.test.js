import { expect, test } from "bun:test";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hostABI, writeHostABI } from "./extension-host-abi.mjs";

async function fixture(run) {
  const root = await mkdtemp(join(tmpdir(), "extension-host-contract-"));
  try {
    for (const module of [
      "EdithCore",
      "EdithKit",
      "EdithShared",
      "EdithCameraSupport",
      "EdithLidAwakeSupport",
    ])
      await mkdir(join(root, "Packages/Edith/Sources", module), {
        recursive: true,
      });
    for (const directory of [
      "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace",
      "Extensions",
      "scripts",
    ])
      await mkdir(join(root, directory), { recursive: true });
    for (const path of [
      "Packages/Edith/Package.swift",
      "Packages/ExtensionMarketplace/Package.swift",
      "scripts/link-shared-framework.py",
      "scripts/extension-host-build.mjs",
    ])
      await writeFile(join(root, path), path);
    const configuration = join(
      root,
      "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift",
    );
    await writeFile(configuration, 'public static let hostABI = "stale"\n');
    const manifest = join(root, "Extensions/manifest.json");
    await writeFile(
      manifest,
      JSON.stringify([
        { id: "first", hostABI: "stale" },
        { id: "second", hostABI: "stale" },
      ]),
    );
    await run({ root, configuration, manifest });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("build preparation updates every package to the actual merged host source", async () => {
  await fixture(async ({ root, configuration, manifest }) => {
    const previous = await writeHostABI(root);
    await writeFile(
      join(root, "Packages/Edith/Sources/EdithKit/Merged.swift"),
      "public struct Merged {}\n",
    );
    const merged = await writeHostABI(root);
    expect(merged).not.toBe(previous);
    expect(await readFile(configuration, "utf8")).toContain(merged);
    expect(
      JSON.parse(await readFile(manifest, "utf8")).map(
        ({ hostABI }) => hostABI,
      ),
    ).toEqual([merged, merged]);
    expect(await hostABI(root)).toBe(merged);
  });
});

test("unchanged build preparation leaves source timestamps intact", async () => {
  await fixture(async ({ root, configuration, manifest }) => {
    const abi = await writeHostABI(root);
    const timestamps = await Promise.all([stat(configuration), stat(manifest)]);
    expect(await writeHostABI(root)).toBe(abi);
    expect((await stat(configuration)).mtimeMs).toBe(timestamps[0].mtimeMs);
    expect((await stat(manifest)).mtimeMs).toBe(timestamps[1].mtimeMs);
  });
});

test("SDK dependency changes invalidate the shared host contract", async () => {
  await fixture(async ({ root }) => {
    const previous = await hostABI(root);
    await writeFile(
      join(root, "Packages/ExtensionMarketplace/Package.swift"),
      "new dependency version",
    );
    expect(await hostABI(root)).not.toBe(previous);
  });
});

test("unrelated feature changes leave the shared contract unchanged", async () => {
  await fixture(async ({ root }) => {
    const previous = await hostABI(root);
    await mkdir(join(root, "Extensions/first"));
    await writeFile(
      join(root, "Extensions/first/Runtime.swift"),
      "changed runtime",
    );
    expect(await hostABI(root)).toBe(previous);
  });
});

test("build preparation refuses a missing host declaration", async () => {
  await fixture(async ({ root, configuration }) => {
    await writeFile(configuration, "invalid configuration");
    await expect(writeHostABI(root)).rejects.toThrow(
      "Missing host ABI declaration",
    );
  });
});
