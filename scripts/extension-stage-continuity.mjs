import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { isDeepStrictEqual } from "node:util";

const repository = "pulkitxm/edith";
const sha = /^[a-f0-9]{40}$/;
const digest = /^[a-f0-9]{64}$/;
const plistNames = ["Info.plist", "HelperInfo.plist"];

async function metadata(path) {
  assert(process.env.GITHUB_TOKEN, "Missing read-only release token");
  const response = await fetch(
    `https://api.github.com/repos/${repository}/${path}`,
    {
      headers: {
        Authorization: `Bearer ${process.env.GITHUB_TOKEN}`,
        Accept: "application/vnd.github+json",
        "Cache-Control": "no-cache",
      },
      cache: "no-store",
      signal: AbortSignal.timeout(60_000),
    },
  );
  assert(response.ok, "Release stamp metadata unavailable");
  assert.equal(new URL(response.url).origin, "https://api.github.com");
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      assert(size <= 2 * 1024 ** 2, "Release stamp metadata exceeds bound");
      chunks.push(Buffer.from(value));
    }
  } finally {
    await reader.cancel();
  }
  return JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)),
  );
}

function tree(value, expected) {
  assert.equal(value.sha, expected);
  assert.equal(value.truncated, false);
  assert(
    Array.isArray(value.tree) &&
      value.tree.length > 0 &&
      value.tree.length <= 512,
  );
  const entries = new Map();
  for (const row of value.tree) {
    assert(
      typeof row.path === "string" &&
        row.path.length > 0 &&
        row.path.length <= 256,
    );
    assert(
      !row.path.includes("/") &&
        !row.path.includes("\0") &&
        !entries.has(row.path),
    );
    assert(sha.test(row.sha));
    assert(["blob", "tree", "commit"].includes(row.type));
    assert(
      ["100644", "100755", "120000", "040000", "160000"].includes(row.mode),
    );
    entries.set(row.path, {
      path: row.path,
      type: row.type,
      mode: row.mode,
      sha: row.sha,
    });
  }
  return entries;
}

function unchangedExcept(before, after, names) {
  assert.deepEqual([...after.keys()].sort(), [...before.keys()].sort());
  for (const [name, row] of before) {
    const current = after.get(name);
    if (!names.includes(name)) {
      assert.deepEqual(
        current,
        row,
        "Release stamp changed unrelated tree entries",
      );
    } else {
      assert.equal(current.type, row.type);
      assert.equal(current.mode, row.mode);
      assert.notEqual(
        current.sha,
        row.sha,
        "Release stamp did not change required metadata",
      );
    }
  }
}

function blob(value, expected) {
  assert.equal(value.sha, expected);
  assert.equal(value.encoding, "base64");
  assert(
    Number.isSafeInteger(value.size) &&
      value.size > 0 &&
      value.size <= 1024 ** 2,
  );
  assert(
    typeof value.content === "string" && value.content.length <= 2 * 1024 ** 2,
  );
  const encoded = value.content.replace(/\n/g, "");
  const bytes = Buffer.from(encoded, "base64");
  assert.equal(bytes.toString("base64"), encoded);
  assert.equal(bytes.length, value.size);
  assert.equal(
    createHash("sha1")
      .update(`blob ${bytes.length}\0`)
      .update(bytes)
      .digest("hex"),
    expected,
    "Release stamp blob identity differs",
  );
  return bytes.toString("base64");
}

export function verifyReleaseStampPlists(values, version, build) {
  assert(Array.isArray(values) && values.length === 2);
  const input = Buffer.from(JSON.stringify({ values, version, build }));
  assert(input.length <= 6 * 1024 ** 2);
  const program =
    "import base64,json,plistlib,sys;v=json.load(sys.stdin);" +
    "assert len(v['values'])==2;" +
    "\nfor pair in v['values']:\n" +
    " before=plistlib.loads(base64.b64decode(pair['before'],validate=True));" +
    "after=plistlib.loads(base64.b64decode(pair['after'],validate=True));" +
    "assert isinstance(before,dict) and isinstance(after,dict);" +
    "expected=dict(before);expected.update(CFBundleShortVersionString=v['version'],CFBundleVersion=v['build']);" +
    "assert expected!=before and after==expected\n" +
    "print('version-stamp-only')";
  const environment = { PATH: process.env.PATH, LANG: "C" };
  if (process.env.DEVELOPER_DIR)
    environment.DEVELOPER_DIR = process.env.DEVELOPER_DIR;
  const result = spawnSync("python3", ["-I", "-B", "-c", program], {
    input,
    env: environment,
    timeout: 60_000,
    maxBuffer: 64 * 1024,
    encoding: "utf8",
  });
  assert.equal(
    result.status,
    0,
    "Release stamp changed nonversion plist fields",
  );
  assert.equal(result.stdout, "version-stamp-only\n");
}

