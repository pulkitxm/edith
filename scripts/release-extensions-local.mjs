import { execFileSync } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const catalogPublicKey = "ZmEn7Nvq56SkxwSOm7ey0kyBdFERSQgDywlDCuvxZgk=";

export async function releaseExtensionsLocally({
  root = process.cwd(),
  environment = process.env,
  execute = execFileSync,
  log = (message) => process.stdout.write(`==> ${message}\n`),
} = {}) {
  for (const key of [
    "EXTENSION_CATALOG_PRIVATE_KEY",
    "EDITH_SIGN_IDENTITY",
    "NOTARY_KEY_ID",
    "NOTARY_ISSUER_ID",
    "NOTARY_KEY",
  ])
    if (!environment[key]) throw new Error(`${key} is required`);
  if (!environment.EDITH_SIGN_IDENTITY.startsWith("Developer ID Application: "))
    throw new Error("A Developer ID Application signing identity is required");
  if (
    environment.EXTENSION_FORCE_ALL !== undefined &&
    !["true", "false"].includes(environment.EXTENSION_FORCE_ALL)
  )
    throw new Error("EXTENSION_FORCE_ALL must be true or false");
  const repository = environment.GITHUB_REPOSITORY ?? "pulkitxm/edith";
  const directory = resolve(root, "dist/extensions-local");
  const settings = {
    ...environment,
    GITHUB_REPOSITORY: repository,
    GITHUB_REF: "refs/heads/main",
    EXTENSION_OUTPUT: directory,
    EXTENSION_CATALOG_PUBLIC_KEY:
      environment.EXTENSION_CATALOG_PUBLIC_KEY ?? catalogPublicKey,
    EXTENSION_SWIFT_JOBS: environment.EXTENSION_SWIFT_JOBS ?? "2",
    EXTENSION_SIGN_IDENTITY: environment.EDITH_SIGN_IDENTITY,
  };
  const run = (file, args, options = {}) =>
    execute(file, args, {
      cwd: root,
      env: settings,
      encoding: "utf8",
      maxBuffer: 256 * 1024 * 1024,
      stdio: ["ignore", "pipe", "inherit"],
      ...options,
    });
  const target =
    environment.BUILT_SHA ?? run("git", ["rev-parse", "HEAD"]).trim();
  if (!/^[a-f0-9]{40}$/.test(target)) throw new Error("Invalid release source");
  settings.BUILT_SHA = target;
  settings.GITHUB_SHA = target;
  const verifySource = () => {
    const head = run("git", ["rev-parse", "HEAD"]).trim();
    const remote = run("git", [
      "ls-remote",
      "--exit-code",
      "origin",
      "refs/heads/main",
    ])
      .trim()
      .split(/\s+/);
    if (
      head !== target ||
      remote[0] !== target ||
      remote[1] !== "refs/heads/main"
    )
      throw new Error("Extension publication superseded: main changed");
    if (run("git", ["status", "--porcelain"]).trim())
      throw new Error("Extension release requires a clean frozen source");
  };
  verifySource();
  run("swift", [
    "scripts/extension-catalog-sign.swift",
    "check-key",
    settings.EXTENSION_CATALOG_PUBLIC_KEY,
  ]);
  await mkdir(directory, { recursive: true });
  log("reading the verified published catalog");
  const previous = resolve(directory, "previous.json");
  run("bun", ["scripts/extension-publish.mjs", "--read-catalog", previous]);
  const plan = JSON.parse(
    run("bun", ["scripts/extension-release-plan.mjs", previous]),
  );
  if (!Array.isArray(plan.include))
    throw new Error("Invalid extension release plan");
  await writeFile(resolve(directory, "plan.json"), JSON.stringify(plan));
  const state = JSON.parse(
    await readFile(resolve(directory, "previous-state.json"), "utf8"),
  );
  verifySource();
  if (plan.include.length === 0 && state.draft !== true) {
    log("every extension is already published for this source");
    return { built: 0, resumed: false };
  }
  if (plan.include.length > 0) {
    log("building the signed containing host");
    run("make", ["host"], { stdio: "inherit" });
    const host = resolve(root, "local/extension-release-host/Edith.app");
    run(
      "python3",
      [
        "scripts/package-shipping-host.py",
        "local/minimal-host/Edith.app",
        host,
        "--identity",
        environment.EDITH_SIGN_IDENTITY,
        "--release",
      ],
      { stdio: "inherit" },
    );
    const definitions = JSON.parse(
      await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
    );
    if (
      plan.include.some(
        ({ id }) =>
          definitions.find((entry) => entry.id === id)?.nativeProduct ===
          "GhosttyTerminal",
      )
    ) {
      log("building the terminal library");
      run("make", ["ghostty-extension"], { stdio: "inherit" });
      run("bun", ["scripts/extension-ghostty-native.mjs", "--check"], {
        stdio: "inherit",
      });
    }
    for (const entry of plan.include) {
      verifySource();
      log(`building ${entry.id} ${entry.version}`);
      const output = run(
        "bun",
        ["scripts/build-extension-package.mjs", entry.id],
        {
          env: {
            ...settings,
            EXTENSION_VERSION: entry.version,
            EXTENSION_CONTAINING_HOST_APP: host,
          },
        },
      );
      const result = JSON.parse(output.trimEnd().split("\n").at(-1));
      if (result.id !== entry.id || result.tag !== entry.tag)
        throw new Error("Built extension differs from its frozen release plan");
    }
    verifySource();
    log("submitting every extension for notarization");
    const submissions = resolve(directory, "notarization.json");
    await writeFile(submissions, "{}");
    run(
      "bash",
      [
        "scripts/notary-submit.sh",
        submissions,
        ...plan.include.map(({ id }) => resolve(directory, `${id}.zip`)),
      ],
      { stdio: "inherit" },
    );
    run("python3", ["scripts/notary_wait.py", submissions], {
      stdio: "inherit",
    });
  }
  verifySource();
  log("publishing immutable packages and the verified catalog");
  run("bun", ["scripts/extension-publish.mjs"], { stdio: "inherit" });
  return { built: plan.include.length, resumed: state.draft === true };
}

if (import.meta.main) {
  if (process.argv.length !== 2)
    throw new Error("Unexpected local extension release arguments");
  process.stdout.write(`${JSON.stringify(await releaseExtensionsLocally())}\n`);
}
