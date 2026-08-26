import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const script = readFileSync(resolve("build.sh"), "utf8");

describe("build install lifecycle", () => {
  test("requests a normal application quit before replacing the bundle", () => {
    const stop = script.indexOf("stop_installed_app");
    const replace = script.indexOf('rm -rf "/Applications/Edith.app"');

    expect(script).toContain('tell application id "com.pulkit.edith" to quit');
    expect(stop).toBeGreaterThan(-1);
    expect(replace).toBeGreaterThan(stop);
  });

  test("targets the app and helper by exact executable path", () => {
    expect(script).toContain('pgrep -f -x "$1"');
    expect(script).toContain('pkill -TERM -f -x "$executable"');
    expect(script).toContain("/Applications/Edith.app/Contents/MacOS/Edith");
    expect(script).toContain(
      "/Applications/Edith.app/Contents/Library/LoginItems/Edith.app/Contents/MacOS/Edith",
    );
    expect(script).not.toContain("killall Edith");
  });
});
