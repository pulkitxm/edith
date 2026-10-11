import { expect, test } from "bun:test";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  preflightHostRelease,
  publishHostRelease,
} from "./publish-host-release.mjs";

const assetNames = [
  "Edith.dmg",
  "appcast.xml",
  "host-release-proof.json",
  "build-metadata.json",
  "toolchain-provenance.json",
];
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");

function fixture(existing = false) {
  const directory = mkdtempSync(join(tmpdir(), "edith-host-publication-"));
  writeFileSync(join(directory, "Edith.dmg"), Buffer.alloc(50_000, 42));
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const signature = sign(
    null,
    readFileSync(join(directory, "Edith.dmg")),
    privateKey,
  ).toString("base64");
  writeFileSync(
    join(directory, "appcast.xml"),
    `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>123</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><enclosure url="https://github.com/synthetic/fixture/releases/download/v1.2.3/Edith.dmg" length="50000" sparkle:edSignature="${signature}" /></item></channel></rss>`,
  );
  const sourceCommit = "a".repeat(40);
  const hostExecutableSHA256 = "b".repeat(64);
  const metadata = {
    sourceCommit,
    sourceTreeDirty: false,
    configuration: "Release",
    optimization: "Osize",
    linkTimeOptimization: "full",
    architecture: "arm64",
    hostExecutableSHA256,
  };
  const toolchain = {
    schema: 1,
    sourceCommit,
    hostExecutableSHA256,
    xcode: "Xcode 26.0\nBuild version 17A400",
    sdk: "26.0",
    builderSignature: "ad-hoc",
  };
  const proof = {
    schema: 1,
    sourceCommit,
    version: "1.2.3",
    build: "123",
    installedBytes: 1234,
    extensionPayloadBytes: 0,
    indexedExtensions: 39,
    indexSHA256: "c".repeat(64),
    hostExecutableSHA256,
    certificateCategory: "Apple Development",
    teamIdentifier: "ABCDEFGHIJ",
    verifiedDesignatedRequirement:
      'identifier "com.pulkit.edith" and anchor apple generic and certificate leaf[subject.OU] = "ABCDEFGHIJ"',
    deepStrictSignatureVerified: true,
    dmgBytes: 50000,
    dmgSHA256: hash(readFileSync(join(directory, "Edith.dmg"))),
    dmgURL:
      "https://github.com/synthetic/fixture/releases/download/v1.2.3/Edith.dmg",
    appcastSHA256: hash(readFileSync(join(directory, "appcast.xml"))),
    sparklePublicKey: publicKey
      .export({ format: "der", type: "spki" })
      .subarray(-32)
      .toString("base64"),
    sparkleEd25519Verified: true,
    notarization: "skipped",
    publicationVerified: false,
    managedViewsVerified: false,
    hardwareVerified: false,
    sourceQualification: "clean",
    workflowSourceCommit: sourceCommit,
    sourceMode: "current-workflow-source",
  };
  for (const [name, content] of [
    ["host-release-proof.json", proof],
    ["build-metadata.json", metadata],
    ["toolchain-provenance.json", toolchain],
  ])
    writeFileSync(join(directory, name), JSON.stringify(content));
  const calls = [];
  let release = existing
    ? { id: 7, tag_name: "v1.2.3", draft: true, assets: [] }
    : undefined;
  const execute = (command, args) => {
    calls.push([command, ...args]);
    if (command === "gh" && args[1].endsWith("git/ref/heads/main"))
      return JSON.stringify({
        ref: "refs/heads/main",
        object: { type: "commit", sha: "a".repeat(40) },
      });
    if (command === "gh" && args[1].includes("/tags/")) {
      if (release && !release.draft) return JSON.stringify(release);
      throw Object.assign(new Error("Missing release"), { stderr: "HTTP 404" });
    }
    if (command === "gh" && args[1].includes("/releases?"))
      return JSON.stringify(release ? [release] : []);
    if (command === "gh" && args.includes("Accept: application/octet-stream")) {
      const id = Number(args.at(-1).split("/").at(-1));
      return release.assets.find((asset) => asset.id === id).bytes;
    }
    if (command === "pukbot" && args[1] === "create")
      release = { id: 7, tag_name: "v1.2.3", draft: true, assets: [] };
    if (command === "pukbot" && args[1] === "edit") release.draft = false;
    return "{}";
  };
  return {
    directory,
    proof,
    metadata,
    toolchain,
    calls,
    execute,
    matchesAsset: async ({ asset, file }) =>
      Buffer.from(asset.bytes.data ?? asset.bytes).equals(readFileSync(file)),
    get release() {
      return release;
    },
    clean() {
      rmSync(directory, { force: true, recursive: true });
    },
  };
}
function publish(value, options = {}) {
  if (options.rebuild) {
    value.proof.sourceMode = "tag-rebuild";
    writeFileSync(
      join(value.directory, "host-release-proof.json"),
      JSON.stringify(value.proof),
    );
  }
  return publishHostRelease({
    directory: value.directory,
    repository: "synthetic/fixture",
    tag: "v1.2.3",
    target: "a".repeat(40),
    execute: value.execute,
    matchesAsset: value.matchesAsset,
    ...options,
  });
}

