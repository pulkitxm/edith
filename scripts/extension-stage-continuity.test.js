import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { verifyCohortReleaseStamp } from "./extension-stage-continuity.mjs";

const source = "a".repeat(40);
const continuation = "b".repeat(40);

function fixture() {
  const host = { source, tag: "v0.0.320", version: "0.0.320", build: "331" };
  const proof = {
    sourceCommit: source,
    version: host.version,
    build: host.build,
    dmgSHA256: "1".repeat(64),
  };
  const release = {
    id: 101,
    tag_name: host.tag,
    target_commitish: continuation,
    draft: false,
    prerelease: true,
  };
  const documents = new Map();
  function addBlob(bytes) {
    const sha = createHash("sha1")
      .update(`blob ${bytes.length}\0`)
      .update(bytes)
      .digest("hex");
    documents.set(`git/blobs/${sha}`, {
      sha,
      size: bytes.length,
      encoding: "base64",
      content: bytes.toString("base64"),
    });
    return sha;
  }
  function plist(version, build, extra = "Edith") {
    return Buffer.from(
      `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>${version}</string><key>CFBundleVersion</key><string>${build}</string><key>CFBundleExecutable</key><string>${extra}</string></dict></plist>`,
    );
  }
  const before = addBlob(plist("0.0.319", "330"));
  const after = addBlob(plist(host.version, host.build));
  const row = (path, type, mode, sha) => ({ path, type, mode, sha });
  const oldRoot = "c".repeat(40),
    newRoot = "d".repeat(40);
  const oldResources = "e".repeat(40),
    newResources = "f".repeat(40);
  for (const [root, resources] of [
    [oldRoot, oldResources],
    [newRoot, newResources],
  ]) {
    documents.set(`git/trees/${root}`, {
      sha: root,
      truncated: false,
      tree: [
        row("Resources", "tree", "040000", resources),
        row("Casks", "tree", "040000", "2".repeat(40)),
        row("Sources", "tree", "040000", "3".repeat(40)),
      ],
    });
  }
  for (const [resources, sha] of [
    [oldResources, before],
    [newResources, after],
  ]) {
    documents.set(`git/trees/${resources}`, {
      sha: resources,
      truncated: false,
      tree: [
        row("Info.plist", "blob", "100644", sha),
        row("HelperInfo.plist", "blob", "100644", sha),
        row("icon.png", "blob", "100644", "4".repeat(40)),
      ],
    });
  }
  documents.set("git/ref/heads/main", {
    ref: "refs/heads/main",
    object: { type: "commit", sha: continuation },
  });
  documents.set(`git/ref/tags/${host.tag}`, {
    ref: `refs/tags/${host.tag}`,
    object: { type: "commit", sha: continuation },
  });
  documents.set(`git/commits/${source}`, {
    sha: source,
    tree: { sha: oldRoot },
    parents: [],
    message: "Reviewed implementation",
  });
  documents.set(`git/commits/${continuation}`, {
    sha: continuation,
    tree: { sha: newRoot },
    parents: [{ sha: source }],
    message: `Release ${host.tag} [skip ci]`,
  });
  const requests = [];
  const fetchMetadata = async (path) => {
    requests.push(path);
    expect(documents.has(path)).toBe(true);
    return structuredClone(documents.get(path));
  };
  return {
    input: { source, host, proof, release },
    documents,
    requests,
    fetchMetadata,
    addBlob,
    plist,
    oldResources,
    newResources,
    newRoot,
  };
}

test("exact single-parent prerelease stamp preserves source code and stable cask", async () => {
  const value = fixture();
  expect(await verifyCohortReleaseStamp(value.input, value)).toEqual({
    source,
    continuation,
    tag: "v0.0.320",
    releaseID: 101,
  });
  expect(
    value.requests.filter((path) => path === "git/ref/heads/main"),
  ).toHaveLength(2);
  expect(value.requests.some((path) => path.includes("recursive"))).toBe(false);
});

