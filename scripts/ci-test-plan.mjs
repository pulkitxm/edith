import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
import {
  definitionSupportInputs,
  planExtensionBuilds,
} from "./extension-release-plan.mjs";
import { shippingDefinitions } from "./shipping-extension-policy.mjs";
import { extensionTestTargets } from "./test-extension-package.mjs";

const definitions = JSON.parse(
  readFileSync(new URL("../Extensions/manifest.json", import.meta.url), "utf8"),
);

function nativeCIInputs(configuration) {
  const record = (value) =>
    value !== null && typeof value === "object" && !Array.isArray(value);
  if (
    !record(configuration) ||
    !record(configuration.jobs) ||
    !record(configuration.on) ||
    !("pull_request" in configuration.on) ||
    !("push" in configuration.on)
  )
    throw new Error("Native workflow scope requires a complete workflow");
  const jobs = Object.create(null);
  const active = new Set();
  const selected = new Set();
  const visit = (id) => {
    if (!/^[A-Za-z_][A-Za-z0-9_-]*$/.test(id) || active.has(id))
      throw new Error("Invalid native workflow dependency");
    if (selected.has(id)) return;
    const job = configuration.jobs[id];
    if (!record(job)) throw new Error("Missing native workflow dependency");
    active.add(id);
    const dependencies =
      job.needs === undefined
        ? []
        : typeof job.needs === "string"
          ? [job.needs]
          : job.needs;
    if (
      !Array.isArray(dependencies) ||
      dependencies.some((dependency) => typeof dependency !== "string")
    )
      throw new Error("Invalid native workflow dependencies");
    for (const dependency of dependencies) visit(dependency);
    active.delete(id);
    selected.add(id);
    jobs[id] = job;
  };
  for (const root of ["changes", "swift-build", "swift-test"]) visit(root);
  const triggers = { ...configuration.on };
  delete triggers.workflow_dispatch;
  return {
    workflow: { ...configuration, on: triggers, jobs },
    jobIDs: Object.keys(configuration.jobs).sort(),
  };
}

export function nativeCIWorkflowsEqual(previous, current) {
  try {
    return isDeepStrictEqual(nativeCIInputs(previous), nativeCIInputs(current));
  } catch {
    return false;
  }
}

export function planSwiftTests(
  paths,
  { all = false, extensions = definitions, shipping = false, ciWorkflow } = {},
) {
  const releaseOnlyCI =
    !all &&
    !shipping &&
    ciWorkflow &&
    nativeCIWorkflowsEqual(ciWorkflow.previous, ciWorkflow.current);
  const force =
    all ||
    paths.some(
      (path) =>
        !(releaseOnlyCI && path === ".github/workflows/ci.yml") &&
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
  if (matches(/^Extensions\/music\/Native\//)) {
    include.push({ lane: "native-music", targets: "ci-music-native" });
  }
  if (shipping) shippingDefinitions(extensions);
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
    if (ownedTargets.includes("ci-extension-accounts-local"))
      throw new Error("Local account checks cannot enter hosted lanes");
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
  const docsTarget = targets.indexOf("ci-extension-docs");
  if (
    docsTarget >= 0 &&
    include.some(
      (lane) =>
        lane.extension === "docs" &&
        lane.targets.split(" ").includes("ci-extension-docs"),
    )
  ) {
    targets.splice(docsTarget, 1);
  }
  if (targets.length > 0)
    include.splice(include[0]?.lane === "host-runtime" ? 1 : 0, 0, {
      lane: "feature-models",
      targets: targets.join(" "),
    });
  const scheduledTargets = new Set();
  return {
    include: include
      .map((lane) => ({
        ...lane,
        targets: lane.targets
          .split(" ")
          .filter((target) => {
            if (scheduledTargets.has(target)) return false;
            scheduledTargets.add(target);
            return true;
          })
          .join(" "),
      }))
      .filter((lane) => lane.targets.length > 0),
  };
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const arguments_ = process.argv.slice(2);
  const pullRequestBases = arguments_.filter((argument) =>
    argument.startsWith("--pull-request-base="),
  );
  if (
    pullRequestBases.length > 1 ||
    arguments_.some(
      (argument) =>
        !["--all", "--shipping"].includes(argument) &&
        !/^--pull-request-base=[a-f0-9]{40}$/.test(argument),
    )
  )
    throw new Error(
      "Only --all, --shipping and one exact --pull-request-base are supported.",
    );
  const paths = readFileSync(0, "utf8").split("\n").filter(Boolean);
  let ciWorkflow;
  if (
    pullRequestBases.length === 1 &&
    paths.includes(".github/workflows/ci.yml")
  ) {
    try {
      const base = pullRequestBases[0].slice("--pull-request-base=".length);
      const previous = execFileSync(
        "git",
        ["show", `${base}:.github/workflows/ci.yml`],
        { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
      );
      ciWorkflow = {
        previous: globalThis.Bun.YAML.parse(previous),
        current: globalThis.Bun.YAML.parse(
          readFileSync(
            new URL("../.github/workflows/ci.yml", import.meta.url),
            "utf8",
          ),
        ),
      };
    } catch {
      ciWorkflow = undefined;
    }
  }
  process.stdout.write(
    JSON.stringify(
      planSwiftTests(paths, {
        all: arguments_.includes("--all"),
        shipping: arguments_.includes("--shipping"),
        ciWorkflow,
      }),
    ),
  );
}