test("publishes the host DMG signed appcast and three closed receipts through the release client", async () => {
  const value = fixture();
  try {
    expect((await publish(value)).assets).toEqual(assetNames);
    const mutations = value.calls.filter(
      (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
    );
    expect(mutations.map((args) => args[2])).toEqual([
      "create",
      ...assetNames.map(() => "upload-asset"),
      "edit",
    ]);
    expect(mutations[0]).toContain("--draft");
    expect(mutations.at(-1)).toContain("--make-latest");
    expect(
      value.calls.some((args) => args.includes("edith-database.zip")),
    ).toBe(false);
    expect(
      value.calls.some((args) => args[0] === "gh" && args[1] === "release"),
    ).toBe(false);
  } finally {
    value.clean();
  }
});

test("retries identical assets without uploading again", async () => {
  const value = fixture(true);
  try {
    value.release.assets = assetNames.map((name, index) => ({
      id: index + 1,
      name,
      bytes: readFileSync(join(value.directory, name)),
    }));
    await publish(value);
    expect(
      value.calls
        .filter((args) => args[0] === "pukbot" && !args.includes("--dry-run"))
        .map((args) => args[2]),
    ).toEqual(["edit"]);
    value.release.assets[0].bytes = Buffer.from("different");
    await expect(publish(value)).rejects.toThrow(
      "Published host assets are immutable",
    );
    expect(value.calls.some((args) => args.includes("DELETE"))).toBe(false);
  } finally {
    value.clean();
  }
});

test("rebuild replaces changed assets but requires an existing release", async () => {
  const value = fixture(true);
  try {
    value.release.assets = [
      { id: 9, name: "Edith.dmg", bytes: Buffer.from("old") },
    ];
    await publish(value, { rebuild: true });
    expect(
      value.calls.some((args) => args[0] === "gh" && args.includes("DELETE")),
    ).toBe(true);
    expect(
      value.calls
        .filter((args) => args[0] === "pukbot" && !args.includes("--dry-run"))
        .map((args) => args[2]),
    ).toEqual([...assetNames.map(() => "upload-asset"), "edit"]);
  } finally {
    value.clean();
  }
  const missing = fixture();
  try {
    await expect(publish(missing, { rebuild: true })).rejects.toThrow(
      "missing release",
    );
  } finally {
    missing.clean();
  }
});

test("invalid or unsigned appcasts fail before any remote call", async () => {
  const value = fixture();
  try {
    for (const xml of [
      "unsigned",
      '<enclosure url="https://example.com/Edith.dmg" sparkle:edSignature="synthetic"/>',
    ]) {
      writeFileSync(join(value.directory, "appcast.xml"), xml);
      await expect(publish(value)).rejects.toThrow("appcast");
    }
    expect(value.calls).toEqual([]);
  } finally {
    value.clean();
  }
});

test("failed uploads do not expose an unfinished release", async () => {
  const value = fixture();
  try {
    const execute = (command, args, options) => {
      if (
        command === "pukbot" &&
        args[1] === "upload-asset" &&
        !args.includes("--dry-run")
      )
        throw new Error("Upload failed");
      return value.execute(command, args, options);
    };
    await expect(publish(value, { execute })).rejects.toThrow("Upload failed");
    expect(
      value.calls.some((args) => args[0] === "pukbot" && args[2] === "edit"),
    ).toBe(false);
  } finally {
    value.clean();
  }
});

test("capacity fallback preflights every host asset without creating a release", () => {
  const value = fixture();
  try {
    const execute = (command, args) => {
      value.calls.push([command, ...args]);
      return command === "pukbot" && statSync(args[3]).size > 40_000
        ? JSON.stringify({
            ok: false,
            error: {
              message: "release asset must be between 1 and 40000 bytes",
            },
          })
        : "{}";
    };
    expect(
      preflightHostRelease({
        directory: value.directory,
        repository: "synthetic/fixture",
        tag: "v1.2.3",
        source: "a".repeat(40),
        execute,
      }),
    ).toEqual(assetNames);
    expect(
      value.calls.every(
        (args) => args.includes("--dry-run") || args.includes("--help"),
      ),
    ).toBe(true);
  } finally {
    value.clean();
  }
});

test("failed existing asset verification never deletes or replaces an asset", async () => {
  const value = fixture(true);
  try {
    value.release.assets = [{ id: 9, name: "Edith.dmg" }];
    await expect(
      publish(value, {
        rebuild: true,
        matchesAsset: async () => {
          throw new Error("Release asset download timed out");
        },
      }),
    ).rejects.toThrow("timed out");
    expect(value.calls.some((args) => args.includes("DELETE"))).toBe(false);
    expect(
      value.calls.some(
        (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
      ),
    ).toBe(false);
  } finally {
    value.clean();
  }
});

test("a later asset preflight failure stops publication before release creation", async () => {
  const value = fixture();
  try {
    const execute = (command, args) => {
      value.calls.push([command, ...args]);
      if (command === "pukbot")
        return JSON.stringify({
          ok: false,
          error: {
            message: args[3].endsWith("Edith.dmg")
              ? "release asset must be between 1 and 40000 bytes"
              : "Forbidden",
          },
        });
      return "{}";
    };
    await expect(publish(value, { execute })).rejects.toThrow("Forbidden");
    expect(
      value.calls.every(
        (args) => args.includes("--dry-run") || args.includes("--help"),
      ),
    ).toBe(true);
  } finally {
    value.clean();
  }
});

test("current main guards reject obsolete source and foreign release targets before mutation", async () => {
  for (const options of [
    { target: "b".repeat(40), sourceTarget: "a".repeat(40) },
    { sourceTarget: "b".repeat(40) },
  ]) {
    const value = fixture();
    try {
      await expect(publish(value, options)).rejects.toThrow();
      expect(
        value.calls.some(
          (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
        ),
      ).toBe(false);
    } finally {
      value.clean();
    }
  }
});

test("publication accepts only the exact intentional release child of the built source", async () => {
  const value = fixture();
  const source = "a".repeat(40);
  const release = "b".repeat(40);
  try {
    const execute = (command, args, options) => {
      if (command === "gh" && args[1].endsWith("git/ref/heads/main"))
        return JSON.stringify({
          ref: "refs/heads/main",
          object: { type: "commit", sha: release },
        });
      if (command === "gh" && args[1].endsWith(`commits/${release}`))
        return JSON.stringify({
          sha: release,
          parents: [{ sha: source }],
          commit: { message: "Release v1.2.3 [skip ci]" },
        });
      return value.execute(command, args, options);
    };
    await publish(value, { execute, sourceTarget: source, target: release });
    const creation = value.calls.find(
      (args) => args[0] === "pukbot" && args[2] === "create",
    );
    expect(creation[creation.indexOf("--target") + 1]).toBe(release);
    expect(
      value.calls.findLast(
        (args) => args[0] === "pukbot" && args[2] === "edit",
      ),
    ).toContain("--make-latest");
  } finally {
    value.clean();
  }
});

test("duplicate remote asset names stop resumable publication before mutation", async () => {
  const value = fixture(true);
  value.release.assets = [
    { id: 1, name: "Edith.dmg" },
    { id: 2, name: "Edith.dmg" },
  ];
  try {
    await expect(publish(value, { rebuild: true })).rejects.toThrow(
      "Ambiguous",
    );
    expect(value.calls.some((args) => args.includes("DELETE"))).toBe(false);
    expect(
      value.calls.some(
        (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
      ),
    ).toBe(false);
  } finally {
    value.clean();
  }
});

test("source advance during actual upload or immediately before promotion leaves the new release draft", async () => {
  for (const failAt of [5, 14]) {
    const value = fixture();
    let reads = 0;
    try {
      const execute = (command, args, options) => {
        if (command === "gh" && args[1].endsWith("git/ref/heads/main")) {
          if (++reads === failAt)
            return JSON.stringify({
              ref: "refs/heads/main",
              object: { type: "commit", sha: "b".repeat(40) },
            });
        }
        return value.execute(command, args, options);
      };
      await expect(publish(value, { execute })).rejects.toThrow("superseded");
      expect(value.release.draft).toBe(true);
      expect(
        value.calls.some((args) => args[0] === "pukbot" && args[2] === "edit"),
      ).toBe(false);
      expect(
        value.calls.filter(
          (args) =>
            args[0] === "pukbot" &&
            args[2] === "upload-asset" &&
            !args.includes("--dry-run"),
        ).length,
      ).toBe(failAt === 5 ? 1 : 5);
    } finally {
      value.clean();
    }
  }
});

test("source advance during existing asset comparison never deletes or replaces the draft", async () => {
  const value = fixture(true);
  value.release.assets = [{ id: 9, name: "Edith.dmg" }];
  let changed = false;
  try {
    await expect(
      publish(value, {
        rebuild: true,
        execute: (command, args, options) =>
          command === "gh" && args[1].endsWith("git/ref/heads/main") && changed
            ? JSON.stringify({
                ref: "refs/heads/main",
                object: { type: "commit", sha: "b".repeat(40) },
              })
            : value.execute(command, args, options),
        matchesAsset: async () => {
          changed = true;
          return false;
        },
      }),
    ).rejects.toThrow("superseded");
    expect(value.calls.some((args) => args.includes("DELETE"))).toBe(false);
    expect(
      value.calls.some(
        (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
      ),
    ).toBe(false);
  } finally {
    value.clean();
  }
});

test("published host assets stay immutable and identical rebuilds never change latest", async () => {
  const value = fixture(true);
  value.proof.sourceMode = "tag-rebuild";
  writeFileSync(
    join(value.directory, "host-release-proof.json"),
    JSON.stringify(value.proof),
  );
  value.release.draft = false;
  value.release.assets = assetNames.map((name, index) => ({
    id: index + 1,
    name,
    bytes: readFileSync(join(value.directory, name)),
  }));
  try {
    expect(await publish(value, { rebuild: true })).toEqual({
      tag: "v1.2.3",
      assets: assetNames,
      unchanged: true,
    });
    expect(
      value.calls.some(
        (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
      ),
    ).toBe(false);
    value.release.assets[0].bytes = Buffer.from("changed");
    await expect(publish(value, { rebuild: true })).rejects.toThrow(
      "Publish a new version",
    );
    value.release.assets = [];
    await expect(publish(value, { rebuild: true })).rejects.toThrow(
      "Publish a new version",
    );
    expect(value.calls.some((args) => args.includes("DELETE"))).toBe(false);
    expect(
      value.calls.some(
        (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
      ),
    ).toBe(false);
  } finally {
    value.clean();
  }
});

test("rebuilt checksums follow successful publication and never precede immutable asset rejection", () => {
  const workflow = Bun.YAML.parse(
    readFileSync(".github/workflows/ci.yml", "utf8"),
  );
  const steps = workflow.jobs.publish.steps;
  expect(
    steps.findIndex(
      (step) => step.name === "Update the rebuilt release checksum",
    ),
  ).toBeGreaterThan(
    steps.findIndex((step) => step.name === "Publish the release"),
  );
  expect(
    steps.findIndex(
      (step) => step.name === "Update the rebuilt release checksum",
    ),
  ).toBeLessThan(
    steps.findIndex(
      (step) => step.name === "Mirror the cask to the tap repository",
    ),
  );
});

function delayedMutations(value, effect = () => {}) {
  let pending;
  const events = [];
  const execute = (command, args, options) => {
    if (command === "pukbot" && ["create", "edit"].includes(args[1])) {
      expect(args.filter((argument) => argument === "--json")).toHaveLength(1);
      expect(args[args.indexOf("--repo") + 1]).toBe("synthetic/fixture");
      expect(options.timeout).toBeGreaterThan(0);
      expect(options.timeout).toBeLessThanOrEqual(30 * 60_000);
      expect(options.maxBuffer).toBe(2 * 1024 ** 2);
      expect(options.killSignal).toBe("SIGKILL");
      pending = args;
      events.push(args[1]);
      return JSON.stringify({
        workflowUrl: "https://github.com/synthetic/control/actions/runs/123",
      });
    }
    if (command === "gh" && args[0] === "run" && args[1] === "watch") {
      expect(args).toEqual([
        "run",
        "watch",
        "123",
        "--repo",
        "synthetic/control",
        "--exit-status",
      ]);
      expect(options.timeout).toBeGreaterThan(0);
      expect(options.timeout).toBeLessThanOrEqual(30 * 60_000);
      expect(options.maxBuffer).toBe(2 * 1024 ** 2);
      expect(options.killSignal).toBe("SIGKILL");
      events.push(`completed:${pending[1]}`);
      effect(pending[1]);
      return value.execute("pukbot", pending, options);
    }
    return value.execute(command, args, options);
  };
  return { execute, events };
}

test("host create and promotion await completed release workflows before observing state", async () => {
  const value = fixture();
  try {
    const delayed = delayedMutations(value);
    expect(await publish(value, { execute: delayed.execute })).toEqual({
      tag: "v1.2.3",
      assets: assetNames,
    });
    expect(delayed.events).toEqual([
      "create",
      "completed:create",
      "edit",
      "completed:edit",
    ]);
    expect(value.release.draft).toBe(false);
    expect(value.calls.at(-1)[2]).toContain("/tags/v1.2.3");
  } finally {
    value.clean();
  }
});

test("failed release control workflows never report completed publication", async () => {
  for (const operation of ["create", "edit"]) {
    const value = fixture();
    try {
      const delayed = delayedMutations(value, (current) => {
        if (current === operation)
          throw new Error(`${operation} workflow failed`);
      });
      await expect(
        publish(value, { execute: delayed.execute }),
      ).rejects.toThrow(`${operation} workflow failed`);
      expect(value.release?.draft ?? true).toBe(true);
      if (operation === "create")
        expect(
          value.calls.some(
            (args) =>
              args[0] === "pukbot" &&
              args[2] === "upload-asset" &&
              !args.includes("--dry-run"),
          ),
        ).toBe(false);
    } finally {
      value.clean();
    }
  }
});

test("release control timeouts propagate for both request and workflow wait", async () => {
  for (const stage of ["request", "watch"]) {
    const value = fixture();
    try {
      const delayed = delayedMutations(value);
      const execute = (command, args, options) => {
        if (
          (stage === "request" &&
            command === "pukbot" &&
            args[1] === "create") ||
          (stage === "watch" && command === "gh" && args[0] === "run")
        ) {
          expect(options.timeout).toBeLessThanOrEqual(30 * 60_000);
          expect(options.maxBuffer).toBe(2 * 1024 ** 2);
          expect(options.killSignal).toBe("SIGKILL");
          throw Object.assign(new Error("Release control timed out"), {
            code: "ETIMEDOUT",
          });
        }
        return delayed.execute(command, args, options);
      };
      await expect(publish(value, { execute })).rejects.toMatchObject({
        code: "ETIMEDOUT",
      });
      expect(value.release).toBeUndefined();
    } finally {
      value.clean();
    }
  }
});

test("source is revalidated after delayed draft creation before any upload", async () => {
  const value = fixture();
  let changed = false;
  try {
    const delayed = delayedMutations(value, () => {
      changed = true;
    });
    await expect(
      publish(value, {
        execute: delayed.execute,
        verifySource: async () => {
          if (changed) throw new Error("Source superseded");
        },
      }),
    ).rejects.toThrow("superseded");
    expect(value.release.draft).toBe(true);
    expect(
      value.calls.some(
        (args) =>
          args[0] === "pukbot" &&
          args[2] === "upload-asset" &&
          !args.includes("--dry-run"),
      ),
    ).toBe(false);
  } finally {
    value.clean();
  }
});

test("successful promotion response must expose the exact public release", async () => {
  const value = fixture();
  try {
    const execute = (command, args, options) =>
      command === "pukbot" && args[1] === "edit"
        ? "{}"
        : value.execute(command, args, options);
    await expect(publish(value, { execute })).rejects.toThrow(
      "Published host release state was not confirmed",
    );
    expect(value.release.draft).toBe(true);
  } finally {
    value.clean();
  }
});

test("draft asset deletion has bounded control output and deadline", async () => {
  const value = fixture(true);
  value.release.assets = [
    { id: 9, name: "Edith.dmg", bytes: Buffer.from("old") },
  ];
  let deletes = 0;
  try {
    const execute = (command, args, options) => {
      if (command === "gh" && args.includes("DELETE")) {
        expect(options.timeout).toBe(60_000);
        expect(options.maxBuffer).toBe(1024 ** 2);
        expect(options.killSignal).toBe("SIGKILL");
        deletes += 1;
      }
      return value.execute(command, args, options);
    };
    await publish(value, { execute, rebuild: true });
    expect(deletes).toBe(1);
  } finally {
    value.clean();
  }
});

test("closed receipt contradictions stop all remote commands", async () => {
  for (const [name, field, change] of [
    ["host-release-proof.json", "proof", { sourceCommit: "d".repeat(40) }],
    ["host-release-proof.json", "proof", { publicationVerified: true }],
    [
      "build-metadata.json",
      "metadata",
      { hostExecutableSHA256: "d".repeat(64) },
    ],
    ["build-metadata.json", "metadata", { private: "unexpected" }],
    ["toolchain-provenance.json", "toolchain", { sdk: "26.0 beta" }],
    [
      "toolchain-provenance.json",
      "toolchain",
      { builderSignature: "Apple Development" },
    ],
  ]) {
    const value = fixture();
    try {
      writeFileSync(
        join(value.directory, name),
        JSON.stringify({ ...value[field], ...change }),
      );
      await expect(publish(value)).rejects.toThrow();
      expect(value.calls).toEqual([]);
    } finally {
      value.clean();
    }
  }
});

test("duplicate JSON fields stop all remote commands for each receipt", async () => {
  for (const name of assetNames.filter((asset) => asset.endsWith(".json"))) {
    const value = fixture();
    try {
      const path = join(value.directory, name);
      const text = readFileSync(path, "utf8");
      writeFileSync(
        path,
        `${text.slice(0, -1)},"sourceCommit":"${"a".repeat(40)}"}`,
      );
      await expect(publish(value)).rejects.toThrow();
      expect(value.calls).toEqual([]);
    } finally {
      value.clean();
    }
  }
});

test("appcast signature must match the exact DMG and qualified key even with matching proof hashes", async () => {
  for (const changed of ["dmg", "key", "signature"]) {
    const value = fixture();
    try {
      if (changed === "dmg") {
        writeFileSync(
          join(value.directory, "Edith.dmg"),
          Buffer.alloc(50_000, 43),
        );
        value.proof.dmgSHA256 = hash(
          readFileSync(join(value.directory, "Edith.dmg")),
        );
      } else if (changed === "key") {
        const { publicKey } = generateKeyPairSync("ed25519");
        value.proof.sparklePublicKey = publicKey
          .export({ format: "der", type: "spki" })
          .subarray(-32)
          .toString("base64");
      } else {
        const xml = readFileSync(join(value.directory, "appcast.xml"), "utf8");
        writeFileSync(
          join(value.directory, "appcast.xml"),
          xml.replace(
            /edSignature="[^"]+"/,
            `edSignature="${Buffer.alloc(64).toString("base64")}"`,
          ),
        );
        value.proof.appcastSHA256 = hash(
          readFileSync(join(value.directory, "appcast.xml")),
        );
      }
      writeFileSync(
        join(value.directory, "host-release-proof.json"),
        JSON.stringify(value.proof),
      );
      await expect(publish(value)).rejects.toThrow("signature differs");
      expect(value.calls).toEqual([]);
    } finally {
      value.clean();
    }
  }
});

test("every public asset including provenance is immutable and required on retries", async () => {
  for (const name of assetNames) {
    for (const mode of ["changed", "missing", "duplicate"]) {
      const value = fixture(true);
      value.proof.sourceMode = "tag-rebuild";
      writeFileSync(
        join(value.directory, "host-release-proof.json"),
        JSON.stringify(value.proof),
      );
      value.release.draft = false;
      value.release.assets = assetNames.map((asset, index) => ({
        id: index + 1,
        name: asset,
        bytes: readFileSync(join(value.directory, asset)),
      }));
      const asset = value.release.assets.find((item) => item.name === name);
      if (mode === "changed")
        asset.bytes = Buffer.from("changed synthetic receipt");
      if (mode === "missing")
        value.release.assets = value.release.assets.filter(
          (item) => item.name !== name,
        );
      if (mode === "duplicate") value.release.assets.push({ ...asset, id: 99 });
      try {
        await expect(publish(value, { rebuild: true })).rejects.toThrow(
          mode === "duplicate" ? "Ambiguous" : "Publish a new version",
        );
        expect(value.calls.some((args) => args.includes("DELETE"))).toBe(false);
        expect(
          value.calls.some(
            (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
          ),
        ).toBe(false);
      } finally {
        value.clean();
      }
    }
  }
});

test("a later receipt comparison failure prevents every draft upload and replacement", async () => {
  const value = fixture(true);
  value.release.assets = assetNames.map((name, index) => ({
    id: index + 1,
    name,
    bytes: Buffer.from("old synthetic bytes"),
  }));
  const compared = [];
  try {
    await expect(
      publish(value, {
        rebuild: true,
        matchesAsset: async ({ asset }) => {
          compared.push(asset.name);
          if (asset.name === "toolchain-provenance.json")
            throw new Error("Receipt comparison timed out");
          return false;
        },
      }),
    ).rejects.toThrow("timed out");
    expect(compared).toEqual(assetNames);
    expect(value.calls.some((args) => args.includes("DELETE"))).toBe(false);
    expect(
      value.calls.some(
        (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
      ),
    ).toBe(false);
  } finally {
    value.clean();
  }
});

test("asset changes during capability preflight or source checks block publication", async () => {
  for (const stage of ["preflight", "source", "upload"]) {
    const value = fixture();
    let changed = false;
    try {
      const execute = (command, args, options) => {
        if (
          !changed &&
          ((stage === "preflight" &&
            command === "pukbot" &&
            args.includes("--dry-run")) ||
            (stage === "source" &&
              command === "gh" &&
              args[1].endsWith("git/ref/heads/main")) ||
            (stage === "upload" &&
              command === "pukbot" &&
              args[1] === "upload-asset" &&
              !args.includes("--dry-run")))
        ) {
          writeFileSync(
            join(value.directory, "toolchain-provenance.json"),
            JSON.stringify({ ...value.toolchain, sdk: "26.1" }),
          );
          changed = true;
        }
        return value.execute(command, args, options);
      };
      await expect(publish(value, { execute })).rejects.toThrow(
        "changed after preflight",
      );
      expect(
        value.calls.some((args) => args[0] === "pukbot" && args[2] === "edit"),
      ).toBe(false);
      if (stage !== "upload")
        expect(
          value.calls.some(
            (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
          ),
        ).toBe(false);
      else expect(value.release.draft).toBe(true);
    } finally {
      value.clean();
    }
  }
});

test("the immutable hosted artifact and release staging use the actual three receipt names", () => {
  const workflow = Bun.YAML.parse(
    readFileSync(".github/workflows/ci.yml", "utf8"),
  );
  const steps = workflow.jobs.dmg.steps;
  const artifact = steps.find(
    (step) => step.with?.name === "host-release-proof",
  );
  expect(artifact.with["if-no-files-found"]).toBe("error");
  expect(artifact.with.path.trim().split("\n")).toEqual(
    assetNames.slice(2).map((name) => `local/host-release-proof/${name}`),
  );
  const staging = steps.find(
    (step) => step.name === "Stage macOS release assets",
  );
  for (const name of assetNames.slice(2))
    expect(staging.run).toContain(`local/host-release-proof/${name}`);
  expect(staging.run).toContain("release-macos/");
  const download = workflow.jobs.publish.steps.find(
    (step) => step.with?.name === "release-macos",
  );
  expect(download.with.path).toBe("release-assets");
});
