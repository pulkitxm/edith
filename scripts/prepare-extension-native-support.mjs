import { readFileSync } from "node:fs";
import { resolve, sep } from "node:path";
import {
  buildExtensionSupport,
  supportModules,
  supportProducts,
} from "./build-extension-support.mjs";

export function prepareNativeSupport(
  root,
  definition,
  build = buildExtensionSupport,
) {
  if (definition.nativeSupportProduct == null) return undefined;
  if (
    typeof definition.nativePackage !== "string" ||
    !definition.nativePackage ||
    typeof definition.nativeProduct !== "string" ||
    !definition.nativeProduct ||
    !resolve(root, definition.nativePackage).startsWith(
      `${resolve(root)}${sep}`,
    )
  )
    throw new Error(
      "Native support requires an owned native package and product",
    );
  const scope = `${definition.id}_native`;
  supportModules(scope);
  supportProducts(definition.nativeSupportProduct);
  return build(root, definition.nativeSupportProduct, scope);
}

if (import.meta.main) {
  if (process.argv.length !== 3)
    throw new Error("Specify exactly one extension");
  const root = resolve(".");
  const definitions = JSON.parse(
    readFileSync(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  const definition = definitions.find(({ id }) => id === process.argv[2]);
  if (!definition) throw new Error("Unknown extension");
  prepareNativeSupport(root, definition);
}
