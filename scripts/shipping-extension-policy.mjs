export const shippingExtensionIDs = Object.freeze(["keepAwake"]);

export function assertShippingExtensions(entries) {
  if (
    !Array.isArray(entries) ||
    new Set(entries.map((entry) => entry.id)).size !== entries.length ||
    entries.some((entry) => !shippingExtensionIDs.includes(entry.id))
  )
    throw new Error("Extension is outside the shipping release scope");
}

export function shippingDefinitions(definitions) {
  if (!Array.isArray(definitions))
    throw new Error("Invalid extension definitions");
  const selected = shippingExtensionIDs.map((id) => {
    const matches = definitions.filter((entry) => entry.id === id);
    if (matches.length !== 1)
      throw new Error(
        `Require exactly one shipping extension definition: ${id}`,
      );
    const entry = matches[0];
    if (
      !Array.isArray(entry.dependencies) ||
      entry.dependencies.some(
        (dependency) => !shippingExtensionIDs.includes(dependency),
      )
    )
      throw new Error(`Unreleased shipping extension dependency: ${id}`);
    return entry;
  });
  assertShippingExtensions(selected);
  return selected;
}
