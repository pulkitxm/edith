import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { verifyCurrentMain } from "./extension-release-ready.mjs";
import { releaseAssetMatchesFile } from "./release-asset-read.mjs";
import {
  executeReleaseMutation,
  preflightReleaseAsset,
  uploadReleaseAsset,
} from "./release-asset-upload.mjs";
import { lookupRelease } from "./release-lookup.mjs";

export function preflightHostRelease({
  directory,
  repository,
  tag,
  execute = execFileSync,
}) {
  if (
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) ||
    !/^v\d+\.\d+\.\d+$/.test(tag)
  )
    throw new Error("Invalid release identity");
  const assets = ["Edith.dmg", "appcast.xml"];
  for (const name of assets) {
    if (statSync(resolve(directory, name)).size === 0)
      throw new Error("Empty release asset");
  }
  const appcast = readFileSync(resolve(directory, "appcast.xml"), "utf8");
  if (
    !appcast.includes(
      `https://github.com/${repository}/releases/download/${tag}/Edith.dmg`,
    ) ||
    !/sparkle:edSignature="[^"\s]+"/.test(appcast)
  )
    throw new Error("Invalid signed appcast");
  for (const name of assets) {
    preflightReleaseAsset({
      repository,
      file: resolve(directory, name),
      execute,
    });
  }
  return assets;
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
  const assets = preflightHostRelease({ directory, repository, tag, execute });
  const gh = (...args) =>
    execute("gh", args, {
      encoding: "utf8",
      timeout: 60_000,
      killSignal: "SIGKILL",
      maxBuffer: 1024 ** 2,
    });
  const mutate = (...args) =>
    executeReleaseMutation([...args, "--repo", repository], { execute });
  await verifySource();
  let release = lookupRelease({ repository, tag, execute });
  if (!release) {
    if (rebuild) throw new Error("Cannot rebuild a missing release");
    await verifySource();
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
    await verifySource();
    release = lookupRelease({ repository, tag, execute });
    if (!release) throw new Error("Created host release is not available");
  }
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
      await verifySource();
      if (identical) continue;
      if (!release.draft)
        throw new Error(
          `Published host assets are immutable: ${name}. Publish a new version.`,
        );
      if (!rebuild) throw new Error(`Existing release asset differs: ${name}`);
      await verifySource();
      gh(
        "api",
        "--method",
        "DELETE",
        `repos/${repository}/releases/assets/${existing.id}`,
      );
    }
    if (!release.draft)
      throw new Error(
        `Published host asset is missing: ${name}. Publish a new version.`,
      );
    await verifySource();
    await uploadReleaseAsset({
      repository,
      releaseID: release.id,
      tag,
      file,
      execute,
    });
    await verifySource();
  }
  await verifySource();
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
  await verifySource();
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
