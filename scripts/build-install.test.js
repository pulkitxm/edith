import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const script = readFileSync(resolve("build.sh"), "utf8");
const launcher = readFileSync(resolve("Resources/ed-launcher"), "utf8");

describe("build install lifecycle", () => {
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
      expect(output).toContain("Ran 10 tests");
      expect(output).toContain("OK");
      expect(result.exitCode).toBe(0);
    },
    35000,
  );

  test("launches the installed bundle as a new application instance", () => {
    expect(script).toContain('open -n "/Applications/Edith.app"');
  });
});
