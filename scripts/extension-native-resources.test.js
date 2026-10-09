import { expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { copyNativeResources } from "./build-extension-package.mjs";

test("native Swift resources and explicit licenses retain their bundle structure", async () => {
  const root = await mkdtemp(join(tmpdir(), "extension-native-resources-"));
  try {
    const nativePackage = "Extensions/mock/Native";
    const bundle = "MockParser_MockParser.bundle";
    await mkdir(join(root, nativePackage, ".build/release", bundle, "assets"), {
      recursive: true,
    });
    await writeFile(
      join(root, nativePackage, ".build/release", bundle, "assets/theme.css"),
      "synthetic theme",
    );
    await writeFile(join(root, nativePackage, "LICENSE"), "synthetic license");
    const contents = join(root, "mock.bundle/Contents");
    await copyNativeResources(
      root,
      {
        nativePackage,
        nativeResources: [bundle],
        nativeLicenses: [
          {
            source: join(nativePackage, "LICENSE"),
            destination: "Parser-LICENSE",
          },
        ],
      },
      contents,
    );
    expect(
      await readFile(
        join(contents, "Resources", bundle, "assets/theme.css"),
        "utf8",
      ),
    ).toBe("synthetic theme");
    expect(
      await readFile(join(contents, "Resources/Parser-LICENSE"), "utf8"),
    ).toBe("synthetic license");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("native resources reject collisions and destination paths outside Resources", async () => {
  const root = await mkdtemp(
    join(tmpdir(), "extension-native-resource-names-"),
  );
  try {
    for (const name of [
      "../Runtime",
      "/absolute",
      "",
      ".",
      "..",
      "existing.bundle",
    ]) {
      await expect(
        copyNativeResources(
          root,
          {
            nativePackage: "Extensions/mock/Native",
            nativeResources: [name],
          },
          join(root, "mock.bundle/Contents"),
          new Set(["existing.bundle"]),
        ),
      ).rejects.toThrow("invalid native resource");
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
