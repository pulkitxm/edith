import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
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
import { fileURLToPath } from "node:url";
import { hostABI, workerHostABI, writeHostABI } from "./extension-host-abi.mjs";

async function fixture(run) {
  const root = await mkdtemp(join(tmpdir(), "extension-host-contract-"));
  try {
    for (const module of [
      "EdithCore",
      "EdithDatabase",
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

test("isolated worker contracts survive unrelated legacy feature changes", async () => {
  await fixture(async ({ root, manifest }) => {
    await writeFile(
      manifest,
      JSON.stringify([
        { id: "isolated", contractVersion: 1, hostABI: "stale" },
        { id: "legacy", hostABI: "stale" },
      ]),
    );
    const previous = await writeHostABI(root);
    await writeFile(
      join(root, "Packages/Edith/Sources/EdithKit/Merged.swift"),
      "changed legacy feature",
    );
    const next = await writeHostABI(root);
    expect(next).not.toBe(previous);
    expect(
      JSON.parse(await readFile(manifest, "utf8")).map(
        (entry) => entry.hostABI,
      ),
    ).toEqual([workerHostABI, next]);
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

test("database interfaces invalidate legacy bundles without changing the worker contract", async () => {
  await fixture(async ({ root, manifest }) => {
    await writeFile(
      manifest,
      JSON.stringify([
        { id: "isolated", contractVersion: 1, hostABI: "stale" },
        { id: "legacy", hostABI: "stale" },
      ]),
    );
    const previous = await writeHostABI(root);
    await writeFile(
      join(root, "Packages/Edith/Sources/EdithDatabase/Surface.swift"),
      "changed database interface",
    );
    const next = await writeHostABI(root);
    expect(next).not.toBe(previous);
    expect(
      JSON.parse(await readFile(manifest, "utf8")).map(
        (entry) => entry.hostABI,
      ),
    ).toEqual([workerHostABI, next]);
  });
});

test("worker ABI preparation replaces an obsolete worker compatibility version", async () => {
  await fixture(async ({ root, configuration, manifest }) => {
    await writeFile(
      configuration,
      'public static let hostABI = "stale"\npublic static let workerHostABI = "edith-host-1"\n',
    );
    await writeFile(
      manifest,
      JSON.stringify([
        { id: "isolated", contractVersion: 1, hostABI: "edith-host-1" },
      ]),
    );
    await writeHostABI(root);
    expect(await readFile(configuration, "utf8")).toContain(
      `workerHostABI = "${workerHostABI}"`,
    );
    expect(JSON.parse(await readFile(manifest, "utf8"))[0].hostABI).toBe(
      workerHostABI,
    );
  });
});

test.each(["legacy source", "worker source", "worker manifest"])(
  "ABI preflight rejects stale %s without changing tracked inputs",
  async (stale) => {
    await fixture(async ({ root, configuration, manifest }) => {
      await writeFile(
        configuration,
        `public static let hostABI = "stale"\npublic static let workerHostABI = "${workerHostABI}"\n`,
      );
      await writeFile(
        manifest,
        JSON.stringify([
          { id: "isolated", contractVersion: 1, hostABI: workerHostABI },
          { id: "legacy", hostABI: "stale" },
        ]),
      );
      await writeHostABI(root);
      if (stale === "legacy source")
        await writeFile(
          join(root, "Packages/Edith/Sources/EdithKit/Changed.swift"),
          "changed legacy interface",
        );
      else if (stale === "worker source")
        await writeFile(
          configuration,
          (await readFile(configuration, "utf8")).replace(
            workerHostABI,
            "edith-host-1",
          ),
        );
      else
        await writeFile(
          manifest,
          (await readFile(manifest, "utf8")).replace(
            workerHostABI,
            "edith-host-1",
          ),
        );
      const files = [configuration, manifest];
      const before = await Promise.all(files.map((path) => readFile(path)));
      const timestamps = await Promise.all(files.map((path) => stat(path)));
      const check = () =>
        spawnSync(
          process.execPath,
          [
            fileURLToPath(new URL("./extension-host-abi.mjs", import.meta.url)),
            "--check",
            root,
          ],
          { cwd: root, encoding: "utf8", timeout: 10000, maxBuffer: 1048576 },
        );
      const rejected = check();
      expect(rejected.error).toBeUndefined();
      expect(rejected.status).toBe(1);
      expect(rejected.stderr).toContain("Host contract changed");
      for (let index = 0; index < files.length; index++) {
        expect(await readFile(files[index])).toEqual(before[index]);
        expect((await stat(files[index])).mtimeMs).toBe(
          timestamps[index].mtimeMs,
        );
      }
      const abi = await writeHostABI(root);
      const prepared = await Promise.all(files.map((path) => readFile(path)));
      const preparedTimes = await Promise.all(files.map((path) => stat(path)));
      for (let repeat = 0; repeat < 2; repeat++) {
        const accepted = check();
        expect(accepted.error).toBeUndefined();
        expect(accepted.status).toBe(0);
        expect(accepted.stdout.trim()).toBe(abi);
        expect(await writeHostABI(root)).toBe(abi);
        for (let index = 0; index < files.length; index++) {
          expect(await readFile(files[index])).toEqual(prepared[index]);
          expect((await stat(files[index])).mtimeMs).toBe(
            preparedTimes[index].mtimeMs,
          );
        }
      }
      expect(await readFile(configuration, "utf8")).toContain(
        `workerHostABI = "${workerHostABI}"`,
      );
      expect(JSON.parse(await readFile(manifest, "utf8"))[0].hostABI).toBe(
        workerHostABI,
      );
    });
  },
);
