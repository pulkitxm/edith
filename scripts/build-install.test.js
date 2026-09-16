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

  test("routes CLI names through the application executable", () => {
    const removal = script.indexOf('rm -f "$APP/Contents/MacOS/edh"');
    const install = script.indexOf(
      'install -m 755 Resources/ed-launcher "$APP/Contents/Resources/ed-launcher"',
    );

    expect(removal).toBeGreaterThan(-1);
    expect(install).toBeGreaterThan(removal);
    expect(script).toContain(
      'ln -s ../Resources/ed-launcher "$APP/Contents/MacOS/ed"',
    );
    expect(launcher).toContain(
      'EDITH_CLI=1 exec "$edith_launcher_directory/../MacOS/Edith" "$@"',
    );
    expect(script).not.toContain('ln -sfn ed "$APP/Contents/MacOS/edith"');
    expect(script).not.toContain('sign_tool "$APP/Contents/MacOS/ed"');
  });

  test("removes unused executable architectures from every bundle", () => {
    expect(script).toContain('lipo "$binary" -thin arm64');
    expect(script).toContain('mv "$binary.arm64" "$binary"');
  });

  test("signs nested runtime libraries before their bundles", () => {
    const runtimeSigning = script.indexOf(
      'for library in "$APP"/Contents/Frameworks/*.dylib "$HELPER"/Contents/Frameworks/*.dylib; do',
    );
    const helperSigning = script.indexOf('sign "$HELPER"');
    const appSigning = script.indexOf('sign "$APP"');

    expect(runtimeSigning).toBeGreaterThan(-1);
    expect(helperSigning).toBeGreaterThan(runtimeSigning);
    expect(appSigning).toBeGreaterThan(helperSigning);
  });

  test("shares resources with the nested login item", () => {
    expect(script).toContain(
      'ln -s ../../../../../Resources/AppIcon.icns "$HELPER/Contents/Resources/AppIcon.icns"',
    );
    expect(script).toContain(
      '"$HELPER/Contents/Resources/Edith_EdithKit.bundle"',
    );
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
      expect(output).toContain("Ran 13 tests");
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
});
