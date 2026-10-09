import { describe, expect, test } from "bun:test";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

const script = readFileSync(resolve("build.sh"), "utf8");
const launcher = readFileSync(resolve("Resources/ed-launcher"), "utf8");

describe("build install lifecycle", () => {
  test.skipIf(process.platform !== "darwin")(
    "rejects prebuilt installation without explicit release install mode",
    () => {
      for (const options of [
        [],
        ["--release"],
        ["--release", "--install", "--branch", "fixture"],
      ]) {
        const result = Bun.spawnSync(
          ["bash", "build.sh", "--from-app", "/fixture/Edith.app", ...options],
          {
            stdout: "pipe",
            stderr: "pipe",
            timeout: 5000,
          },
        );
        expect(result.exitCode).toBe(1);
        expect(new TextDecoder().decode(result.stderr)).toContain(
          "--from-app requires --release --install",
        );
      }
    },
  );

  test.skipIf(process.platform !== "darwin")(
    "rejects untrusted prebuilt bundles before replacing the installed app",
    () => {
      const directory = mkdtempSync(
        resolve(tmpdir(), "edith-prebuilt-fixture-"),
      );
      try {
        const bundle = resolve(directory, "Edith.app");
        mkdirSync(bundle);
        const result = Bun.spawnSync(
          [
            "bash",
            "build.sh",
            "--release",
            "--install",
            "--from-app",
            bundle,
            "--no-open",
          ],
          {
            stdout: "pipe",
            stderr: "pipe",
            timeout: 5000,
          },
        );
        expect(result.exitCode).not.toBe(0);
        expect(new TextDecoder().decode(result.stderr)).toContain(
          "bundle format",
        );
      } finally {
        rmSync(directory, { recursive: true, force: true });
      }
    },
  );

  test.skipIf(process.platform !== "darwin")(
    "rejects development installation before resolving a branch or pull request",
    () => {
      for (const selection of [
        [],
        ["--branch", "fixture-development"],
        ["--pr", "999999"],
      ]) {
        const result = Bun.spawnSync(
          ["bash", "build.sh", "--install", ...selection],
          {
            env: { ...process.env, EDITH_RELEASE: "0" },
            stdout: "pipe",
            stderr: "pipe",
            timeout: 5000,
          },
        );
        expect(result.exitCode).toBe(1);
        expect(new TextDecoder().decode(result.stderr)).toContain(
          "Development builds cannot replace /Applications/Edith.app.",
        );
      }
    },
  );

  test("install targets explicitly select a release build", () => {
    for (const target of ["install", "reinstall"]) {
      const result = Bun.spawnSync(["make", "-n", target], {
        stdout: "pipe",
        stderr: "pipe",
        timeout: 5000,
      });
      expect(result.exitCode).toBe(0);
      expect(new TextDecoder().decode(result.stdout)).toContain(
        "./build.sh --release --install",
      );
    }
  });

  test("uses the host for CLI and workers without another feature executable", () => {
    const packaging = readFileSync("scripts/package-shipping-host.py", "utf8");
    expect(script).toContain("node scripts/build-minimal-host.mjs");
    expect(script).not.toContain("EdithDatabaseRuntime");
    expect(script).not.toContain("edith-music-player");
    expect(packaging).toContain("symlink_to('../Resources/ed-launcher')");
    expect(launcher).toContain(
      'EDITH_CLI=1 exec "$edith_launcher_directory/../MacOS/Edith" "$@"',
    );
    expect(script).not.toContain('sign_tool "$APP/Contents/MacOS/ed"');
  });

  test.skipIf(process.platform !== "darwin")(
    "installs atomically and stops only retired native processes",
    () => {
      expect(script).toContain(
        'python3 scripts/install_app.py "$APP" "/Applications/Edith.app"',
      );
      const result = Bun.spawnSync(
        ["python3", resolve("scripts/install_app_test.py")],
        { stdout: "pipe", stderr: "pipe", timeout: 30000 },
      );
      const output = new TextDecoder().decode(result.stderr);
      expect(output).toContain("Ran 14 tests");
      expect(output).toContain("OK");
      expect(result.exitCode).toBe(0);
    },
    35000,
  );

  test.skipIf(process.platform !== "darwin")(
    "signs the embedded helper after removing copied AppleDouble files",
    () => {
      const directory = mkdtempSync(resolve(tmpdir(), "edith-bundle-fixture-"));
      try {
        const source = resolve(directory, "EdithHelper.app/Contents");
        mkdirSync(resolve(source, "MacOS"), { recursive: true });
        copyFileSync("/bin/sleep", resolve(source, "MacOS/EdithHelper"));
        writeFileSync(resolve(source, "MacOS/._Edith"), "fixture metadata");
        chmodSync(resolve(source, "MacOS/._Edith"), 0o755);
        writeFileSync(
          resolve(source, "Info.plist"),
          `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.fixture.helper</string>
<key>CFBundleExecutable</key><string>EdithHelper</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>`,
        );
        const extraction = Bun.spawnSync(
          [
            "plutil",
            "-extract",
            "objects.894E33B83968A6646E7A6B4F.shellScript",
            "raw",
            "edth.xcodeproj/project.pbxproj",
          ],
          { stdout: "pipe", stderr: "pipe" },
        );
        expect(extraction.exitCode).toBe(0);
        const phase = new TextDecoder()
          .decode(extraction.stdout)
          .replace(
            "/usr/libexec/PlistBuddy",
            'cp /bin/sleep "$DEST/Contents/MacOS/._Edith"\n/usr/libexec/PlistBuddy',
          );
        const environment = {
          ...process.env,
          TARGET_BUILD_DIR: directory,
          BUILT_PRODUCTS_DIR: directory,
          WRAPPER_NAME: "Fixture.app",
          EXPANDED_CODE_SIGN_IDENTITY: "-",
        };
        const result = Bun.spawnSync(["bash", "-c", phase], {
          env: environment,
          stdout: "pipe",
          stderr: "pipe",
        });
        expect(new TextDecoder().decode(result.stderr)).not.toContain("failed");
        expect(result.exitCode).toBe(0);
        const helper = resolve(
          directory,
          "Fixture.app/Contents/Library/LoginItems/Edith.app",
        );
        expect(existsSync(resolve(helper, "Contents/MacOS/._Edith"))).toBe(
          false,
        );
        expect(existsSync(resolve(source, "MacOS/._Edith"))).toBe(true);
        const verification = Bun.spawnSync(
          ["codesign", "--verify", "--strict", helper],
          { stdout: "pipe", stderr: "pipe" },
        );
        expect(verification.exitCode).toBe(0);
      } finally {
        rmSync(directory, { recursive: true, force: true });
      }
    },
  );

  test("launches the installed bundle as a new application instance", () => {
    expect(script).toContain('open -n "/Applications/Edith.app"');
  });

  test("names each development build after its worktree folder", () => {
    for (const [path, slot] of [
      ["/fixture/edith", "main"],
      ["/fixture/edith-openscreen", "openscreen"],
      ["/fixture/edith-Herdr_New.Agent", "herdr-new-agent"],
      ["/fixture/edith-", "main"],
    ]) {
      const result = Bun.spawnSync(
        ["bash", "scripts/dev-slots.sh", "slot", path],
        { stdout: "pipe", stderr: "pipe", timeout: 5000 },
      );
      expect(result.exitCode).toBe(0);
      expect(new TextDecoder().decode(result.stdout).trim()).toBe(slot);
    }
    expect(script).toContain('SLOT="$(scripts/dev-slots.sh claim)"');
    expect(script).toContain(["$", '{SLOT:+--slot "$SLOT"}'].join(""));
  });

  test("never launches a production copy outside /Applications", () => {
    expect(script).toContain('"$LSREGISTER" -u "$APP"');
    expect(script).toContain('elif [ "$NO_OPEN" != 1 ]; then');
    expect(script).not.toContain('[ "$NO_OPEN" = 1 ] || open "$APP"');
  });
});
