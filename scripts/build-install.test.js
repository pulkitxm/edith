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

  test("shares resources with the nested login item", () => {
    expect(script).toContain(
      'ln -s ../../../../../Resources/AppIcon.icns "$HELPER/Contents/Resources/AppIcon.icns"',
    );
    expect(script).toContain(
      '"$HELPER/Contents/Resources/Edith_EdithKit.bundle"',
    );
  });

  test("requests a normal application quit before replacing the bundle", () => {
    const stop = script.indexOf("stop_installed_app");
    const replace = script.indexOf('rm -rf "/Applications/Edith.app"');

    expect(script).toContain('tell application id "com.pulkit.edith" to quit');
    expect(stop).toBeGreaterThan(-1);
    expect(replace).toBeGreaterThan(stop);
  });

  test("targets the app and helper by exact runtime identities", () => {
    expect(script).toContain('pgrep -f -x "$1"');
    expect(script).toContain('pkill -TERM -f -x "$executable"');
    expect(script).toContain("/Applications/Edith.app/Contents/MacOS/Edith");
    expect(script).toContain(
      "/Applications/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/MacOS/Edith",
    );
    expect(script).toContain('stop_process "com.pulkit.edith.helper"');
    expect(script).not.toContain("killall Edith");
  });

  test("launches the installed bundle as a new application instance", () => {
    expect(script).toContain('open -n "/Applications/Edith.app"');
  });
});