export async function verifyCohortReleaseStamp(
  { source, host, proof, release },
  { fetchMetadata = metadata } = {},
) {
  assert(sha.test(source));
  assert.equal(host.source, source);
  assert(/^v[0-9]+\.[0-9]+\.[0-9]+$/.test(host.tag));
  assert.equal(host.tag, `v${host.version}`);
  assert(/^[0-9]{1,20}$/.test(String(host.build)));
  assert.equal(proof.sourceCommit, source);
  assert.equal(proof.version, host.version);
  assert.equal(String(proof.build), String(host.build));
  assert(digest.test(proof.dmgSHA256));
  assert(Number.isSafeInteger(release.id) && release.id > 0);
  assert.equal(release.tag_name, host.tag);
  assert.equal(release.draft, false);
  assert.equal(release.prerelease, true);
  const readMain = async () => {
    const ref = await fetchMetadata("git/ref/heads/main");
    assert.equal(ref.ref, "refs/heads/main");
    assert.equal(ref.object.type, "commit");
    assert(sha.test(ref.object.sha));
    return ref.object.sha;
  };
  const current = await readMain();
  assert.equal(
    release.target_commitish,
    current,
    "Public release target differs from its exact stamp",
  );
  assert.notEqual(
    current,
    source,
    "A completed cohort host requires its exact release stamp",
  );
  const tag = await fetchMetadata(
    `git/ref/tags/${encodeURIComponent(host.tag)}`,
  );
  assert.equal(tag.ref, `refs/tags/${host.tag}`);
  assert.equal(
    tag.object.type,
    "commit",
    "Require the raw lightweight release tag",
  );
  assert.equal(tag.object.sha, current);
  const original = await fetchMetadata(`git/commits/${source}`);
  const commit = await fetchMetadata(`git/commits/${current}`);
  assert.equal(original.sha, source);
  assert.equal(commit.sha, current);
  assert.deepEqual(
    commit.parents.map(({ sha }) => sha),
    [source],
  );
  assert.equal(commit.message.split("\n")[0], `Release ${host.tag} [skip ci]`);
  assert(sha.test(original.tree.sha) && sha.test(commit.tree.sha));
  const before = tree(
    await fetchMetadata(`git/trees/${original.tree.sha}`),
    original.tree.sha,
  );
  const after = tree(
    await fetchMetadata(`git/trees/${commit.tree.sha}`),
    commit.tree.sha,
  );
  unchangedExcept(before, after, ["Resources"]);
  assert.equal(before.get("Resources")?.type, "tree");
  assert.equal(before.get("Resources")?.mode, "040000");
  assert.equal(before.get("Casks")?.type, "tree");
  assert.equal(before.get("Casks")?.mode, "040000");
  assert(
    isDeepStrictEqual(before.get("Casks"), after.get("Casks")),
    "Stable cask changed",
  );
  const oldResources = tree(
    await fetchMetadata(`git/trees/${before.get("Resources").sha}`),
    before.get("Resources").sha,
  );
  const newResources = tree(
    await fetchMetadata(`git/trees/${after.get("Resources").sha}`),
    after.get("Resources").sha,
  );
  unchangedExcept(oldResources, newResources, plistNames);
  const values = [];
  for (const name of plistNames) {
    const oldEntry = oldResources.get(name);
    const newEntry = newResources.get(name);
    assert.equal(oldEntry?.type, "blob");
    assert.equal(oldEntry?.mode, "100644");
    values.push({
      before: blob(
        await fetchMetadata(`git/blobs/${oldEntry.sha}`),
        oldEntry.sha,
      ),
      after: blob(
        await fetchMetadata(`git/blobs/${newEntry.sha}`),
        newEntry.sha,
      ),
    });
  }
  verifyReleaseStampPlists(values, host.version, String(host.build));
  const finalTag = await fetchMetadata(
    `git/ref/tags/${encodeURIComponent(host.tag)}`,
  );
  assert.equal(finalTag.ref, `refs/tags/${host.tag}`);
  assert.equal(finalTag.object.type, "commit");
  assert.equal(
    finalTag.object.sha,
    current,
    "Release tag moved during admission",
  );
  assert.equal(
    await readMain(),
    current,
    "Release stamp source moved during admission",
  );
  return Object.freeze({
    source,
    continuation: current,
    tag: host.tag,
    releaseID: release.id,
  });
}
