import { describe, expect, test } from "bun:test";
import { prepareExtensionNative } from "./prepare-extension-native.mjs";

const root = process.cwd();

describe("prepareExtensionNative", () => {
  test("builds Ghostty for ghostty extensions when artifacts are missing", async () => {
    for (const id of ["machines", "terminal"]) {
      const builds = [];
      const state = await prepareExtensionNative(root, id, {
        ready: async () => false,
        build: (cwd) => builds.push(cwd) > 0,
      });
      expect(state).toBe("built");
      expect(builds).toEqual([root]);
    }
  });

  test("skips the build when artifacts are verified", async () => {
    let built = false;
    const state = await prepareExtensionNative(root, "machines", {
      ready: async () => true,
      build: () => {
        built = true;
        return true;
      },
    });
    expect(state).toBe("ready");
    expect(built).toBe(false);
  });

  test("ignores extensions without Ghostty", async () => {
    const state = await prepareExtensionNative(root, "keepAwake", {
      ready: async () => false,
      build: () => {
        throw new Error("unexpected build");
      },
    });
    expect(state).toBe("not-needed");
  });

  test("reports build failure and unknown ids", async () => {
    await expect(
      prepareExtensionNative(root, "machines", {
        ready: async () => false,
        build: () => false,
      }),
    ).rejects.toThrow("Ghostty native build failed");
    await expect(prepareExtensionNative(root, "nope")).rejects.toThrow(
      "Unknown extension nope",
    );
  });
});