test.each([
  [
    "wrong public source",
    (value) => {
      value.input.proof.sourceCommit = "9".repeat(40);
    },
  ],
  [
    "wrong build",
    (value) => {
      value.input.proof.build = "332";
    },
  ],
  [
    "draft release",
    (value) => {
      value.input.release.draft = true;
    },
  ],
  [
    "stable release",
    (value) => {
      value.input.release.prerelease = false;
    },
  ],
  [
    "source without stamp",
    (value) => {
      value.documents.get("git/ref/heads/main").object.sha = source;
    },
  ],
  [
    "annotated tag",
    (value) => {
      value.documents.get("git/ref/tags/v0.0.320").object.type = "tag";
    },
  ],
  [
    "tag not current main",
    (value) => {
      value.documents.get("git/ref/tags/v0.0.320").object.sha = "9".repeat(40);
    },
  ],
  [
    "merge stamp",
    (value) => {
      value.documents
        .get(`git/commits/${continuation}`)
        .parents.push({ sha: "9".repeat(40) });
    },
  ],
  [
    "second stamp",
    (value) => {
      value.documents.get(`git/commits/${continuation}`).parents[0].sha =
        "9".repeat(40);
    },
  ],
  [
    "wrong subject",
    (value) => {
      value.documents.get(`git/commits/${continuation}`).message =
        "Unreviewed stamp";
    },
  ],
  [
    "stable cask changed",
    (value) => {
      value.documents.get(`git/trees/${value.newRoot}`).tree[1].sha =
        "9".repeat(40);
    },
  ],
  [
    "implementation changed",
    (value) => {
      value.documents.get(`git/trees/${value.newRoot}`).tree[2].sha =
        "9".repeat(40);
    },
  ],
  [
    "other resources changed",
    (value) => {
      value.documents.get(`git/trees/${value.newResources}`).tree[2].sha =
        "9".repeat(40);
    },
  ],
  [
    "unchanged helper version",
    (value) => {
      value.documents.get(`git/trees/${value.newResources}`).tree[1].sha =
        value.documents.get(`git/trees/${value.oldResources}`).tree[1].sha;
    },
  ],
  [
    "plist mode changed",
    (value) => {
      value.documents.get(`git/trees/${value.newResources}`).tree[1].mode =
        "100755";
    },
  ],
  [
    "duplicate tree name",
    (value) => {
      const tree = value.documents.get(`git/trees/${value.newResources}`).tree;
      tree.push(tree[0]);
    },
  ],
  [
    "truncated tree",
    (value) => {
      value.documents.get(`git/trees/${value.newResources}`).truncated = true;
    },
  ],
])("release stamp rejects %s", async (_, alter) => {
  const value = fixture();
  alter(value);
  await expect(verifyCohortReleaseStamp(value.input, value)).rejects.toThrow();
});

test.each(["version", "build", "executable"])(
  "plist semantic %s changes cannot obtain continuation",
  async (field) => {
    const value = fixture();
    const sha = value.addBlob(
      value.plist(
        field === "version" ? "0.0.321" : "0.0.320",
        field === "build" ? "332" : "331",
        field === "executable" ? "Foreign" : "Edith",
      ),
    );
    value.documents.get(`git/trees/${value.newResources}`).tree[0].sha = sha;
    await expect(
      verifyCohortReleaseStamp(value.input, value),
    ).rejects.toThrow();
  },
);

test("a public release cannot claim a different target from the raw tag and main", async () => {
  const value = fixture();
  value.input.release.target_commitish = source;
  await expect(verifyCohortReleaseStamp(value.input, value)).rejects.toThrow(
    "release target",
  );
});

test("blob bytes cannot substitute for their admitted Git identity", async () => {
  const value = fixture();
  const sha = value.documents.get(`git/trees/${value.newResources}`).tree[0]
    .sha;
  const blob = value.documents.get(`git/blobs/${sha}`);
  blob.content = value.plist("0.0.320", "331", "Foreign").toString("base64");
  blob.size = Buffer.from(blob.content, "base64").length;
  await expect(verifyCohortReleaseStamp(value.input, value)).rejects.toThrow(
    "blob identity",
  );
});

test("main moving after exact metadata verification remains rejected", async () => {
  const value = fixture();
  let reads = 0;
  const fetchMetadata = async (path) => {
    const result = await value.fetchMetadata(path);
    if (path === "git/ref/heads/main" && ++reads === 2)
      result.object.sha = "9".repeat(40);
    return result;
  };
  await expect(
    verifyCohortReleaseStamp(value.input, { fetchMetadata }),
  ).rejects.toThrow("source moved");
});

test("release tag retargeting after semantic verification remains rejected", async () => {
  const value = fixture();
  let reads = 0;
  const fetchMetadata = async (path) => {
    const result = await value.fetchMetadata(path);
    if (path === "git/ref/tags/v0.0.320" && ++reads === 2)
      result.object.sha = "9".repeat(40);
    return result;
  };
  await expect(
    verifyCohortReleaseStamp(value.input, { fetchMetadata }),
  ).rejects.toThrow("tag moved");
});
