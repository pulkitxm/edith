import { expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import {
  chmodSync,
  existsSync,
  linkSync,
  readFileSync,
  statSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";
import { PassThrough } from "node:stream";
import { assetNames, fixture, publish } from "./host-release-test-fixture.mjs";
import {
  downloadReleaseAsset,
  releaseAssetMatchesFile,
} from "./release-asset-read.mjs";

const writes = (value) =>
  value.calls.filter(
    (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
  );
const uploads = (value) =>
  writes(value).filter((args) => args[2] === "upload-asset");
const promotions = (value) =>
  writes(value).filter((args) => args[2] === "edit");
const fill = (value) => {
  value.release.assets = assetNames.map((name, index) =>
    value.asset(name, index + 1),
  );
};

function matcher(value, events = [], effect = () => {}) {
  return (options) =>
    releaseAssetMatchesFile({
      ...options,
      downloadAsset: (request) =>
        downloadReleaseAsset({
          ...request,
          spawnProcess: (command, args) => {
            expect(command).toBe("gh");
            expect(args).toEqual([
              "api",
              "-H",
              "Accept: application/octet-stream",
              `repos/synthetic/fixture/releases/assets/${request.asset.id}`,
            ]);
            events.push([request.asset.name, value.release.draft]);
            const child = new EventEmitter();
            child.stdout = new PassThrough();
            child.kill = () => true;
            const bytes = Buffer.from(value.remoteBytes.get(request.asset.id));
            queueMicrotask(() => {
              effect(request.asset);
              child.stdout.end(bytes);
              child.emit("close", 0);
            });
            return child;
          },
        }),
    });
}

test("all five remote assets pass bounded byte verification before and after promotion", async () => {
  const value = fixture();
  const events = [];
  try {
    expect(
      (await publish(value, { matchesAsset: matcher(value, events) })).assets,
    ).toEqual(assetNames);
    expect(events).toEqual([
      ...assetNames.map((name) => [name, true]),
      ...assetNames.map((name) => [name, true]),
      ...assetNames.map((name) => [name, false]),
    ]);
    expect(
      uploads(value).map((args) => args[args.indexOf("--name") + 1]),
    ).toEqual(assetNames);
    expect(promotions(value)).toHaveLength(1);
    expect(
      value.calls.some(
        (args) => args.includes("DELETE") || args.includes("--clobber"),
      ),
    ).toBe(false);
  } finally {
    value.clean();
  }
});

test("partial exact draft resumes only missing assets and exact public retry writes nothing", async () => {
  const value = fixture(true);
  const events = [];
  try {
    value.release.assets = assetNames
      .slice(0, 2)
      .map((name, index) => value.asset(name, index + 1));
    const initial = value.release.assets.map((asset) => ({ ...asset }));
    await publish(value, { matchesAsset: matcher(value, events) });
    expect(value.release.assets.slice(0, 2)).toEqual(initial);
    expect(
      uploads(value).map((args) => args[args.indexOf("--name") + 1]),
    ).toEqual(assetNames.slice(2));
    value.calls.length = 0;
    events.length = 0;
    expect(
      await publish(value, { matchesAsset: matcher(value, events) }),
    ).toEqual({ tag: "v1.2.3", assets: assetNames, unchanged: true });
    expect(events).toEqual(assetNames.map((name) => [name, false]));
    expect(writes(value)).toEqual([]);
  } finally {
    value.clean();
  }
});

const immutableAssetCases = [true, false].flatMap((draft) =>
  [false, true].flatMap((rebuild) =>
    assetNames.map((name) => [draft, rebuild, name]),
  ),
);

test.each(immutableAssetCases)(
  "every existing asset is immutable: draft %p rebuild %p asset %s",
  async (draft, rebuild, name) => {
    const value = fixture(true);
    try {
      if (rebuild) {
        value.proof.sourceMode = "tag-rebuild";
        writeFileSync(
          join(value.directory, "host-release-proof.json"),
          JSON.stringify(value.proof),
        );
      }
      fill(value);
      value.release.draft = draft;
      const existing = value.release.assets.find(
        (asset) => asset.name === name,
      );
      value.remoteBytes.set(existing.id, Buffer.alloc(existing.size, 65));
      await expect(
        publish(value, { rebuild, matchesAsset: matcher(value) }),
      ).rejects.toThrow("Publish a new version");
      expect(writes(value)).toEqual([]);
      expect(value.calls.some((args) => args.includes("DELETE"))).toBe(false);
      expect(value.remoteBytes.get(existing.id)).toEqual(
        Buffer.alloc(existing.size, 65),
      );
    } finally {
      value.clean();
    }
  },
);

test("publication during the last asset comparison fails closed without replacement", async () => {
  for (const mismatched of [false, true]) {
    const value = fixture(true);
    const events = [];
    try {
      fill(value);
      if (mismatched) {
        const last = value.release.assets.at(-1);
        value.remoteBytes.set(last.id, Buffer.alloc(last.size, 65));
      }
      await expect(
        publish(value, {
          matchesAsset: matcher(value, events, (asset) => {
            if (asset.name === assetNames.at(-1)) value.release.draft = false;
          }),
        }),
      ).rejects.toThrow("draft state changed");
      expect(events).toEqual(assetNames.map((name) => [name, true]));
      expect(writes(value)).toEqual([]);
      expect(value.calls.some((args) => args.includes("DELETE"))).toBe(false);
    } finally {
      value.clean();
    }
  }
});

test("unknown missing duplicate and invalid remote assets cannot pass final inventory", async () => {
  for (const change of [
    (value) =>
      value.release.assets.push({
        id: 99,
        name: "unexpected.json",
        size: 1,
        state: "uploaded",
      }),
    (value) => {
      value.release.draft = false;
      value.release.assets.pop();
    },
    (value) =>
      value.release.assets.push({ ...value.release.assets[0], id: 99 }),
    (value) => {
      value.release.assets[1].id = value.release.assets[0].id;
    },
    (value) => {
      value.release.assets[0].size = 0;
    },
    (value) => {
      value.release.assets[0].state = "starter";
    },
  ]) {
    const value = fixture(true);
    try {
      fill(value);
      change(value);
      await expect(
        publish(value, { matchesAsset: matcher(value) }),
      ).rejects.toThrow();
      expect(writes(value)).toEqual([]);
    } finally {
      value.clean();
    }
  }
});

test("stable private copies keep original basenames permissions and owned cleanup", async () => {
  for (const fail of [false, true]) {
    const value = fixture();
    const paths = [];
    try {
      const execute = (command, args, options) => {
        if (
          command === "pukbot" &&
          args[1] === "upload-asset" &&
          !args.includes("--dry-run")
        ) {
          const file = args[3];
          paths.push(file);
          const name = args[args.indexOf("--name") + 1];
          expect(basename(file)).toBe(name);
          expect(dirname(file)).not.toBe(value.directory);
          expect(statSync(dirname(file)).mode & 0o777).toBe(0o700);
          expect(statSync(file).mode & 0o777).toBe(0o600);
          expect(statSync(file).nlink).toBe(1);
          expect(readFileSync(file)).toEqual(
            readFileSync(join(value.directory, name)),
          );
          if (fail) throw new Error("Synthetic upload failure");
        }
        return value.execute(command, args, options);
      };
      if (fail)
        await expect(publish(value, { execute })).rejects.toThrow(
          "Synthetic upload failure",
        );
      else await publish(value, { execute, matchesAsset: matcher(value) });
      expect(paths.length).toBe(fail ? 1 : 5);
      expect(paths.every((file) => !existsSync(dirname(file)))).toBe(true);
      expect(
        assetNames.every((name) => existsSync(join(value.directory, name))),
      ).toBe(true);
    } finally {
      value.clean();
    }
  }
});

test("local upload changes including restored transient bytes cannot promote", async () => {
  for (const restored of [false, true])
    for (const copied of [false, true]) {
      const value = fixture();
      let changedFile;
      try {
        const execute = (command, args, options) => {
          if (
            command === "pukbot" &&
            args[1] === "upload-asset" &&
            !args.includes("--dry-run") &&
            basename(args[3]) === "toolchain-provenance.json"
          ) {
            changedFile = copied
              ? args[3]
              : join(value.directory, "toolchain-provenance.json");
            const original = readFileSync(changedFile);
            writeFileSync(
              changedFile,
              JSON.stringify({ ...value.toolchain, sdk: "26.1" }),
            );
            try {
              return value.execute(command, args, options);
            } finally {
              if (restored) writeFileSync(changedFile, original);
            }
          }
          return value.execute(command, args, options);
        };
        await expect(
          publish(value, { execute, matchesAsset: matcher(value) }),
        ).rejects.toThrow("changed after preflight");
        expect(value.release.draft).toBe(true);
        expect(promotions(value)).toEqual([]);
        const asset = value.release.assets.find(
          (asset) => asset.name === "toolchain-provenance.json",
        );
        expect(JSON.parse(value.remoteBytes.get(asset.id)).sdk).toBe(
          copied ? "26.1" : "26.0",
        );
        if (copied) expect(existsSync(dirname(changedFile))).toBe(false);
      } finally {
        value.clean();
      }
    }
});

test("same size corrupted upload bytes fail remote checksum before promotion", async () => {
  const value = fixture();
  try {
    const execute = (command, args, options) => {
      const result = value.execute(command, args, options);
      if (
        command === "pukbot" &&
        args[1] === "upload-asset" &&
        !args.includes("--dry-run") &&
        basename(args[3]) === "toolchain-provenance.json"
      ) {
        const asset = value.release.assets.at(-1);
        const bytes = Buffer.from(value.remoteBytes.get(asset.id));
        bytes[0] ^= 1;
        value.remoteBytes.set(asset.id, bytes);
      }
      return result;
    };
    await expect(
      publish(value, { execute, matchesAsset: matcher(value) }),
    ).rejects.toThrow("Publish a new version");
    expect(value.release.draft).toBe(true);
    expect(promotions(value)).toEqual([]);
  } finally {
    value.clean();
  }
});

test("concurrent release identity and inventory changes block the next upload", async () => {
  for (const change of [
    (release) => {
      release.id += 1;
    },
    (release) => {
      release.tag_name = "v9.9.9";
    },
    (release) => {
      release.target_commitish = "b".repeat(40);
    },
    (release) => {
      release.draft = false;
    },
    (release) => {
      release.assets[0].id += 1;
    },
    (release) => {
      release.assets.push({
        id: 99,
        name: "extra.json",
        size: 1,
        state: "uploaded",
      });
    },
  ]) {
    const value = fixture();
    try {
      const execute = (command, args, options) => {
        const result = value.execute(command, args, options);
        if (
          command === "pukbot" &&
          args[1] === "upload-asset" &&
          !args.includes("--dry-run")
        )
          change(value.release);
        return result;
      };
      await expect(
        publish(value, { execute, matchesAsset: matcher(value) }),
      ).rejects.toThrow();
      expect(uploads(value)).toHaveLength(1);
      expect(promotions(value)).toEqual([]);
    } finally {
      value.clean();
    }
  }
});

test("publication after the final remote guard cannot clobber existing bytes or report success", async () => {
  const value = fixture(true);
  try {
    value.release.assets = [value.asset(assetNames[0], 1)];
    const original = Buffer.from(value.remoteBytes.get(1));
    const execute = (command, args, options) => {
      if (
        command === "pukbot" &&
        args[1] === "upload-asset" &&
        !args.includes("--dry-run")
      )
        value.release.draft = false;
      return value.execute(command, args, options);
    };
    await expect(
      publish(value, { execute, matchesAsset: matcher(value) }),
    ).rejects.toThrow("draft state changed");
    expect(value.remoteBytes.get(1)).toEqual(original);
    expect(value.release.assets[0].id).toBe(1);
    expect(
      value.calls.some(
        (args) => args.includes("DELETE") || args.includes("--clobber"),
      ),
    ).toBe(false);
    expect(promotions(value)).toEqual([]);
  } finally {
    value.clean();
  }
});

test("concurrent identical asset arrival is rejected by nonclobber upload", async () => {
  const value = fixture(true);
  try {
    const execute = (command, args, options) => {
      if (
        command === "pukbot" &&
        args[1] === "upload-asset" &&
        !args.includes("--dry-run")
      ) {
        const name = args[args.indexOf("--name") + 1];
        value.release.assets.push(value.asset(name, 99));
      }
      return value.execute(command, args, options);
    };
    await expect(publish(value, { execute })).rejects.toThrow("HTTP 422");
    expect(value.release.assets).toHaveLength(1);
    expect(value.release.assets[0].id).toBe(99);
    expect(promotions(value)).toEqual([]);
  } finally {
    value.clean();
  }
});

test("postpromotion identity inventory and bytes must still match the draft snapshot", async () => {
  for (const change of [
    (value) => {
      value.release.target_commitish = "b".repeat(40);
    },
    (value) => {
      value.release.assets.pop();
    },
    (value) => {
      value.release.assets[0].size += 1;
    },
    (value) => {
      value.release.assets[0].id += 1;
    },
    (value) => {
      const asset = value.release.assets[0];
      value.remoteBytes.set(asset.id, Buffer.alloc(asset.size, 65));
    },
  ]) {
    const value = fixture();
    try {
      const execute = (command, args, options) => {
        const result = value.execute(command, args, options);
        if (command === "pukbot" && args[1] === "edit") change(value);
        return result;
      };
      await expect(
        publish(value, { execute, matchesAsset: matcher(value) }),
      ).rejects.toThrow();
      expect(promotions(value)).toHaveLength(1);
    } finally {
      value.clean();
    }
  }
});

test("nonregular linked writable empty and oversized local assets fail without remote access", async () => {
  for (const change of [
    (file, value) => {
      unlinkSync(file);
      symlinkSync(join(value.directory, "build-metadata.json"), file);
    },
    (file, value) => linkSync(file, join(value.directory, "linked.json")),
    (file) => chmodSync(file, 0o666),
    (file) => chmodSync(file, 0o2644),
    (file) => writeFileSync(file, Buffer.alloc(0)),
    (file) => writeFileSync(file, Buffer.alloc(1024 ** 2 + 1)),
  ]) {
    const value = fixture();
    try {
      change(join(value.directory, "toolchain-provenance.json"), value);
      await expect(publish(value)).rejects.toThrow(
        "Invalid bounded release asset",
      );
      expect(value.calls).toEqual([]);
    } finally {
      value.clean();
    }
  }
});

test("capacity fallback keeps copied bytes private and rechecks remote state before transport", async () => {
  for (const publishDuringFallback of [false, true]) {
    const value = fixture();
    const fallbackFiles = [];
    try {
      const execute = (command, args, options) => {
        if (
          command === "pukbot" &&
          args[1] === "upload-asset" &&
          basename(args[3]) === "Edith.dmg"
        ) {
          if (!args.includes("--dry-run") && publishDuringFallback)
            value.release.draft = false;
          return JSON.stringify({
            ok: false,
            error: {
              message: "release asset must be between 1 and 40000 bytes",
            },
          });
        }
        if (command === "gh" && args[0] === "release" && args[1] === "upload")
          return "Usage: gh release upload";
        if (
          command === "gh" &&
          args[0] === "api" &&
          args.includes("--input") &&
          args.some((argument) =>
            argument.startsWith("https://uploads.github.com/"),
          )
        ) {
          expect(args).not.toContain("--clobber");
          expect(value.release.draft).toBe(true);
          const file = args[args.indexOf("--input") + 1];
          fallbackFiles.push(file);
          expect(basename(file)).toBe("Edith.dmg");
          expect(statSync(file).mode & 0o777).toBe(0o600);
          expect(statSync(dirname(file)).mode & 0o777).toBe(0o700);
          value.release.assets.push(
            value.asset("Edith.dmg", 99, readFileSync(file)),
          );
          return "";
        }
        return value.execute(command, args, options);
      };
      if (publishDuringFallback) {
        await expect(
          publish(value, { execute, matchesAsset: matcher(value) }),
        ).rejects.toThrow("draft state changed");
        expect(fallbackFiles).toEqual([]);
        expect(value.release.assets).toEqual([]);
        expect(promotions(value)).toEqual([]);
      } else {
        await publish(value, { execute, matchesAsset: matcher(value) });
        expect(fallbackFiles).toHaveLength(1);
        expect(existsSync(dirname(fallbackFiles[0]))).toBe(false);
        expect(value.release.draft).toBe(false);
      }
    } finally {
      value.clean();
    }
  }
});

test("remote tag commit and annotated tag source must bind the exact release target", async () => {
  for (const mode of [
    "commit",
    "annotated",
    "foreign",
    "wrong-ref",
    "nested-tag",
    "annotated-move",
    "commit-move",
  ]) {
    const value = fixture(true);
    try {
      fill(value);
      if (["annotated", "nested-tag", "annotated-move"].includes(mode)) {
        value.tagReference.object = { type: "tag", sha: "d".repeat(40) };
        value.annotatedTags.set("d".repeat(40), {
          sha: "d".repeat(40),
          tag: "v1.2.3",
          object: {
            type: mode === "nested-tag" ? "tag" : "commit",
            sha: "a".repeat(40),
          },
        });
      }
      if (mode === "foreign") value.tagReference.object.sha = "b".repeat(40);
      if (mode === "wrong-ref") value.tagReference.ref = "refs/tags/v1.2.4";
      const matchesAsset = matcher(value, [], (asset) => {
        if (asset.name !== assetNames.at(-1)) return;
        if (mode === "commit-move")
          value.tagReference.object.sha = "b".repeat(40);
        if (mode === "annotated-move") {
          value.tagReference.object.sha = "e".repeat(40);
          value.annotatedTags.set("e".repeat(40), {
            sha: "e".repeat(40),
            tag: "v1.2.3",
            object: { type: "commit", sha: "a".repeat(40) },
          });
        }
      });
      if (["commit", "annotated"].includes(mode))
        await publish(value, { matchesAsset });
      else {
        await expect(publish(value, { matchesAsset })).rejects.toThrow();
        expect(writes(value)).toEqual([]);
      }
    } finally {
      value.clean();
    }
  }
});

test("missing upload inventory and truncated or oversized remote bytes cannot promote", async () => {
  for (const mode of ["missing", "truncated", "oversized", "size"]) {
    const value = fixture();
    try {
      const execute = (command, args, options) => {
        const result = value.execute(command, args, options);
        if (
          command === "pukbot" &&
          args[1] === "upload-asset" &&
          !args.includes("--dry-run")
        ) {
          const asset = value.release.assets.at(-1);
          if (mode === "missing") value.release.assets.pop();
          if (mode === "size") asset.size += 1;
          if (mode === "truncated")
            value.remoteBytes.set(
              asset.id,
              value.remoteBytes.get(asset.id).subarray(1),
            );
          if (mode === "oversized")
            value.remoteBytes.set(
              asset.id,
              Buffer.concat([
                value.remoteBytes.get(asset.id),
                Buffer.from([0]),
              ]),
            );
        }
        return result;
      };
      await expect(
        publish(value, { execute, matchesAsset: matcher(value) }),
      ).rejects.toThrow();
      expect(uploads(value)).toHaveLength(1);
      expect(value.release.draft).toBe(true);
      expect(promotions(value)).toEqual([]);
    } finally {
      value.clean();
    }
  }
});
