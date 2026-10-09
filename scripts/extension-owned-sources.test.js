import { expect, test } from "bun:test";
import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";

test("every owned worker source is included in a downloaded role", async () => {
  const root = resolve(import.meta.dir, "..");
  const definitions = JSON.parse(
    await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  async function files(directory, nativePackage) {
    const result = [];
    for (const entry of await readdir(resolve(root, directory), {
      withFileTypes: true,
    })) {
      if (["Tests", ".build", ".swiftpm", "vendor"].includes(entry.name)) continue;
      const path = `${directory}/${entry.name}`;
      if (path === nativePackage) continue;
      if (entry.isDirectory()) result.push(...(await files(path, nativePackage)));
      else if (entry.name.endsWith(".swift") && entry.name !== "Package.swift")
        result.push(path);
    }
    return result;
  }
  for (const definition of definitions.filter(
    ({ contractVersion }) => contractVersion === 1,
  )) {
    const listed = new Set([
      ...Object.values(definition.roles).flat(),
      ...(definition.nativeSources ?? []),
    ]);
    expect(listed.size).toBeGreaterThan(0);
    if (definition.nativePackage) {
      expect(definition.nativeProduct).toBeTruthy();
      const native = await files(definition.nativePackage);
      expect(native.length).toBeGreaterThan(0);
      for (const source of native)
        expect(
          listed.has(source),
          `${definition.id} compiles native ${source} twice`,
        ).toBe(false);
    }
    for (const source of await files(
      `Extensions/${definition.id}`,
      definition.nativePackage,
    )) {
      expect(
        listed.has(source),
        `${definition.id} omits ${source} from downloaded roles`,
      ).toBe(true);
    }
    for (const source of definition.nativeSources ?? []) {
      expect(definition.nativePackage).toBeTruthy();
      expect(source.startsWith(`${definition.nativePackage}/Sources/`)).toBe(true);
    }
    for (const source of listed) await readFile(resolve(root, source));
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
