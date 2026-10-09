import { expect, test } from "bun:test";
import {
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const build = readFileSync("build.sh", "utf8");
const minimal = readFileSync("scripts/build-minimal-host.mjs", "utf8");
const fixture = process.env.HOST_FIXTURE;
const run = (...args) =>
  Bun.spawnSync(args, { stdout: "pipe", stderr: "pipe", timeout: 60000 });

test("development and release builds route through the empty host", () => {
  expect(build).toContain("node scripts/build-minimal-host.mjs");
  expect(build).toContain("python3 scripts/package-shipping-host.py");
  expect(build).not.toContain("xcodebuild -project");
  expect(build).not.toContain("cargo build");
  expect(build).not.toContain("EdithAgentRuntime");
  expect(build).not.toContain("EdithDatabaseRuntime");
  expect(minimal).toContain('"-Osize"');
  expect(minimal).toContain('"strip", ["-rSTx", file]');
  expect(minimal).toContain("5_000_000");
});

test.skipIf(!fixture || process.platform !== "darwin")(
  "packages signed release and development hosts and rejects payloads",
  () => {
    const root = mkdtempSync(join(tmpdir(), "edith-shipping-contract-"));
    try {
      for (const mode of [["--release"], ["--slot", "synthetic-shipping"]]) {
        const app = join(
          root,
          mode[0] === "--release"
            ? "release/Edith.app"
            : "development/Edith.app",
        );
        const packed = run(
          "python3",
          "scripts/package-shipping-host.py",
          fixture,
          app,
          "--identity",
          "-",
          ...mode,
        );
        expect(packed.stderr.toString()).toBe("");
        expect(packed.exitCode).toBe(0);
        const verified = run(
          "python3",
          "scripts/verify-shipping-host.py",
          app,
          ...(mode[0] === "--release" ? mode : []),
        );
        expect(verified.exitCode).toBe(0);
        expect(
          JSON.parse(verified.stdout.toString()).extensionPayloadBytes,
        ).toBe(0);
        const sparkle = join(app, "Contents/Frameworks/Sparkle.framework");
        const inspectLinks = (directory) => {
          for (const name of readdirSync(directory)) {
            const path = join(directory, name);
            const stat = lstatSync(path);
            expect(stat.isSymbolicLink()).toBe(false);
            if (stat.isDirectory()) inspectLinks(path);
          }
        };
        inspectLinks(sparkle);
        expect(readdirSync(sparkle)).not.toContain("Versions");
        for (const name of ["Headers", "PrivateHeaders", "Modules"])
          expect(readdirSync(sparkle)).not.toContain(name);
        const dependencies = run(
          "otool",
          "-L",
          join(app, "Contents/MacOS/Edith"),
        );
        expect(dependencies.exitCode).toBe(0);
        expect(dependencies.stdout.toString()).toContain(
          "@rpath/Sparkle.framework/Sparkle",
        );
        expect(dependencies.stdout.toString()).not.toContain(
          "/Sparkle.framework/Versions/",
        );
        const catalog = run(
          join(app, "Contents/MacOS/ed"),
          "extensions",
          "catalog",
          "--json",
        );
        expect(catalog.exitCode).toBe(0);
        expect(
          JSON.parse(catalog.stdout.toString()).length,
        ).toBeGreaterThanOrEqual(35);
        writeFileSync(
          join(app, "Contents/Library/feature.bundle"),
          "synthetic payload",
        );
        expect(
          run("python3", "scripts/verify-shipping-host.py", app).exitCode,
        ).not.toBe(0);
        rmSync(join(app, "Contents/Library/feature.bundle"));
        symlinkSync("/bin/sleep", join(app, "Contents/MacOS/worker"));
        expect(
          run("python3", "scripts/verify-shipping-host.py", app).exitCode,
        ).not.toBe(0);
        rmSync(join(app, "Contents/MacOS/worker"));
        writeFileSync(
          join(app, "Contents/Resources/index.json"),
          Buffer.alloc(5_000_000),
        );
        expect(
          run("python3", "scripts/verify-shipping-host.py", app).exitCode,
        ).not.toBe(0);
      }
      const same = run(
        "python3",
        "scripts/package-shipping-host.py",
        resolve(fixture),
        resolve(fixture),
        "--identity",
        "-",
        "--release",
      );
      expect(same.exitCode).not.toBe(0);
      expect(same.stderr.toString()).toContain("separate bundles");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  },
  120000,
);
