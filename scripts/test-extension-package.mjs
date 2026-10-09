import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";

export function runExtensionPackageTests(definition, run = execFileSync) {
  const targets = definition.testTargets ?? [];
  if (
    !Array.isArray(targets) ||
    targets.length > 4 ||
    new Set(targets).size !== targets.length ||
    targets.some(
      (target) =>
        typeof target !== "string" ||
        !/^ci-extension-[A-Za-z][A-Za-z0-9-]{0,127}$/.test(target),
    )
  )
    throw new Error("Invalid extension test targets");
  if (targets.length) run("make", targets, { stdio: "inherit" });
}

if (import.meta.main) {
  if (process.argv.length !== 3)
    throw new Error("Specify exactly one extension to test");
  const definitions = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
  );
  const definition = definitions.find(({ id }) => id === process.argv[2]);
  if (!definition || definition.contractVersion !== 1)
    throw new Error("Unknown native extension worker");
  runExtensionPackageTests(definition);
}
