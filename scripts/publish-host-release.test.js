import { expect, test } from "bun:test";
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

function fixture(existing = false) {
  const directory = mkdtempSync(join(tmpdir(), "edith-host-publication-"));
  writeFileSync(join(directory, "Edith.dmg"), Buffer.alloc(50_000, 42));
  writeFileSync(
    join(directory, "appcast.xml"),
    '<rss><enclosure url="https://github.com/synthetic/fixture/releases/download/v1.2.3/Edith.dmg" sparkle:edSignature="synthetic-signature" /></rss>',
  );
  const calls = [];
  let release = existing ? { id: 7, assets: [] } : undefined;
  const execute = (command, args) => {
    calls.push([command, ...args]);
    if (command === "gh" && args[1].includes("/tags/")) {
      if (release) return JSON.stringify(release);
      throw Object.assign(new Error("Missing release"), { stderr: "HTTP 404" });
    }
    if (command === "gh" && args.includes("Accept: application/octet-stream")) {
      const id = Number(args.at(-1).split("/").at(-1));
      return release.assets.find((asset) => asset.id === id).bytes;
    }
    if (command === "pukbot" && args[1] === "create")
      release = { id: 7, assets: [] };
    return "{}";
  };
  return {
    directory,
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

test("publishes only the host DMG and signed appcast through the release client", async () => {
  const value = fixture();
  try {
    expect((await publish(value)).assets).toEqual(["Edith.dmg", "appcast.xml"]);
    const mutations = value.calls.filter(
      (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
    );
    expect(mutations.map((args) => args[2])).toEqual([
      "create",
      "upload-asset",
      "upload-asset",
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
    value.release.assets = ["Edith.dmg", "appcast.xml"].map((name, index) => ({
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
    await expect(publish(value)).rejects.toThrow("differs");
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
    ).toEqual(["upload-asset", "upload-asset", "edit"]);
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
        execute,
      }),
    ).toEqual(["Edith.dmg", "appcast.xml"]);
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
