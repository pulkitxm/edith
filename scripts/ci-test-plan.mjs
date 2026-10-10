import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function planSwiftTests(paths, { all = false } = {}) {
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
  if (matches(/^Packages\/ExtensionSupport\//)) {
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
