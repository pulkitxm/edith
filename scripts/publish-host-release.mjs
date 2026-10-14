import { execFileSync } from "node:child_process";
import { createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { verifyCurrentMain } from "./extension-release-ready.mjs";
import { withGitHubRetrySync } from "./github-retry.mjs";
import {
  assetSnapshot,
  hostAssets,
  privateHostAssets,
  requireAssetSnapshot,
} from "./host-release-snapshot.mjs";
import { releaseAssetMatchesFile } from "./release-asset-read.mjs";
import {
  executeReleaseMutation,
  preflightReleaseAsset,
  uploadReleaseAsset,
} from "./release-asset-upload.mjs";
import { lookupRelease } from "./release-lookup.mjs";

export function hostReleasePrerelease(value = "false") {
  if (!["true", "false"].includes(value))
    throw new Error("Invalid host release channel");
  return value === "true";
}

function releaseInventory(release) {
  const names = new Set();
  const ids = new Set();
  for (const asset of release.assets) {
    if (names.has(asset.name) || ids.has(asset.id))
      throw new Error("Ambiguous host release asset");
    if (
      !hostAssets.includes(asset.name) ||
      !Number.isSafeInteger(asset.id) ||
      asset.id < 1 ||
      !Number.isSafeInteger(asset.size) ||
      asset.size < 1 ||
      asset.size > (asset.name === "Edith.dmg" ? 1024 ** 3 : 1024 ** 2) ||
      asset.state !== "uploaded"
    )
      throw new Error("Invalid host release inventory. Publish a new version.");
    names.add(asset.name);
    ids.add(asset.id);
  }
  return release.assets
    .map(({ id, name, size, state }) => [id, name, size, state])
    .sort((left, right) => left[1].localeCompare(right[1]));
}

export function preflightHostRelease({
  directory,
  repository,
  tag,
  source,
  rebuild = false,
  execute = execFileSync,
  retry = {},
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
      retry,
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
  prerelease = false,
  execute = execFileSync,
  retry = {},
  matchesAsset = releaseAssetMatchesFile,
  verifySource = async () => {
    const current = await verifyCurrentMain({
      target: sourceTarget,
      releaseTag: tag,
      repository,
      retry,
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
  if (typeof prerelease !== "boolean")
    throw new Error("Invalid host release channel");
  const copies = privateHostAssets(directory);
  try {
    const assets = preflightHostRelease({
      directory: copies.directory,
      repository,
      tag,
      source: sourceTarget,
      rebuild,
      execute,
      retry,
    });
    const verifyFiles = () => {
      requireAssetSnapshot(directory, copies.original);
      requireAssetSnapshot(copies.directory, copies.snapshot);
    };
    let tagIdentity;
    const verifyTag = () => {
      const read = (path) =>
        withGitHubRetrySync(
          () =>
            JSON.parse(
              execute("gh", ["api", `repos/${repository}/${path}`], {
                encoding: "utf8",
                timeout: 60_000,
                killSignal: "SIGKILL",
                maxBuffer: 1024 ** 2,
              }),
            ),
          retry,
        );
      const reference = read(`git/ref/tags/${tag}`);
      if (
        reference.ref !== `refs/tags/${tag}` ||
        !/^[a-f0-9]{40}$/.test(reference.object?.sha) ||
        !["commit", "tag"].includes(reference.object?.type)
      )
        throw new Error("Invalid host release tag reference");
      let commit = reference.object.sha;
      if (reference.object.type === "tag") {
        const annotated = read(`git/tags/${reference.object.sha}`);
        if (
          annotated.sha !== reference.object.sha ||
          annotated.tag !== tag ||
          annotated.object?.type !== "commit"
        )
          throw new Error("Invalid annotated host release tag");
        commit = annotated.object.sha;
      }
      const current = JSON.stringify([
        reference.ref,
        reference.object.type,
        reference.object.sha,
        commit,
      ]);
      if (
        commit !== target ||
        (tagIdentity !== undefined && tagIdentity !== current)
      )
        throw new Error("Host release tag source changed");
      tagIdentity = current;
    };
    const verifyInputs = async () => {
      await verifySource();
      verifyTag();
      verifyFiles();
    };
    const readRelease = () =>
      lookupRelease({ repository, tag, execute, retry });
    const requireIdentity = (value, draft, id) => {
      if (
        !value ||
        value.id !== id ||
        value.tag_name !== tag ||
        value.target_commitish !== target ||
        value.draft !== draft ||
        value.prerelease !== prerelease
      )
        throw new Error("Host release identity or draft state changed");
      releaseInventory(value);
      return value;
    };
    const requireStable = (expected) => {
      verifyTag();
      const current = requireIdentity(
        readRelease(),
        expected.draft,
        expected.id,
      );
      if (
        JSON.stringify(releaseInventory(current)) !==
        JSON.stringify(releaseInventory(expected))
      )
        throw new Error("Host release inventory changed concurrently");
      return current;
    };
    const guardSource = () => {
      const reference = withGitHubRetrySync(
        () =>
          JSON.parse(
            execute("gh", ["api", `repos/${repository}/git/ref/heads/main`], {
              encoding: "utf8",
              timeout: 60_000,
              killSignal: "SIGKILL",
              maxBuffer: 1024 ** 2,
            }),
          ),
        retry,
      );
      if (
        reference.ref !== "refs/heads/main" ||
        reference.object?.type !== "commit" ||
        reference.object.sha !== target
      )
        throw new Error(
          "App publication superseded: main moved after the release build",
        );
      verifyTag();
    };
    await verifyInputs();
    let release = readRelease();
    if (!release) {
      if (rebuild) throw new Error("Cannot rebuild a missing release");
      await verifyInputs();
      executeReleaseMutation(
        [
          "release",
          "create",
          tag,
          "--name",
          `Edith ${tag}`,
          "--target",
          target,
          "--draft",
          ...(prerelease ? ["--prerelease"] : []),
          "--generate-notes",
          "--repo",
          repository,
        ],
        {
          execute: (command, args, options) => {
            if (command === "pukbot") {
              guardSource();
              verifyFiles();
              if (readRelease())
                throw new Error("Host release appeared concurrently");
            }
            return execute(command, args, options);
          },
          retry,
        },
      );
      await verifyInputs();
      release = readRelease();
      if (!release) throw new Error("Created host release is not available");
    }
    requireIdentity(release, release.draft, release.id);
    const compareAsset = async (expected, existing) => {
      const local = copies.snapshot.find(
        (asset) => asset.name === existing.name,
      );
      const identical =
        existing.size === local.size &&
        (await matchesAsset({
          repository,
          asset: existing,
          file: resolve(copies.directory, existing.name),
        }));
      await verifyInputs();
      requireStable(expected);
      if (!identical)
        throw new Error(
          `Published host assets are immutable: ${existing.name}. Publish a new version.`,
        );
    };
    const compare = async (expected, complete) => {
      if (complete && expected.assets.length !== assets.length)
        throw new Error(
          "Host release asset is missing. Publish a new version.",
        );
      for (const name of assets) {
        const existing = expected.assets.find((asset) => asset.name === name);
        if (existing) await compareAsset(expected, existing);
      }
      await verifyInputs();
      requireStable(expected);
    };
    await compare(release, !release.draft);
    if (!release.draft) return { tag, assets, unchanged: true };
    for (const name of assets) {
      if (release.assets.some((asset) => asset.name === name)) continue;
      await verifyInputs();
      requireStable(release);
      await uploadReleaseAsset({
        repository,
        releaseID: release.id,
        tag,
        file: resolve(copies.directory, name),
        execute: (command, args, options) => {
          if (
            (command === "pukbot" && !args.includes("--dry-run")) ||
            (command === "gh" && args[0] === "release" && args[1] === "upload")
          ) {
            guardSource();
            verifyFiles();
            requireStable(release);
          }
          return execute(command, args, options);
        },
        retry,
      });
      await verifyInputs();
      const current = requireIdentity(readRelease(), true, release.id);
      const appended = current.assets.find((asset) => asset.name === name);
      if (
        !appended ||
        current.assets.length !== release.assets.length + 1 ||
        JSON.stringify(
          releaseInventory({
            assets: current.assets.filter((asset) => asset.name !== name),
          }),
        ) !== JSON.stringify(releaseInventory(release))
      )
        throw new Error("Host release inventory changed concurrently");
      await compareAsset(current, appended);
      release = current;
    }
    await compare(release, true);
    executeReleaseMutation(
      [
        "release",
        "edit",
        String(release.id),
        "--draft",
        "false",
        "--prerelease",
        String(prerelease),
        "--make-latest",
        String(!prerelease),
        "--repo",
        repository,
      ],
      {
        execute: (command, args, options) => {
          if (command === "pukbot") {
            guardSource();
            verifyFiles();
            requireStable(release);
          }
          return execute(command, args, options);
        },
        retry,
      },
    );
    await verifyInputs();
    const published = readRelease();
    if (!published || published.draft || published.id !== release.id)
      throw new Error("Published host release state was not confirmed");
    requireIdentity(published, false, release.id);
    if (
      JSON.stringify(releaseInventory(published)) !==
      JSON.stringify(releaseInventory(release))
    )
      throw new Error("Host release inventory changed concurrently");
    await compare(published, true);
    return { tag, assets };
  } finally {
    copies.cleanup();
  }
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
    prerelease: hostReleasePrerelease(process.env.RELEASE_PRERELEASE),
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
