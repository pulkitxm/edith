import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { relative, resolve } from "node:path";

export function planExtensionBuilds(definitions, changes) {
  const ids = new Set(definitions.map(({ id }) => id));
  if (ids.size !== definitions.length)
    throw new Error("Duplicate extension id");
  for (const definition of definitions) {
    if (!/^[A-Za-z][A-Za-z0-9_-]*$/.test(definition.id))
      throw new Error("Invalid extension id");
    if (definition.dependencies.some((id) => !ids.has(id)))
      throw new Error("Unknown dependency");
  }
  const selected = new Set();
  for (const definition of definitions) {
    if (
      changes.some((path) =>
        [...definition.inputs, ...definition.sharedInputs].some(
          (input) => path === input || path.startsWith(`${input}/`),
        ),
      )
    ) {
      selected.add(definition.id);
    }
  }
  let changed = true;
  while (changed) {
    changed = false;
    for (const definition of definitions) {
      if (
        !selected.has(definition.id) &&
        definition.dependencies.some((id) => selected.has(id))
      ) {
        selected.add(definition.id);
        changed = true;
      }
    }
  }
  return definitions.filter(({ id }) => selected.has(id));
}

export async function extensionFingerprint(root, definition, definitions) {
  const inputs = new Set();
  const visited = new Set();
  const visiting = new Set();
  async function visit(id) {
    if (visiting.has(id)) throw new Error("Dependency cycle");
    if (visited.has(id)) return;
    const current = definitions.find((candidate) => candidate.id === id);
    if (!current) throw new Error("Unknown dependency");
    visiting.add(id);
    for (const input of [...current.inputs, ...current.sharedInputs])
      inputs.add(input);
    for (const dependency of current.dependencies) await visit(dependency);
    visiting.delete(id);
    visited.add(id);
  }
  await visit(definition.id);
  const files = new Map();
  async function collect(path) {
    const absolute = resolve(root, path);
    if (!absolute.startsWith(`${resolve(root)}/`))
      throw new Error("Input outside repository");
    let entries;
    try {
      entries = await readdir(absolute, { withFileTypes: true });
    } catch (error) {
      if (error.code !== "ENOTDIR") throw error;
      files.set(relative(root, absolute), await readFile(absolute));
      return;
    }
    for (const entry of entries) {
      if (entry.isSymbolicLink()) throw new Error("Symlink in extension input");
      await collect(`${path}/${entry.name}`);
    }
  }
  for (const input of [...inputs].sort()) await collect(input);
  const digest = createHash("sha256").update(JSON.stringify(definition));
  for (const [path, bytes] of [...files].sort(([a], [b]) =>
    a.localeCompare(b),
  )) {
    digest.update(`${path}\0${bytes.length}\0`).update(bytes);
  }
  return digest.digest("hex");
}

if (import.meta.main) {
  const root = process.cwd();
  const definitions = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
  );
  const base = process.argv[2];
  if (!base) throw new Error("Supply the base commit for change detection");
  const changes = execFileSync(
    "git",
    ["diff", "--name-only", "-z", base, "HEAD"],
    { encoding: "utf8" },
  )
    .split("\0")
    .filter(Boolean);
  const selected = planExtensionBuilds(definitions, changes);
  const include = await Promise.all(
    selected.map(async (definition) => {
      const fingerprint = await extensionFingerprint(
        root,
        definition,
        definitions,
      );
      return {
        id: definition.id,
        fingerprint,
        tag: `extensions/${definition.id}/${fingerprint.slice(0, 20)}`,
      };
    }),
  );
  process.stdout.write(`${JSON.stringify({ include })}\n`);
}
