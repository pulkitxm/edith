import { expect, test } from "bun:test";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import {
  preflightReleaseAsset,
  uploadReleaseAsset,
} from "./release-asset-upload.mjs";

function fixture() {
  const directory = mkdtempSync(join(tmpdir(), "release-upload-fixture-"));
  const file = join(directory, "catalog.json");
  writeFileSync(file, Buffer.alloc(50_001, 42));
  const calls = [];
  let uploadPath;
  const execute = (command, args) => {
    calls.push([command, ...args]);
    if (command === "pukbot")
      throw Object.assign(new Error("Request rejected"), {
        stderr: "Error: release asset must be between 1 and 40000 bytes",
      });
    if (
      args[0] === "release" &&
      args[1] === "upload" &&
      !args.includes("--help")
    ) {
      uploadPath = args[3];
      expect(basename(uploadPath)).toBe("catalog-123.json");
      expect(readFileSync(uploadPath)).toEqual(readFileSync(file));
    }
    return "{}";
  };
  return {
    file,
    calls,
    execute,
    get uploadPath() {
      return uploadPath;
    },
    clean() {
      rmSync(directory, { recursive: true, force: true });
    },
  };
}

test("capacity fallback uses the actual tag and an owned custom basename without clobber", async () => {
  const value = fixture();
  try {
    const options = {
      repository: "synthetic/fixture",
      file: value.file,
      name: "catalog-123.json",
      execute: value.execute,
    };
    expect(preflightReleaseAsset(options)).toBe("gh");
    expect(
      value.calls.every(
        (call) => call.includes("--dry-run") || call.includes("--help"),
      ),
    ).toBe(true);
    expect(
      await uploadReleaseAsset({
        ...options,
        releaseID: 7,
        tag: "extension-catalog-v1",
      }),
    ).toBe("gh");
    const upload = value.calls.at(-1);
    expect(upload.slice(0, 4)).toEqual([
      "gh",
      "release",
      "upload",
      "extension-catalog-v1",
    ]);
    expect(upload).not.toContain("--clobber");
    expect(upload.every((argument) => !argument.includes("#"))).toBe(true);
    expect(existsSync(value.uploadPath)).toBe(false);
  } finally {
    value.clean();
  }
});

test("small accepted assets stay with the release client and wait for upload completion", async () => {
  const value = fixture();
  try {
    writeFileSync(value.file, "synthetic metadata");
    const execute = (command, args) => {
      value.calls.push([command, ...args]);
      return command === "pukbot" && !args.includes("--dry-run")
        ? JSON.stringify({
            workflowUrl:
              "https://github.com/synthetic/transport/actions/runs/9",
          })
        : "{}";
    };
    const options = {
      repository: "synthetic/fixture",
      file: value.file,
      execute,
    };
    expect(preflightReleaseAsset(options)).toBe("pukbot");
    expect(
      await uploadReleaseAsset({ ...options, releaseID: 7, tag: "v1.2.3" }),
    ).toBe("pukbot");
    expect(value.calls.at(-1)).toEqual([
      "gh",
      "run",
      "watch",
      "9",
      "--repo",
      "synthetic/transport",
      "--exit-status",
    ]);
    expect(
      value.calls.some((call) => call[0] === "gh" && call[1] === "release"),
    ).toBe(false);
  } finally {
    value.clean();
  }
});

test("unrelated failures and false capacity errors never use the fallback", async () => {
  const value = fixture();
  try {
    for (const message of ["Forbidden", "Upload failed", "Unknown release"]) {
      const execute = () => {
        throw new Error(message);
      };
      expect(() =>
        preflightReleaseAsset({
          repository: "synthetic/fixture",
          file: value.file,
          execute,
        }),
      ).toThrow(message);
      await expect(
        uploadReleaseAsset({
          repository: "synthetic/fixture",
          releaseID: 7,
          tag: "v1.2.3",
          file: value.file,
          execute,
        }),
      ).rejects.toThrow(message);
    }
    writeFileSync(value.file, "small");
    expect(() =>
      preflightReleaseAsset({
        repository: "synthetic/fixture",
        file: value.file,
        execute: value.execute,
      }),
    ).toThrow("rejected");
    expect(value.calls.every((call) => call[0] === "pukbot")).toBe(true);
  } finally {
    value.clean();
  }
});

test("returned capacity errors are accepted only for genuinely oversized assets", () => {
  const value = fixture();
  try {
    const execute = (command, args) => {
      value.calls.push([command, ...args]);
      return JSON.stringify({
        ok: false,
        error: { message: "release asset must be between 1 and 40000 bytes" },
      });
    };
    expect(statSync(value.file).size).toBeGreaterThan(40_000);
    expect(
      preflightReleaseAsset({
        repository: "synthetic/fixture",
        file: value.file,
        execute,
      }),
    ).toBe("gh");
    expect(value.calls.at(-1).slice(0, 4)).toEqual([
      "gh",
      "release",
      "upload",
      "--help",
    ]);
  } finally {
    value.clean();
  }
});
