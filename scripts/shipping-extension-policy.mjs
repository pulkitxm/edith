import { readFileSync } from "node:fs";

let manifestIDs;

export function shippingExtensionIDs() {
  manifestIDs ??= Object.freeze(
    JSON.parse(
      readFileSync(
        new URL("../Extensions/manifest.json", import.meta.url),
        "utf8",
      ),
    ).map(({ id }) => id),
  );
  return manifestIDs;
}

export function assertShippingExtensions(entries) {
  if (
    !Array.isArray(entries) ||
    new Set(entries.map((entry) => entry.id)).size !== entries.length ||
    entries.some((entry) => !shippingExtensionIDs().includes(entry.id))
  )
    throw new Error("Extension is outside the shipping release scope");
}

export function shippingDefinitions(definitions) {
  if (!Array.isArray(definitions))
    throw new Error("Invalid extension definitions");
  const ids = shippingExtensionIDs();
  const selected = ids.map((id) => {
    const matches = definitions.filter((entry) => entry.id === id);
    if (matches.length !== 1)
      throw new Error(
        `Require exactly one shipping extension definition: ${id}`,
      );
    const entry = matches[0];
    if (
      !Array.isArray(entry.dependencies) ||
      entry.dependencies.some((dependency) => !ids.includes(dependency))
    )
      throw new Error(`Unreleased shipping extension dependency: ${id}`);
    return entry;
  });
  if (selected.length !== definitions.length)
    throw new Error("Extension is outside the shipping release scope");
  assertShippingExtensions(selected);
  return selected;
}
