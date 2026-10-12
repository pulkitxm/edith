import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { relative, resolve } from "node:path";
import { supportSourceInputs } from "./build-extension-support.mjs";
import { ghosttyNativeInputs } from "./extension-ghostty-native.mjs";
import { writeHostABI } from "./extension-host-abi.mjs";
import { shippingDefinitions } from "./shipping-extension-policy.mjs";

export const workerRuntimeInputs = [
  "Packages/EdithHost/Package.swift",
  "Packages/EdithHost/Package.resolved",
  "scripts/build-minimal-host.mjs",
  "scripts/package-shipping-host.py",
  "Packages/EdithHost/Sources/HostBootstrap",
  "Packages/EdithHost/Sources/EdithHost/HostEntry.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostPublicLauncher.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostFolderChoiceNavigationClient.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostWorkerNavigationClient.swift",
  "Packages/EdithHost/Sources/EdithHost/HostWorkerApplication.swift",
  "Packages/EdithHost/Sources/EdithHost/HostWorkerStartAdmission.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostCoreAdmission.swift",
  "Extensions/fixtureSupport",
  "Packages/EdithHost/Sources/EdithHost/HostWorkerControl.swift",
  "Packages/EdithHost/Sources/EdithHost/HostNativeTask.swift",
  "Packages/EdithHost/Sources/EdithHost/HostRemoteApplication.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostWorkerProtocol.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostFolderChoiceResult.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostAmbientPolicyCoordinator.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostCoreBackgroundPolicy.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostWorkerProcessGroups.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostPrivilegedProcess.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostPrivilegedWorker.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostPrivilegedCarrier.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostPrivilegedAdmission.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostPrivilegedCaller.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostContainedRole.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostWorker.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostContract.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostExtensionSessions.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostSurfaces.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostRemoteProtocol.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostRemoteAuthentication.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostRemoteEndpoint.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostRemoteEngineBridge.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostRemoteEngineTransport.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostRemoteChannel.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostRemoteConfiguration.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostTerminalUIRequest.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostMachinesWindowTarget.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostHerdrWindowTarget.swift",
  "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace",
];

const excludedProductionDirectories = new Set([
  ".build",
  ".git",
  ".swiftpm",
  "node_modules",
  "dist",
  "build",
  "target",
  "Tests",
  "tests",
  "EmbeddedTests",
  "vendor",
]);

function excludedProductionInput(path) {
  return (
    path.split("/").at(-1) === ".DS_Store" ||
    path.split("/").some((part) => excludedProductionDirectories.has(part)) ||
    path ===
      "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift" ||
    path === "Extensions/database/DatabaseEngine/MCPTests" ||
    path.startsWith("Extensions/database/DatabaseEngine/MCPTests/")
  );
}

export function definitionSupportInputs(definition) {
  const products = [
    definition.supportProduct,
    definition.nativeSupportProduct,
    ...Object.values(definition.supportProducts ?? {}),
  ].filter(Boolean);
  return [...new Set(products.flatMap(supportSourceInputs))];
}

export function definitionInputs(definition) {
  const supportInputs = definitionSupportInputs(definition);
  const shared = supportInputs.length
    ? [
        ...definition.sharedInputs.filter(
          (path) =>
            path !== "Packages/ExtensionSupport" &&
            !path.startsWith("Packages/ExtensionSupport/"),
        ),
        ...supportInputs,
      ]
    : definition.sharedInputs;
  return [
    ...definition.inputs,
    ...ghosttyNativeInputs(definition),
    ...shared,
    ...(definition.sameExecutableWorker ? workerRuntimeInputs : []),
  ];
}

export async function supportCacheFingerprint(root, definition) {
  const supportInputs = definitionSupportInputs(definition);
  if (!supportInputs.length) return "none";
  const support = {
    supportProduct: definition.supportProduct,
    supportProducts: definition.supportProducts,
    nativeSupportProduct: definition.nativeSupportProduct,
    id: "support",
    inputs: ["scripts/build-extension-support.mjs", ...supportInputs],
    sharedInputs: [],
    dependencies: [],
  };
  return extensionFingerprint(root, support, [support]);
}

