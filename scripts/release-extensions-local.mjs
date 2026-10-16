import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const repository = process.env.GITHUB_REPOSITORY ?? "pulkitxm/edith";
const catalogTag = "extension-catalog-v1";
const publicKey =
  process.env.EXTENSION_CATALOG_PUBLIC_KEY ??
  "ZmEn7Nvq56SkxwSOm7ey0kyBdFERSQgDywlDCuvxZgk=";
const jobs = Number(process.env.EXTENSION_LOCAL_JOBS ?? 3);
const work = resolve("dist/extensions-local");
const catalogKeys = [
  "architecture",
  "dependencies",
  "downloadBytes",
  "downloadURL",
  "hostABI",
  "id",
  "installedBytes",
  "minimumSystemVersion",
  "sha256",
  "sourceFingerprint",
  "version",
];

const environment = {
  ...process.env,
  GITHUB_REPOSITORY: repository,
  EXTENSION_CATALOG_PUBLIC_KEY: publicKey,
};

function run(file, args, options = {}) {
  return execFileSync(file, args, {
    env: environment,
    encoding: "utf8",
    maxBuffer: 256 * 1024 * 1024,
    stdio: ["ignore", "pipe", "inherit"],
    ...options,
  });
}

function step(message) {
  process.stdout.write(`==> ${message}\n`);
}

function githubJSON(path) {
  return JSON.parse(run("gh", ["api", path]));
}

function releaseByTag(tag) {
  try {
    return githubJSON(
      `repos/${repository}/releases/tags/${encodeURIComponent(tag)}`,
    );
  } catch {
    return undefined;
  }
}

function pukbot(args) {
  const output = run("pukbot", [...args, "--repo", repository, "--json"], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const value = JSON.parse(output);
  if (value.ok === false)
    throw new Error(`pukbot ${args.slice(0, 2).join(" ")} failed: ${output}`);
  return value;
}

function uploadAsset(releaseID, file, name) {
  run(
    "gh",
    [
      "api",
      "--method",
      "POST",
      "-H",
      "Content-Type: application/octet-stream",
      `https://uploads.github.com/repos/${repository}/releases/${releaseID}/assets?name=${encodeURIComponent(name)}`,
      "--input",
      file,
    ],
    { stdio: ["ignore", "ignore", "inherit"] },
  );
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function pool(items, limit, task) {
  const results = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const index = next++;
      results[index] = await task(items[index], index);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, worker),
  );
  return results;
}

