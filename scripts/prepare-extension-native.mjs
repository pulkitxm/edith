import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  ghosttyNativeFingerprint,
  ghosttyNativeInputs,
  verifyGhosttyArtifacts,
} from "./extension-ghostty-native.mjs";

export async function ghosttyReady(root) {
  try {
    await verifyGhosttyArtifacts(root, await ghosttyNativeFingerprint(root));
    return true;
  } catch {
    return false;
  }
}

export async function prepareExtensionNative(
  root,
  id,
  {
    ready = ghosttyReady,
    build = (cwd) =>
      spawnSync("bash", ["scripts/build-ghostty.sh"], {
        cwd,
        stdio: "inherit",
      }).status === 0,
  } = {},
) {
  const manifest = JSON.parse(
    await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  const definition = manifest.find((entry) => entry.id === id);
  if (!definition) throw new Error(`Unknown extension ${id}`);
  if (!ghosttyNativeInputs(definition).length) return "not-needed";
  if (await ready(root)) return "ready";
  if (!build(root)) throw new Error("Ghostty native build failed");
  return "built";
}

if (
  process.argv[1] &&
  pathToFileURL(resolve(process.argv[1])).href === import.meta.url
) {
  try {
    const state = await prepareExtensionNative(process.cwd(), process.argv[2]);
    process.stderr.write(`Ghostty native artifacts: ${state}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
