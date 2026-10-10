import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  definitionSupportInputs,
  planExtensionBuilds,
} from "./extension-release-plan.mjs";
import { extensionTestTargets } from "./test-extension-package.mjs";

const definitions = JSON.parse(
  readFileSync(new URL("../Extensions/manifest.json", import.meta.url), "utf8"),
);

export function planSwiftTests(
  paths,
  { all = false, extensions = definitions } = {},
) {
  const force =
    all ||
    paths.some((path) =>
      /^(Makefile|\.swift-format|scripts\/ci-test-plan\.mjs)$|^\.github\/(workflows|actions)\//.test(
        path,
      ),
    );
  const matches = (pattern) =>
    force || paths.some((path) => pattern.test(path));
  const include = [];
  if (
    matches(
      /^Packages\/(EdithHost|ExtensionMarketplace)\/|^Packages\/ExtensionSupport\/(Package\.(swift|resolved)$|Sources\/(EdithExtensionSupport|EdithExtensionUI)\/)/,
    )
  ) {
    include.push({
      lane: "host-runtime",
      targets: "ci-host ci-marketplace-runtime",
    });
  }
  const targets = [];
  if (
    matches(
      /^Packages\/ExtensionSupport\/|^Extensions\/Package\.(swift|resolved)$|^Extensions\/fixtureSupport\//,
    )
  ) {
    targets.push("ci-extension-support");
  }
  if (
    matches(
      /^Packages\/EdithDocsWorker\/|^Extensions\/docs\/|^scripts\/generate-cli-docs-bundle\.mjs$/,
    )
  ) {
    targets.push("ci-extension-docs");
  }
  if (targets.length > 0) {
    include.push({ lane: "feature-models", targets: targets.join(" ") });
  }
  if (matches(/^Extensions\/music\/Native\//)) {
    include.push({ lane: "native-music", targets: "ci-music-native" });
  }
  const owners = extensions.map((definition) => ({
    ...definition,
    inputs: definition.inputs ?? [`Extensions/${definition.id}`],
    sharedInputs: definition.sharedInputs ?? [],
    dependencies: definition.dependencies ?? [],
    sameExecutableWorker: false,
  }));
  const supportPackageChanged = paths.some((path) =>
    /^Packages\/ExtensionSupport\/Package\.(swift|resolved)$/.test(path),
  );
  const selectedIDs = new Set(
    planExtensionBuilds(
      owners,
      paths.filter((path) => !path.startsWith("Extensions/music/Native/")),
    ).map(({ id }) => id),
  );
  const selected = owners.filter(
    (definition) =>
      force ||
      paths.includes("Extensions/manifest.json") ||
      selectedIDs.has(definition.id) ||
      (supportPackageChanged && definitionSupportInputs(definition).length > 0),
  );
  for (const definition of selected) {
    if (!/^[A-Za-z][A-Za-z0-9_-]*$/.test(definition.id))
      throw new Error("Invalid extension test owner");
    const ownedTargets = extensionTestTargets(definition);
    if (ownedTargets.length === 0) {
      if (!targets.includes("ci-extension-support"))
        targets.unshift("ci-extension-support");
      continue;
    }
    include.push({
      lane: `extension-${definition.id}`,
      extension: definition.id,
      targets: ownedTargets.join(" "),
      ghostty: definition.nativeProduct === "GhosttyTerminal",
    });
  }
  const featureModels = include.find((lane) => lane.lane === "feature-models");
  if (featureModels) featureModels.targets = targets.join(" ");
  else if (targets.length > 0)
    include.splice(include[0]?.lane === "host-runtime" ? 1 : 0, 0, {
      lane: "feature-models",
      targets: targets.join(" "),
    });
  return { include };
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const arguments_ = process.argv.slice(2);
  if (arguments_.some((argument) => argument !== "--all")) {
    throw new Error("Only --all is supported.");
  }
  const paths = readFileSync(0, "utf8").split("\n").filter(Boolean);
  process.stdout.write(
    JSON.stringify(
      planSwiftTests(paths, { all: arguments_.includes("--all") }),
    ),
  );
}
