import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const script = readFileSync(resolve("build.sh"), "utf8");

describe("build install lifecycle", () => {
  test("routes CLI names through the application executable", () => {
    const removal = script.indexOf('rm -f "$APP/Contents/MacOS/edh"');
    const link = script.indexOf('ln -s Edith "$APP/Contents/MacOS/ed"');

    expect(removal).toBeGreaterThan(-1);
    expect(link).toBeGreaterThan(removal);
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
});