export function planExtensionBuilds(definitions, changes, changedIDs = []) {
  const ids = new Set(definitions.map(({ id }) => id));
  if (ids.size !== definitions.length)
    throw new Error("Duplicate extension id");
  for (const definition of definitions) {
    if (!/^[A-Za-z][A-Za-z0-9_-]*$/.test(definition.id))
      throw new Error("Invalid extension id");
    if (definition.dependencies.some((id) => !ids.has(id)))
      throw new Error("Unknown dependency");
  }
  if (changedIDs.some((id) => !ids.has(id)))
    throw new Error("Unknown changed extension");
  const selected = new Set(changedIDs);
  for (const definition of definitions) {
    if (
      changes.some(
        (path) =>
          path.split("/").at(-1) !== ".DS_Store" &&
          definitionInputs(definition).some(
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

export function planPullRequestBuilds(definitions, changes, priorDefinitions) {
  if (priorDefinitions === null)
    return planExtensionBuilds(
      definitions,
      [],
      definitions.map(({ id }) => id),
    );
  if (!Array.isArray(priorDefinitions))
    throw new Error("Invalid base extension manifest");
  planExtensionBuilds(priorDefinitions, []);
  const prior = new Map(priorDefinitions.map((entry) => [entry.id, entry]));
  const productionDefinition = (entry) => {
    if (!entry) return undefined;
    const value = { ...entry };
    delete value.testTargets;
    return JSON.stringify(value);
  };
  const changedIDs = definitions
    .filter(
      (entry) =>
        productionDefinition(entry) !==
        productionDefinition(prior.get(entry.id)),
    )
    .map(({ id }) => id);
  return planExtensionBuilds(
    definitions,
    changes.filter(
      (path) =>
        path !== "Extensions/manifest.json" && !excludedProductionInput(path),
    ),
    changedIDs,
  );
}

export function readPullRequestBaseline(root, baseSHA) {
  if (typeof baseSHA !== "string" || !/^[a-f0-9]{40}$/.test(baseSHA))
    throw new Error("Invalid pull request base commit");
  const git = (arguments_) =>
    execFileSync("git", arguments_, {
      cwd: root,
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024,
    });
  const actual = git(["rev-parse", "--verify", `${baseSHA}^{commit}`]).trim();
  if (actual !== baseSHA) throw new Error("Pull request base commit mismatch");
  const headSHA = git(["rev-parse", "--verify", "HEAD^{commit}"]).trim();
  const baseline = git(["merge-base", "--all", baseSHA, headSHA]).trim();
  if (!/^[a-f0-9]{40}$/.test(baseline))
    throw new Error("Pull request requires a unique merge base");
  if (
    git(["rev-parse", "--verify", `${baseline}^{commit}`]).trim() !== baseline
  )
    throw new Error("Pull request merge base commit mismatch");
  git(["merge-base", "--is-ancestor", baseline, baseSHA]);
  git(["merge-base", "--is-ancestor", baseline, headSHA]);
  const tree = git([
    "ls-tree",
    "-z",
    baseline,
    "--",
    "Extensions/manifest.json",
  ]);
  let priorDefinitions = null;
  if (tree) {
    if (!/^100644 blob [a-f0-9]{40}\tExtensions\/manifest\.json\0$/.test(tree))
      throw new Error("Invalid base extension manifest tree");
    priorDefinitions = JSON.parse(
      git(["show", `${baseline}:Extensions/manifest.json`]),
    );
    if (!Array.isArray(priorDefinitions))
      throw new Error("Invalid base extension manifest");
  }
  const changes = git([
    "diff",
    "--name-only",
    "-z",
    "--no-renames",
    baseline,
    headSHA,
    "--",
  ])
    .split("\0")
    .filter(Boolean);
  return { priorDefinitions, changes };
}

export async function planPullRequestExtensions(root, definitions, baseSHA) {
  const { priorDefinitions, changes } = readPullRequestBaseline(root, baseSHA);
  const selected = planPullRequestBuilds(
    definitions,
    changes,
    priorDefinitions,
  );
  return Promise.all(
    selected.map(async (definition) => {
      const fingerprint = await extensionFingerprint(
        root,
        definition,
        definitions,
      );
      return {
        id: definition.id,
        version: definition.version,
        fingerprint,
        tag: extensionReleaseTag({
          id: definition.id,
          version: definition.version,
          fingerprint,
        }),
        supportFingerprint: await supportCacheFingerprint(root, definition),
      };
    }),
  );
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
    for (const input of definitionInputs(current)) inputs.add(input);
    for (const dependency of current.dependencies) await visit(dependency);
    visiting.delete(id);
    visited.add(id);
  }
  await visit(definition.id);
  const files = new Map();
  async function collect(path) {
    if (excludedProductionInput(path)) return;
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
      if (excludedProductionInput(`${path}/${entry.name}`)) continue;
      if (entry.isSymbolicLink()) throw new Error("Symlink in extension input");
      await collect(`${path}/${entry.name}`);
    }
  }
  for (const input of [...inputs].sort()) await collect(input);
  const packageDefinition = { ...definition };
  delete packageDefinition.testTargets;
  const digest = createHash("sha256").update(JSON.stringify(packageDefinition));
  for (const [path, bytes] of [...files].sort(([a], [b]) =>
    a.localeCompare(b),
  )) {
    digest.update(`${path}\0${bytes.length}\0`).update(bytes);
  }
  return digest.digest("hex");
}

export async function planUnpublishedExtensions(
  root,
  definitions,
  publishedPackages,
) {
  const result = [];
  for (const definition of definitions) {
    const fingerprint = await extensionFingerprint(
      root,
      definition,
      definitions,
    );
    const prior = publishedPackages
      .filter(
        (entry) =>
          entry.id === definition.id &&
          entry.hostABI === definition.hostABI &&
          entry.architecture === "arm64",
      )
      .sort((a, b) =>
        a.version.localeCompare(b.version, undefined, { numeric: true }),
      )
      .at(-1);
    if (prior?.sourceFingerprint === fingerprint) continue;
    let version = definition.version;
    if (
      prior &&
      version.localeCompare(prior.version, undefined, { numeric: true }) <= 0
    ) {
      const parts = prior.version.split(".").map(Number);
      if (
        parts.length !== 3 ||
        parts.some((part) => !Number.isSafeInteger(part) || part < 0)
      )
        throw new Error("Invalid published version");
      parts[2] += 1;
      version = parts.join(".");
    }
    result.push({
      id: definition.id,
      fingerprint,
      version,
      tag: extensionReleaseTag({ id: definition.id, version, fingerprint }),
      supportFingerprint: await supportCacheFingerprint(root, definition),
    });
  }
  return result;
}

export function extensionReleaseTag({ id, version, fingerprint }) {
  if (
    typeof id !== "string" ||
    !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(id) ||
    typeof version !== "string" ||
    version.length > 96 ||
    !/^\d+\.\d+\.\d+$/.test(version) ||
    !version.split(".").every((part) => Number.isSafeInteger(Number(part))) ||
    typeof fingerprint !== "string" ||
    !/^[a-f0-9]{64}$/.test(fingerprint)
  )
    throw new Error("Invalid extension release identity");
  return `extensions/${id}/${version}-${fingerprint.slice(0, 20)}`;
}

export const validationExtensionIDs = [
  "keepAwake",
  "audioMixer",
  "focusDim",
  "windowSweaters",
  "micMute",
  "keystrokeHighlight",
  "presenter",
  "colorPicker",
  "systemStats",
  "emoji",
  "homebrew",
  "calendar",
  "jev",
  "system",
  "timeLapse",
  "cleaner",
  "appMaintenance",
  "blitztree",
  "plugins",
  "notchShelf",
  "clipboard",
  "music",
  "docs",
  "latex",
  "companion",
  "terminal",
  "studio",
  "usage",
  "bifrost",
  "lidAwake",
  "attention",
  "machines",
  "downloads",
  "seoAudit",
  "virtualCamera",
  "codeStats",
  "herdr",
  "quinjet",
  "database",
];

export function assertValidationContext(validationSHA, environment) {
  if (
    typeof validationSHA !== "string" ||
    !/^[a-f0-9]{40}$/.test(validationSHA) ||
    environment.EXTENSION_VALIDATION_SHA !== validationSHA ||
    environment.GITHUB_SHA !== validationSHA ||
    environment.GITHUB_EVENT_NAME !== "workflow_dispatch" ||
    environment.EXTENSION_PUBLISH !== "false" ||
    environment.GITHUB_REPOSITORY !== "pulkitxm/edith" ||
    !["65671483", "320458784"].includes(environment.GITHUB_ACTOR_ID) ||
    !["refs/heads/main", "refs/heads/feat/extension-marketplace"].includes(
      environment.GITHUB_REF,
    )
  )
    throw new Error(
      "All-extension validation requires an authorized nonpublishing exact-source dispatch",
    );
}

export function assertValidationSource(root, validationSHA, environment) {
  assertValidationContext(validationSHA, environment);
  const git = (arguments_) =>
    execFileSync("git", arguments_, { cwd: root, encoding: "utf8" });
  if (
    git(["rev-parse", "--verify", "HEAD^{commit}"]).trim() !== validationSHA ||
    git(["status", "--porcelain=v1", "--untracked-files=all"]) !== ""
  )
    throw new Error(
      "All-extension validation requires the exact clean source HEAD",
    );
}

export function assertValidationExtensions(entries) {
  const ids = entries.map(({ id }) => id);
  if (
    ids.length !== validationExtensionIDs.length ||
    new Set(ids).size !== ids.length ||
    ids.some((id) => !validationExtensionIDs.includes(id))
  )
    throw new Error(
      "All-extension validation requires the exact 39 manifest IDs without duplicates",
    );
}

export async function planValidationExtensions(
  root,
  definitions,
  validationSHA,
  environment,
) {
  assertValidationSource(root, validationSHA, environment);
  assertValidationExtensions(definitions);
  planExtensionBuilds(definitions, []);
  const include = await planUnpublishedExtensions(root, definitions, []);
  assertValidationExtensions(include);
  assertValidationSource(root, validationSHA, environment);
  return { include, mode: "validation", sourceSHA: validationSHA };
}

if (import.meta.main) {
  const validation = ["--validate-all", "--check-validation-source"].includes(
    process.argv[2],
  );
  if (validation || process.env.EXTENSION_VALIDATION_SHA) {
    if (!validation || process.argv.length !== 4)
      throw new Error(
        "Validation input requires explicit exact-source validation arguments",
      );
    const root = process.cwd();
    const validationSHA = process.argv[3];
    assertValidationSource(root, validationSHA, process.env);
    if (process.argv[2] === "--validate-all") {
      const definitions = JSON.parse(
        await readFile("Extensions/manifest.json", "utf8"),
      );
      const plan = await planValidationExtensions(
        root,
        definitions,
        validationSHA,
        process.env,
      );
      process.stdout.write(`${JSON.stringify(plan)}\n`);
    }
  } else {
    const pullRequest = process.argv[2] === "--pull-request-base";
    if (
      pullRequest &&
      (process.env.GITHUB_EVENT_NAME !== "pull_request" ||
        process.argv.length !== 4)
    )
      throw new Error(
        "Pull request planning requires the exact pull request event base",
      );
    await writeHostABI();
    const root = process.cwd();
    const definitions = shippingDefinitions(
      JSON.parse(await readFile("Extensions/manifest.json", "utf8")),
    );
    let include;
    if (pullRequest) {
      include = await planPullRequestExtensions(
        root,
        definitions,
        process.argv[3],
      );
    } else {
      const publishedFile = process.argv[2];
      if (!publishedFile)
        throw new Error("Supply the verified published catalog");
      const published = JSON.parse(await readFile(publishedFile, "utf8"));
      include = await planUnpublishedExtensions(
        root,
        definitions,
        published.packages,
      );
    }
    process.stdout.write(`${JSON.stringify({ include })}\n`);
  }
}
