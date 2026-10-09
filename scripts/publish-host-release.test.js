import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { publishHostRelease } from "./publish-host-release.mjs";

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
    ...options,
  });
}

test("publishes only the host DMG and signed appcast through the release client", () => {
  const value = fixture();
  try {
    expect(publish(value).assets).toEqual(["Edith.dmg", "appcast.xml"]);
    const mutations = value.calls.filter(([command]) => command === "pukbot");
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

test("retries identical assets without uploading again", () => {
  const value = fixture(true);
  try {
    value.release.assets = ["Edith.dmg", "appcast.xml"].map((name, index) => ({
      id: index + 1,
      name,
      bytes: readFileSync(join(value.directory, name)),
    }));
    publish(value);
    expect(
      value.calls.filter((args) => args[0] === "pukbot").map((args) => args[2]),
    ).toEqual(["edit"]);
    value.release.assets[0].bytes = Buffer.from("different");
    expect(() => publish(value)).toThrow("differs");
    expect(value.calls.some((args) => args.includes("DELETE"))).toBe(false);
  } finally {
    value.clean();
  }
});

test("rebuild replaces changed assets but requires an existing release", () => {
  const value = fixture(true);
  try {
    value.release.assets = [
      { id: 9, name: "Edith.dmg", bytes: Buffer.from("old") },
    ];
    publish(value, { rebuild: true });
    expect(
      value.calls.some((args) => args[0] === "gh" && args.includes("DELETE")),
    ).toBe(true);
    expect(
      value.calls.filter((args) => args[0] === "pukbot").map((args) => args[2]),
    ).toEqual(["upload-asset", "upload-asset", "edit"]);
  } finally {
    value.clean();
  }
  const missing = fixture();
  try {
    expect(() => publish(missing, { rebuild: true })).toThrow(
      "missing release",
    );
  } finally {
    missing.clean();
  }
});

test("invalid or unsigned appcasts fail before any remote call", () => {
  const value = fixture();
  try {
    for (const xml of [
      "unsigned",
      '<enclosure url="https://example.com/Edith.dmg" sparkle:edSignature="synthetic"/>',
    ]) {
      writeFileSync(join(value.directory, "appcast.xml"), xml);
      expect(() => publish(value)).toThrow("appcast");
    }
    expect(value.calls).toEqual([]);
  } finally {
    value.clean();
  }
});

test("failed uploads do not expose an unfinished release", () => {
  const value = fixture();
  try {
    const execute = (command, args, options) => {
      if (command === "pukbot" && args[1] === "upload-asset")
        throw new Error("Upload failed");
      return value.execute(command, args, options);
    };
    expect(() => publish(value, { execute })).toThrow("Upload failed");
    expect(
      value.calls.some((args) => args[0] === "pukbot" && args[2] === "edit"),
    ).toBe(false);
  } finally {
    value.clean();
  }
});
