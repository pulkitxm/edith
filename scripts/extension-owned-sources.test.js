import { expect, test } from "bun:test";
import {
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, resolve } from "node:path";

async function ownedSources(
  root,
  directory,
  { excluded, native = false } = {},
) {
  const result = [];
  const extensions = new Set(
    native
      ? [".swift", ".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".m", ".mm"]
      : [".swift"],
  );
  for (const entry of await readdir(resolve(root, directory), {
    withFileTypes: true,
  })) {
    if (
      ["Tests", "EmbeddedTests", ".build", ".swiftpm", "vendor"].includes(
        entry.name,
      )
    )
      continue;
    const path = `${directory}/${entry.name}`;
    if (path === excluded) continue;
    if (entry.isDirectory())
      result.push(...(await ownedSources(root, path, { excluded, native })));
    else if (
      extensions.has(extname(entry.name)) &&
      entry.name !== "Package.swift"
    )
      result.push(path);
  }
  return result;
}

test("every owned worker source is included in a downloaded role", async () => {
  const root = resolve(import.meta.dir, "..");
  const definitions = JSON.parse(
    await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  for (const definition of definitions.filter(
    ({ contractVersion }) => contractVersion === 1,
  )) {
    const listed = new Set(Object.values(definition.roles).flat());
    const nativeSources = new Set(definition.nativeSources ?? []);
    expect(listed.size).toBeGreaterThan(0);
    if (definition.nativePackage) {
      expect(definition.nativeProduct).toBeTruthy();
      const native = await ownedSources(root, definition.nativePackage, {
        native: true,
      });
      expect(native.length).toBeGreaterThan(0);
      for (const source of native)
        expect(
          listed.has(source),
          `${definition.id} compiles native ${source} twice`,
        ).toBe(false);
      if (nativeSources.size)
        for (const source of native)
          expect(
            nativeSources.has(source),
            `${definition.id} omits native ${source} from its source inventory`,
          ).toBe(true);
    }
    for (const source of await ownedSources(
      root,
      `Extensions/${definition.id}`,
      { excluded: definition.nativePackage },
    )) {
      expect(
        listed.has(source),
        `${definition.id} omits ${source} from downloaded roles`,
      ).toBe(true);
    }
    for (const source of definition.nativeSources ?? []) {
      expect(definition.nativePackage).toBeTruthy();
      expect(source.startsWith(`${definition.nativePackage}/Sources/`)).toBe(
        true,
      );
    }
    for (const source of new Set([...listed, ...nativeSources]))
      await readFile(resolve(root, source));
  }
});

test("downloaded resources are assigned to declared worker roles", async () => {
  const root = resolve(import.meta.dir, "..");
  const definitions = JSON.parse(
    await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  for (const definition of definitions.filter(
    ({ contractVersion }) => contractVersion === 1,
  )) {
    const resources = definition.resources ?? {};
    expect(
      Array.isArray(resources),
      `${definition.id} resources need role keys`,
    ).toBe(false);
    for (const [role, paths] of Object.entries(resources)) {
      expect(Object.hasOwn(definition.roles, role)).toBe(true);
      expect(Array.isArray(paths)).toBe(true);
      expect(new Set(paths).size).toBe(paths.length);
      for (const path of paths) await readFile(resolve(root, path));
    }
  }
});

test("native inventory includes compiled native languages and headers without test or vendor files", async () => {
  const root = await mkdtemp(resolve(tmpdir(), "extension-native-inventory-"));
  try {
    const fixtures = [
      "Native/Sources/Module/Runtime.cpp",
      "Native/Sources/Module/include/Runtime.h",
      "Native/Sources/Module/Glue.mm",
      "Native/Sources/Module/Bridge.swift",
      "Native/Tests/Fixture.swift",
      "Native/EmbeddedTests/BrowserFixture.swift",
      "Native/vendor/External.cpp",
      "Native/.build/Generated.swift",
      "Native/Package.swift",
      "Native/Sources/Module/weights.onnx",
      "Feature/Runtime.swift",
    ];
    for (const path of fixtures) {
      await mkdir(resolve(root, path, ".."), { recursive: true });
      await writeFile(resolve(root, path), "");
    }
    expect(
      (await ownedSources(root, "Native", { native: true })).sort(),
    ).toEqual(fixtures.slice(0, 4).sort());
    expect(await ownedSources(root, "Native")).toEqual([
      "Native/Sources/Module/Bridge.swift",
    ]);
    expect(await ownedSources(root, "Feature")).toEqual([
      "Feature/Runtime.swift",
    ]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
