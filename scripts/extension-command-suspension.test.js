import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const handlesCommands = /@objc(?:\(invoke:completion:\))?\s+func\s+invoke\s*\(/;
const suspendsCommands =
  /@objc\(suspendCommandsWithCompletion:\)\s+func\s+\w+\s*\(/;

async function roleSources() {
  const manifest = JSON.parse(
    await readFile(new URL("Extensions/manifest.json", root), "utf8"),
  );
  const result = [];
  for (const entry of manifest)
    for (const [role, paths] of Object.entries(entry.roles ?? {}))
      result.push({
        id: entry.id,
        role,
        sources: await Promise.all(
          paths
            .filter((path) => path.endsWith(".swift"))
            .map(async (path) => ({
              path,
              text: await readFile(new URL(path, root), "utf8"),
            })),
        ),
      });
  return result;
}

test("every extension runtime that handles commands can suspend them", async () => {
  const roles = await roleSources();
  const handling = [];
  const missing = [];
  for (const { id, role, sources } of roles)
    for (const { path, text } of sources) {
      if (!handlesCommands.test(text)) continue;
      handling.push(path);
      if (!suspendsCommands.test(text)) missing.push(`${id}/${role}: ${path}`);
    }
  expect(handling).toContain("Extensions/codeStats/Runtime.swift");
  expect(handling).toContain("Extensions/music/Runtime.swift");
  expect(handling).toContain("Extensions/studio/Runtime.swift");
  expect(missing).toEqual([]);
});

test("the suspension contract recognizes both declaration forms", () => {
  expect(
    handlesCommands.test(
      "@objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {",
    ),
  ).toBe(true);
  expect(
    handlesCommands.test(
      "@objc(invoke:completion:)\n    func invoke(_ request: NSDictionary, completion: @escaping () -> Void) {",
    ),
  ).toBe(true);
  expect(
    handlesCommands.test(
      'client.responds(to: NSSelectorFromString("invoke:completion:"))',
    ),
  ).toBe(false);
  expect(
    suspendsCommands.test(
      "@objc(suspendCommandsWithCompletion:)\n    func suspendCommands(completion: @escaping () -> Void) {",
    ),
  ).toBe(true);
  expect(
    suspendsCommands.test(
      'NSSelectorFromString("suspendCommandsWithCompletion:")',
    ),
  ).toBe(false);
});
