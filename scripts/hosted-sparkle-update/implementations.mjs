import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { open, realpath } from "node:fs/promises";
import { join } from "node:path";

export const historicalSparkleSource =
  "4ed0a89210b89ba3dbe19f0283445c6a691d349e";
export const sparkleImplementationPaths = Object.freeze({
  "Packages/EdithHost/Sources/EdithHost/HostWorkflowOnboardingModel.swift":
    "61247102191f99c73a6b14383c4fa30956255d76",
  "Packages/EdithHost/Sources/EdithHost/HostWorkflowOnboardingView.swift":
    "d845bce13554b80f7e19ffe6a26a0474979dd426",
});
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const blob = (bytes) =>
  createHash("sha1")
    .update(`blob ${bytes.length}\0`)
    .update(bytes)
    .digest("hex");
const exact = (value, keys) =>
  assert.deepEqual(Object.keys(value).sort(), [...keys].sort());
const sha = (value, length) =>
  typeof value === "string" && new RegExp(`^[a-f0-9]{${length}}$`).test(value);

export function readSparkleImplementation(
  generation,
  sourceCommit,
  execute = execFileSync,
) {
  assert(["previous", "current"].includes(generation));
  assert(sha(sourceCommit, 40));
  assert.notEqual(sourceCommit, historicalSparkleSource);
  const commit =
    generation === "previous" ? historicalSparkleSource : sourceCommit;
  const sources = {};
  const metadata = {};
  for (const [path, pinnedBlob] of Object.entries(sparkleImplementationPaths)) {
    const inputPath =
      generation === "previous"
        ? `Tests/HostedSparkleUpdate/ImplementationSources/${path.split("/").at(-1)}`
        : path;
    const bytes = Buffer.from(
      execute("git", ["show", `${sourceCommit}:${inputPath}`], {
        maxBuffer: 1048576,
      }),
    );
    assert(bytes.length > 0 && bytes.length <= 1048576);
    const actualBlob = blob(bytes);
    assert.equal(
      execute("git", ["rev-parse", `${sourceCommit}:${inputPath}`], {
        encoding: "utf8",
      }).trim(),
      actualBlob,
    );
    if (generation === "previous") assert.equal(actualBlob, pinnedBlob);
    else assert.notEqual(actualBlob, pinnedBlob);
    sources[path] = bytes;
    metadata[path] = Object.freeze({ blob: actualBlob, sha256: hash(bytes) });
  }
  return Object.freeze({
    generation,
    sourceCommit: commit,
    baseSourceCommit: sourceCommit,
    sources: Object.freeze(sources),
    metadata: Object.freeze(metadata),
  });
}

export function sparkleChildEnvironment(environment) {
  assert(environment && typeof environment === "object");
  for (const key of ["PYTHONPATH", "PYTHONHOME", "NODE_OPTIONS", "NODE_PATH"])
    assert(
      environment[key] === undefined,
      "Ambient interpreter authority is forbidden",
    );
  const result = {};
  for (const key of [
    "PATH",
    "HOME",
    "CFFIXED_USER_HOME",
    "TMPDIR",
    "DEVELOPER_DIR",
    "LANG",
    "LC_ALL",
  ])
    if (environment[key] !== undefined) result[key] = environment[key];
  assert(typeof result.HOME === "string" && result.HOME.startsWith("/"));
  if (result.CFFIXED_USER_HOME !== undefined)
    assert.equal(result.CFFIXED_USER_HOME, result.HOME);
  return Object.freeze(result);
}

export async function verifySparkleImplementationCopy(
  directory,
  implementation,
) {
  exact(implementation.sources, Object.keys(sparkleImplementationPaths));
  exact(implementation.metadata, Object.keys(sparkleImplementationPaths));
  for (const path of Object.keys(sparkleImplementationPaths)) {
    const copied = join(directory, path.slice("Packages/EdithHost/".length));
    assert.equal(await realpath(copied), copied);
    const handle = await open(
      copied,
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
    try {
      const before = await handle.stat({ bigint: true });
      const expected = implementation.sources[path];
      assert(
        before.isFile() &&
          before.uid === BigInt(process.getuid()) &&
          before.nlink === 1n,
      );
      assert(
        before.size === BigInt(expected.length) &&
          expected.length > 0 &&
          expected.length <= 1048576,
      );
      const bytes = Buffer.alloc(expected.length + 1);
      let count = 0;
      while (count < bytes.length) {
        const row = await handle.read(bytes, count, bytes.length - count, null);
        if (row.bytesRead === 0) break;
        count += row.bytesRead;
      }
      const after = await handle.stat({ bigint: true });
      for (const key of [
        "dev",
        "ino",
        "size",
        "mode",
        "uid",
        "nlink",
        "mtimeNs",
        "ctimeNs",
      ])
        assert.equal(after[key], before[key]);
      assert.equal(count, expected.length);
      assert.deepEqual(bytes.subarray(0, count), expected);
      assert.deepEqual(implementation.metadata[path], {
        blob: blob(expected),
        sha256: hash(expected),
      });
    } finally {
      await handle.close();
    }
  }
}

export function sparkleExecutableIdentity(
  root,
  app,
  environment,
  execute = execFileSync,
) {
  const identity = JSON.parse(
    execute(
      "python3",
      [
        "-I",
        "-B",
        "-c",
        "import json,sys; sys.path.insert(0,sys.argv[1]); from macho_code_identity import executable_identity; print(json.dumps(executable_identity(sys.argv[2])))",
        join(root, "scripts"),
        join(app, "Contents/MacOS/Edith"),
      ],
      {
        encoding: "utf8",
        timeout: 40000,
        maxBuffer: 8192,
        env: sparkleChildEnvironment(environment),
      },
    ),
  );
  assert(sha(identity.signedSHA256, 64));
  assert(sha(identity.normalizedUnsignedSHA256, 64));
  assert.equal(
    identity.normalization,
    "arm64-terminal-linkedit-vmsize-after-verified-signature-removal-v1",
  );
  return identity;
}

export function validateSparkleImplementations(value, sourceCommit) {
  exact(value, ["composition", "baseSourceCommit", "previous", "current"]);
  assert.equal(value.composition, "current-base-with-historical-onboarding");
  assert.equal(value.baseSourceCommit, sourceCommit);
  assert(sha(sourceCommit, 40));
  assert.notEqual(sourceCommit, historicalSparkleSource);
  for (const generation of ["previous", "current"]) {
    const row = value[generation];
    exact(row, ["sourceCommit", "sources", "normalizedUnsignedSHA256"]);
    assert.equal(
      row.sourceCommit,
      generation === "previous" ? historicalSparkleSource : sourceCommit,
    );
    assert(sha(row.normalizedUnsignedSHA256, 64));
    exact(row.sources, Object.keys(sparkleImplementationPaths));
    for (const [path, pinnedBlob] of Object.entries(
      sparkleImplementationPaths,
    )) {
      const source = row.sources[path];
      exact(source, ["blob", "sha256"]);
      assert(sha(source.blob, 40) && sha(source.sha256, 64));
      if (generation === "previous") assert.equal(source.blob, pinnedBlob);
      else assert.notEqual(source.blob, pinnedBlob);
    }
  }
  assert.notEqual(
    value.previous.normalizedUnsignedSHA256,
    value.current.normalizedUnsignedSHA256,
  );
  for (const path of Object.keys(sparkleImplementationPaths)) {
    assert.notEqual(
      value.previous.sources[path].sha256,
      value.current.sources[path].sha256,
    );
  }
  return value;
}