function buildPackage(entry, hostApp) {
  return new Promise((done, fail) => {
    const child = spawn(
      "bun",
      ["scripts/build-extension-package.mjs", entry.id],
      {
        env: {
          ...environment,
          EXTENSION_ID: entry.id,
          EXTENSION_VERSION: entry.version,
          EXTENSION_UI_CARRIER_TOOLS: "local/extension-tools",
          EXTENSION_SWIFT_JOBS: process.env.EXTENSION_SWIFT_JOBS ?? "3",
          EXTENSION_CONTAINING_HOST_APP: hostApp,
          EXTENSION_SIGN_IDENTITY: process.env.EDITH_SIGN_IDENTITY,
        },
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    let output = "";
    let errors = "";
    child.stdout.on("data", (chunk) => {
      output += chunk;
    });
    child.stderr.on("data", (chunk) => {
      errors += chunk;
    });
    child.on("close", (code) => {
      if (code !== 0) {
        fail(
          new Error(
            `${entry.id} package build failed (${code}):\n${errors.slice(-4000)}`,
          ),
        );
        return;
      }
      const lines = output.trimEnd().split("\n");
      done(JSON.parse(lines.at(-1)));
    });
  });
}

function catalogRecord(result) {
  const record = Object.fromEntries(
    catalogKeys.map((key) => [key, result[key]]),
  );
  for (const key of catalogKeys)
    if (record[key] === undefined)
      throw new Error(`${result.id} package record is missing ${key}`);
  return record;
}

function compareVersions(left, right) {
  return left.localeCompare(right, undefined, { numeric: true });
}

if (!process.env.EXTENSION_CATALOG_PRIVATE_KEY)
  throw new Error("EXTENSION_CATALOG_PRIVATE_KEY is required (see AGENTS.md)");
if (!process.env.EDITH_SIGN_IDENTITY)
  throw new Error("EDITH_SIGN_IDENTITY is required (see AGENTS.md)");
run("swift", ["scripts/extension-catalog-sign.swift", "check-key", publicKey]);
await mkdir(work, { recursive: true });
const target = run("git", ["rev-parse", "HEAD"]).trim();

step("reading the published catalog");
run("node", [
  "scripts/extension-publish.mjs",
  "--read-catalog",
  resolve(work, "previous.json"),
]);
const previous = JSON.parse(
  await readFile(resolve(work, "previous.json"), "utf8"),
);
const plan = JSON.parse(
  run("bun", [
    "scripts/extension-release-plan.mjs",
    resolve(work, "previous.json"),
  ]),
);
await writeFile(resolve(work, "plan.json"), JSON.stringify(plan, null, 2));
if (plan.include.length === 0) {
  step("every extension is already published for this source");
  process.exit(0);
}
step(
  `publishing ${plan.include.length} extensions: ${plan.include.map(({ id }) => id).join(", ")}`,
);

step("building the host the extensions are packaged against");
await rm("local/extension-tools", { recursive: true, force: true });
await rm("local/extension-release-host", { recursive: true, force: true });
run("make", ["host"], { stdio: ["ignore", "inherit", "inherit"] });
const hostProducts = run("swift", [
  "build",
  "--package-path",
  "Packages/EdithHost",
  "--build-system",
  "native",
  "--show-bin-path",
]).trim();
run(
  "swift",
  [
    "build",
    "--package-path",
    "Packages/EdithHost",
    "--build-system",
    "native",
    "--product",
    "HostLifecycleHarness",
  ],
  { stdio: ["ignore", "inherit", "inherit"] },
);
run(
  "swift",
  [
    "build",
    "--package-path",
    "Packages/ExtensionMarketplace",
    "--build-system",
    "native",
    "--product",
    "MarketplaceHarness",
  ],
  { stdio: ["ignore", "inherit", "inherit"] },
);
run(
  "python3",
  [
    "scripts/package_extension_lifecycle_tools.py",
    "--host",
    "local/minimal-host/Edith.app",
    "--host-products",
    hostProducts,
    "--marketplace-products",
    run("swift", [
      "build",
      "--package-path",
      "Packages/ExtensionMarketplace",
      "--build-system",
      "native",
      "--show-bin-path",
    ]).trim(),
    "--carrier-products",
    run("swift", [
      "build",
      "--package-path",
      "Packages/EdithHost",
      "--build-system",
      "native",
      "--configuration",
      "release",
      "--show-bin-path",
    ]).trim(),
    "--output",
    "local/extension-tools",
  ],
  { stdio: ["ignore", "inherit", "inherit"] },
);
run(
  "python3",
  [
    "scripts/package-shipping-host.py",
    "local/minimal-host/Edith.app",
    "local/extension-release-host/Edith.app",
    "--identity",
    process.env.EDITH_SIGN_IDENTITY,
    "--release",
  ],
  { stdio: ["ignore", "inherit", "inherit"] },
);

const manifest = JSON.parse(await readFile("Extensions/manifest.json", "utf8"));
const usesGhostty = plan.include.some(
  ({ id }) =>
    manifest.find((definition) => definition.id === id)?.nativeProduct ===
    "GhosttyTerminal",
);
if (usesGhostty) {
  step("building the terminal library");
  run("sh", ["-c", "command -v zig"], {
    stdio: ["ignore", "ignore", "inherit"],
  });
  run("make", ["ghostty-extension"], {
    stdio: ["ignore", "inherit", "inherit"],
  });
  run("node", ["scripts/extension-ghostty-native.mjs", "--check"], {
    stdio: ["ignore", "inherit", "inherit"],
  });
}

step(`building ${plan.include.length} packages, ${jobs} at a time`);
const built = await pool(plan.include, jobs, async (entry) => {
  const result = await buildPackage(
    entry,
    "local/extension-release-host/Edith.app",
  );
  if (result.tag !== entry.tag)
    throw new Error(`${entry.id} built ${result.tag}, planned ${entry.tag}`);
  process.stdout.write(`    built ${entry.id} ${entry.version}\n`);
  return result;
});

step("publishing package releases");
await pool(built, 6, async (result) => {
  const archive = resolve("dist/extensions", `${result.id}.zip`);
  const bytes = await readFile(archive);
  if (sha256(bytes) !== result.sha256 || bytes.length !== result.downloadBytes)
    throw new Error(`${result.id} archive does not match its record`);
  let release = releaseByTag(result.tag);
  if (!release) {
    pukbot([
      "release",
      "create",
      result.tag,
      "--target",
      target,
      "--name",
      `${result.id} ${result.version}`,
      "--body",
      `Extension package ${result.id} ${result.version}.`,
    ]);
    release = releaseByTag(result.tag);
  }
  if (!release || release.draft)
    throw new Error(`${result.tag} release is missing or still a draft`);
  const existing = release.assets.find(
    ({ name }) => name === `${result.id}.zip`,
  );
  if (existing && existing.size !== result.downloadBytes)
    throw new Error(`${result.tag} already has a different ${result.id}.zip`);
  if (!existing) uploadAsset(release.id, archive, `${result.id}.zip`);
  process.stdout.write(`    published ${result.tag}\n`);
});

step("signing the new catalog");
const records = built.map(catalogRecord);
const packages = [...previous.packages, ...records].sort(
  (left, right) =>
    left.id.localeCompare(right.id) ||
    compareVersions(left.version, right.version),
);
const seen = new Set();
for (const entry of packages) {
  const key = `${entry.id}@${entry.version}`;
  if (seen.has(key)) throw new Error(`Duplicate catalog package ${key}`);
  seen.add(key);
}
const revision = Math.max(previous.revision + 1, Date.now());
const payloadPath = resolve(work, `catalog-${revision}.payload.json`);
const envelopePath = resolve(work, `catalog-${revision}.json`);
await writeFile(
  payloadPath,
  JSON.stringify({ schemaVersion: 1, revision, packages }),
);
run("swift", [
  "scripts/extension-catalog-sign.swift",
  "sign",
  payloadPath,
  envelopePath,
]);
run("swift", [
  "scripts/extension-catalog-sign.swift",
  "verify",
  envelopePath,
  resolve(work, "verified.payload.json"),
  publicKey,
]);
const envelope = await readFile(envelopePath);
const pointer = {
  schemaVersion: 1,
  revision,
  assetName: `catalog-${revision}.json`,
  bytes: envelope.length,
  sha256: sha256(envelope),
};

step(`publishing catalog revision ${revision}`);
const catalogRelease = releaseByTag(catalogTag);
if (!catalogRelease || catalogRelease.draft)
  throw new Error(`${catalogTag} release is missing or a draft`);
uploadAsset(catalogRelease.id, envelopePath, pointer.assetName);
const staged = releaseByTag(catalogTag).assets.filter(
  ({ name }) => name === pointer.assetName,
);
if (staged.length !== 1 || staged[0].size !== pointer.bytes)
  throw new Error("The catalog upload did not land intact");
pukbot([
  "release",
  "edit",
  String(catalogRelease.id),
  "--tag",
  catalogTag,
  "--body",
  JSON.stringify(pointer),
]);

step("verifying the published catalog");
run("node", [
  "scripts/extension-publish.mjs",
  "--read-catalog",
  resolve(work, "published.json"),
]);
const published = JSON.parse(
  await readFile(resolve(work, "published.json"), "utf8"),
);
if (published.revision !== revision)
  throw new Error(
    `Published catalog is revision ${published.revision}, expected ${revision}`,
  );
step(`published ${built.length} extensions in catalog revision ${revision}`);
