import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { extensionFingerprint } from "./extension-release-plan.mjs";

const root = process.cwd();
const definitions = JSON.parse(
  await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
);
const result = {};
for (const definition of definitions.filter(
  (entry) => entry.contractVersion === 1,
))
  result[definition.id] = await extensionFingerprint(
    root,
    definition,
    definitions,
  );
process.stdout.write(`${JSON.stringify(result)}\n`);
