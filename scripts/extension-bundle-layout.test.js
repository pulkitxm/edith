import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const frameworkChecks = readFileSync("Makefile", "utf8")
  .split("\n")
  .filter(
    (line) =>
      line.startsWith("\ttest ") &&
      line.includes("find dist/Edith.app -name") &&
      line.includes(".framework"),
  );
const required = [
  "Sparkle.framework",
  "EdithShared.framework",
  "ExtensionMarketplace.framework",
];

function verify({ missing, extra } = {}) {
  const root = mkdtempSync(join(tmpdir(), "extension-bundle-layout-"));
  try {
    for (const name of required.filter((name) => name !== missing)) {
      mkdirSync(join(root, "dist/Edith.app/Contents/Frameworks", name), {
        recursive: true,
      });
    }
    if (extra)
      mkdirSync(join(root, "dist/Edith.app", extra), { recursive: true });
    writeFileSync(
      join(root, "Makefile"),
      `verify:\n${frameworkChecks.join("\n")}\n`,
    );
    return spawnSync("make", ["verify"], { cwd: root, encoding: "utf8" });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("release bundle accepts one shared marketplace runtime without inference payloads", () => {
  expect(frameworkChecks.length).toBeGreaterThanOrEqual(5);
  expect(verify().status).toBe(0);
});

test.each(required)("release bundle rejects missing %s", (missing) => {
  expect(verify({ missing }).status).not.toBe(0);
});

test.each([
  "Contents/Frameworks/ExtensionMarketplace.framework/ExtensionMarketplace.framework",
  "Contents/Frameworks/MeetingVoice.framework",
  "Contents/Library/LoginItems/Edith.app/Contents/Frameworks/MeetingVoice.framework",
  "Contents/Frameworks/onnxruntime.framework",
  "Contents/Library/LoginItems/Edith.app/Contents/Frameworks/onnxruntime.framework",
])(
  "release bundle rejects duplicated or bundled downloadable code at %s",
  (extra) => {
    expect(verify({ extra }).status).not.toBe(0);
  },
);
