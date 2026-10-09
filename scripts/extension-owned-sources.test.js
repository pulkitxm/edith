import { expect, test } from "bun:test";
import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";

test("every owned worker source is included in a downloaded role", async () => {
  const root = resolve(import.meta.dir, "..");
  const definitions = JSON.parse(
    await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  async function files(directory) {
    const result = [];
    for (const entry of await readdir(resolve(root, directory), {
      withFileTypes: true,
    })) {
      if (["Tests", ".build", ".swiftpm"].includes(entry.name)) continue;
      const path = `${directory}/${entry.name}`;
      if (entry.isDirectory()) result.push(...(await files(path)));
      else if (entry.name.endsWith(".swift") && entry.name !== "Package.swift")
        result.push(path);
    }
    return result;
  }
  for (const definition of definitions.filter(
    ({ contractVersion }) => contractVersion === 1,
  )) {
    const listed = new Set(Object.values(definition.roles).flat());
    expect(listed.size).toBeGreaterThan(0);
    for (const source of await files(`Extensions/${definition.id}`)) {
      expect(
        listed.has(source),
        `${definition.id} omits ${source} from downloaded roles`,
      ).toBe(true);
    }
    for (const source of listed) await readFile(resolve(root, source));
  }
});
