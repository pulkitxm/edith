import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { relative, resolve } from "node:path";
import { supportSourceInputs } from "./build-extension-support.mjs";
import { ghosttyNativeInputs } from "./extension-ghostty-native.mjs";
import { writeHostABI } from "./extension-host-abi.mjs";

export const workerRuntimeInputs = [
  "Packages/EdithHost/Package.swift",
  "Packages/EdithHost/Package.resolved",
  "scripts/build-minimal-host.mjs",
  "scripts/package-shipping-host.py",
  "Packages/EdithHost/Sources/HostBootstrap",
  "Packages/EdithHost/Sources/EdithHost/HostEntry.swift",
  "Packages/EdithHost/Sources/EdithHost/HostWorkerApplication.swift",
  "Packages/EdithHost/Sources/EdithHost/HostWorkerControl.swift",
  "Packages/EdithHost/Sources/EdithHost/HostNativeTask.swift",
  "Packages/EdithHost/Sources/EdithHost/HostRemoteApplication.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostWorkerProtocol.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostAmbientPolicyCoordinator.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostCoreBackgroundPolicy.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostWorkerProcessGroups.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostWorker.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostContract.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostExtensionSessions.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostSurfaces.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostRemoteProtocol.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostRemoteAuthentication.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostRemoteEndpoint.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostRemoteChannel.swift",
  "Packages/EdithHost/Sources/EdithHostCore/HostRemoteConfiguration.swift",
  "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace",
];

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
      changes.some((path) =>
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
    changes.filter((path) => path !== "Extensions/manifest.json"),
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
  git(["merge-base", "--is-ancestor", baseSHA, "HEAD"]);
  const tree = git([
    "ls-tree",
    "-z",
    baseSHA,
    "--",
    "Extensions/manifest.json",
  ]);
  let priorDefinitions = null;
  if (tree) {
    if (!/^100644 blob [a-f0-9]{40}\tExtensions\/manifest\.json\0$/.test(tree))
      throw new Error("Invalid base extension manifest tree");
    priorDefinitions = JSON.parse(
      git(["show", `${baseSHA}:Extensions/manifest.json`]),
    );
    if (!Array.isArray(priorDefinitions))
      throw new Error("Invalid base extension manifest");
  }
  const changes = git([
    "diff",
    "--name-only",
    "-z",
    "--no-renames",
    baseSHA,
    "HEAD",
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
      if (
        [
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
        ].includes(entry.name)
      )
        continue;
      if (
        [
          "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift",
          "Extensions/database/DatabaseEngine/MCPTests",
        ].includes(`${path}/${entry.name}`)
      )
        continue;
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

if (import.meta.main) {
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
  const definitions = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
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
