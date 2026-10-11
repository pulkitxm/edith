import { execFileSync } from "node:child_process";
import { createHash, createPublicKey, verify } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { verifyCurrentMain } from "./extension-release-ready.mjs";
import { releaseAssetMatchesFile } from "./release-asset-read.mjs";
import {
  executeReleaseMutation,
  preflightReleaseAsset,
  uploadReleaseAsset,
} from "./release-asset-upload.mjs";
import { lookupRelease } from "./release-lookup.mjs";

const hostAssets = [
  "Edith.dmg",
  "appcast.xml",
  "host-release-proof.json",
  "build-metadata.json",
  "toolchain-provenance.json",
];

function assetSnapshot(directory) {
  return hostAssets
    .map((name) => {
      const file = resolve(directory, name);
      const status = lstatSync(file);
      if (
        !status.isFile() ||
        status.nlink !== 1 ||
        status.size < 1 ||
        status.size > (name === "Edith.dmg" ? 1024 ** 3 : 1024 ** 2)
      )
        throw new Error("Invalid bounded release asset");
      return createHash("sha256").update(readFileSync(file)).digest("hex");
    })
    .join(":");
}

function requireAssetSnapshot(directory, snapshot) {
  if (assetSnapshot(directory) !== snapshot)
    throw new Error("Host release assets changed after preflight");
}

export function preflightHostRelease({
  directory,
  repository,
  tag,
  source,
  rebuild = false,
  execute = execFileSync,
}) {
  if (
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) ||
    !/^v\d+\.\d+\.\d+$/.test(tag)
  )
    throw new Error("Invalid release identity");
  const snapshot = assetSnapshot(directory);
  const qualification = JSON.parse(
    execFileSync(
      "python3",
      [
        fileURLToPath(new URL("./host_release_assets.py", import.meta.url)),
        resolve(directory),
        "--repository",
        repository,
        "--tag",
        tag,
        "--source",
        source,
        ...(rebuild ? ["--rebuild"] : []),
      ],
      {
        encoding: "utf8",
        timeout: 60_000,
        killSignal: "SIGKILL",
        maxBuffer: 1024 ** 2,
        stdio: "pipe",
      },
    ),
  );
  const key = createPublicKey({
    key: Buffer.concat([
      Buffer.from("302a300506032b6570032100", "hex"),
      Buffer.from(qualification.sparklePublicKey, "base64"),
    ]),
    format: "der",
    type: "spki",
  });
  if (
    !verify(
      null,
      readFileSync(resolve(directory, "Edith.dmg")),
      key,
      Buffer.from(qualification.sparkleSignature, "base64"),
    )
  )
    throw new Error(
      "Appcast signature differs from the qualified Sparkle key or DMG",
    );
  for (const name of hostAssets) {
    preflightReleaseAsset({
      repository,
      file: resolve(directory, name),
      execute,
    });
  }
  requireAssetSnapshot(directory, snapshot);
  return [...hostAssets];
}

export async function publishHostRelease({
  directory,
  repository,
  tag,
  target,
  rebuild = false,
  sourceTarget = target,
  execute = execFileSync,
  matchesAsset = releaseAssetMatchesFile,
  verifySource = async () => {
    const current = await verifyCurrentMain({
      target: sourceTarget,
      releaseTag: tag,
      repository,
      fetchMetadata: async (url) =>
        new Response(
          execute("gh", ["api", url], {
            encoding: "utf8",
            timeout: 60_000,
            maxBuffer: 1024 ** 2,
          }),
        ),
    });
    if (current !== target)
      throw new Error("Host release target differs from verified current main");
  },
}) {
  if (!/^[0-9a-f]{40}$/.test(target)) throw new Error("Invalid release target");
  const snapshot = assetSnapshot(directory);
  const assets = preflightHostRelease({
    directory,
    repository,
    tag,
    source: sourceTarget,
    rebuild,
    execute,
  });
  const verifyInputs = async () => {
    await verifySource();
    requireAssetSnapshot(directory, snapshot);
  };
  const gh = (...args) =>
    execute("gh", args, {
      encoding: "utf8",
      timeout: 60_000,
      killSignal: "SIGKILL",
      maxBuffer: 1024 ** 2,
    });
  const mutate = (...args) =>
    executeReleaseMutation([...args, "--repo", repository], { execute });
  await verifyInputs();
  let release = lookupRelease({ repository, tag, execute });
  if (!release) {
    if (rebuild) throw new Error("Cannot rebuild a missing release");
    await verifyInputs();
    mutate(
      "release",
      "create",
      tag,
      "--name",
      `Edith ${tag}`,
      "--target",
      target,
      "--draft",
      "--generate-notes",
    );
    await verifyInputs();
    release = lookupRelease({ repository, tag, execute });
    if (!release) throw new Error("Created host release is not available");
  }
  const changes = [];
  for (const name of assets) {
    const file = resolve(directory, name);
    const matches = release.assets.filter((asset) => asset.name === name);
    if (matches.length > 1)
      throw new Error(`Ambiguous host release asset: ${name}`);
    const existing = matches[0];
    if (existing) {
      const identical = await matchesAsset({
        repository,
        asset: existing,
        file,
      });
      await verifyInputs();
      if (identical) continue;
      if (!release.draft)
        throw new Error(
          `Published host assets are immutable: ${name}. Publish a new version.`,
        );
      if (!rebuild) throw new Error(`Existing release asset differs: ${name}`);
    }
    if (!release.draft)
      throw new Error(
        `Published host asset is missing: ${name}. Publish a new version.`,
      );
    changes.push({ name, file, existing });
  }
  for (const { file, existing } of changes) {
    await verifyInputs();
    if (existing) {
      gh(
        "api",
        "--method",
        "DELETE",
        `repos/${repository}/releases/assets/${existing.id}`,
      );
      await verifyInputs();
    }
    await uploadReleaseAsset({
      repository,
      releaseID: release.id,
      tag,
      file,
      execute,
    });
    await verifyInputs();
  }
  await verifyInputs();
  if (!release.draft) return { tag, assets, unchanged: true };
  mutate(
    "release",
    "edit",
    String(release.id),
    "--draft",
    "false",
    "--make-latest",
    "true",
  );
  await verifyInputs();
  const published = lookupRelease({ repository, tag, execute });
  if (!published || published.draft || published.id !== release.id)
    throw new Error("Published host release state was not confirmed");
  return { tag, assets };
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  const preflight = process.argv[2] === "--preflight";
  const configuration = {
    directory: resolve(process.argv[preflight ? 3 : 2]),
    repository: process.env.GITHUB_REPOSITORY,
    tag: process.env.RELEASE_TAG,
    source: process.env.BUILT_SHA,
    rebuild: Boolean(process.env.REBUILD),
  };
  if (preflight) {
    preflightHostRelease(configuration);
    process.stdout.write("Release assets accepted by the release client.\n");
  } else {
    const target =
      process.env.RELEASE_TARGET_SHA ??
      execFileSync("git", ["-C", "release-source", "rev-parse", "HEAD"], {
        encoding: "utf8",
      }).trim();
    process.stdout.write(
      `${JSON.stringify(await publishHostRelease({ ...configuration, target, sourceTarget: process.env.BUILT_SHA ?? target, rebuild: Boolean(process.env.REBUILD) }))}\n`,
    );
  }
}
