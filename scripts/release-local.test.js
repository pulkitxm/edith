import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const syntheticIdentity =
  "Developer ID Application: Synthetic Publisher (ABCDEF1234)";
const plist = (version, build) =>
  `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>${version}</string><key>CFBundleVersion</key><string>${build}</string></dict></plist>`;

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "release-shell-"));
  for (const dir of ["scripts", "Resources", "Casks", "bin"])
    mkdirSync(join(root, dir));
  copyFileSync(
    resolve("scripts/release-local.sh"),
    join(root, "scripts/release-local.sh"),
  );
  for (const name of ["Info.plist", "HelperInfo.plist"])
    writeFileSync(join(root, "Resources", name), plist("0.0.375", "375"));
  writeFileSync(
    join(root, "Casks/edith.rb"),
    `  version "0.0.375"\n  sha256 "${"a".repeat(64)}"\n`,
  );
  const envFile = join(root, "synthetic-signing.env");
  writeFileSync(
    envFile,
    [
      "MACOS_CERT_P12_BASE64=c3ludGhldGlj",
      "MACOS_CERT_PASSWORD=synthetic",
      "SPARKLE_PRIVATE_KEY=synthetic",
      `EDITH_SIGN_IDENTITY='${syntheticIdentity}'`,
      "EXTENSION_CATALOG_PRIVATE_KEY=synthetic",
      "NOTARY_KEY_ID=synthetic",
      "NOTARY_ISSUER_ID=synthetic",
      "NOTARY_KEY=synthetic",
      "EXTENSION_FORCE_ALL=false",
    ].join("\n"),
  );
  const log = join(root, "calls.jsonl");
  const mock = `#!${process.execPath}
import { appendFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
const name = basename(process.argv[1]);
const command = name === "build-fixture" ? "build.sh" : name;
const args = process.argv.slice(2);
const root = process.env.MOCK_ROOT;
appendFileSync(process.env.MOCK_LOG, JSON.stringify({ command, args, sha: process.env.GITHUB_SHA, ref: process.env.GITHUB_REF, force: process.env.EXTENSION_FORCE_ALL }) + "\\n");
if (command === "git") {
  if (args[0] === "status") process.stdout.write(process.env.MOCK_DIRTY ?? "");
  if (args[0] === "branch") process.stdout.write(process.env.MOCK_BRANCH ?? "");
  if (args[0] === "rev-parse") process.stdout.write((args[1] === "HEAD" && existsSync(join(root, ".published-state")) ? "b" : "a").repeat(40) + "\\n");
} else if (command === "security") {
  if (args[0] === "list-keychains" && !args.includes("-s")) process.stdout.write('    "/synthetic/login.keychain-db"\\n    "/synthetic/Work Keys.keychain-db"\\n');
  if (args[0] === "find-identity") process.stdout.write(${JSON.stringify(syntheticIdentity)} + "\\n");
} else if (command === "find") {
  process.stdout.write(join(root, args[0].startsWith("/Applications") ? "intermediate.cer" : "generate_appcast") + "\\n");
} else if (command === "bun") {
  if (args[0] === "scripts/release-extensions-local.mjs" && process.env.MOCK_EXTENSION_FAILURE) process.exit(23);
} else if (command === "build.sh") {
  mkdirSync("dist/Edith.app/Contents", { recursive: true });
  writeFileSync("dist/Edith.app/Contents/Info.plist", (${plist.toString()})(process.env.RELEASE_VERSION, process.env.RELEASE_BUILD));
  mkdirSync("local/minimal-host", { recursive: true });
  writeFileSync("local/minimal-host/build-metadata.json", "{}");
} else if (command === "python3") {
  if (args[0] === "scripts/package-host-dmg.py") writeFileSync(args[2], "synthetic dmg");
  if (args[0] === "scripts/host_release_proof.py") {
    mkdirSync(args[4], { recursive: true });
    for (const name of ["host-release-proof.json", "build-metadata.json", "toolchain-provenance.json"]) writeFileSync(join(args[4], name), "{}");
  }
} else if (command === "generate_appcast") {
  writeFileSync(join(args.at(-1), "appcast.xml"), '<item sparkle:edSignature="synthetic" url="https://github.com/pulkitxm/edith/releases/download/' + process.env.RELEASE_TAG + '/Edith.dmg"/>');
} else if (command === "node" && args.includes("--preflight") && process.env.MOCK_PREFLIGHT_FAILURE) process.exit(31);
`;
  for (const name of [
    "git",
    "security",
    "find",
    "make",
    "python3",
    "node",
    "bun",
    "codesign",
    "spctl",
    "pukbot",
  ]) {
    writeFileSync(join(root, "bin", name), mock);
    chmodSync(join(root, "bin", name), 0o755);
  }
  for (const name of ["bin/build-fixture", "generate_appcast"]) {
    writeFileSync(join(root, name), mock);
    chmodSync(join(root, name), 0o755);
  }
  writeFileSync(
    join(root, "build.sh"),
    `#!/bin/bash\nexec "${process.execPath}" "$MOCK_ROOT/bin/build-fixture" "$@"\n`,
  );
  chmodSync(join(root, "build.sh"), 0o755);
  const scripts = {
    "run-current-release-build.sh":
      'printf \'%s\\n\' \'{"command":"guard","args":[]}\' >> "$MOCK_LOG"\nexec "$@"',
    "resolve-release-version.sh":
      "printf 'tag=v0.0.376\\nversion=0.0.376\\nbuild=376\\n' > \"$GITHUB_OUTPUT\"",
    "notarize.sh":
      'printf \'%s\\n\' \'{"command":"notarize","args":[]}\' >> "$MOCK_LOG"',
    "publish-release-state.sh":
      'printf \'%s\\n\' \'{"command":"release-state","args":["cut"]}\' >> "$MOCK_LOG"\ntouch .published-state',
  };
  for (const [name, contents] of Object.entries(scripts)) {
    writeFileSync(
      join(root, "scripts", name),
      `#!/bin/bash\nset -euo pipefail\n${contents}\n`,
    );
    chmodSync(join(root, "scripts", name), 0o755);
  }
  return {
    run(args = [], environment = {}) {
      return spawnSync(
        "/bin/bash",
        [join(root, "scripts/release-local.sh"), ...args],
        {
          cwd: root,
          encoding: "utf8",
          timeout: 15_000,
          env: {
            ...process.env,
            PATH: `${join(root, "bin")}:${process.env.PATH}`,
            MOCK_ROOT: root,
            MOCK_LOG: log,
            EDITH_RELEASE_ENV_FILE: envFile,
            ...environment,
          },
        },
      );
    },
    calls() {
      return readFileSync(log, "utf8")
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line));
    },
    clean() {
      rmSync(root, { recursive: true, force: true });
    },
  };
}

test("a clean detached release imports its isolated keychain before extensions and keeps source frozen", () => {
  const f = fixture();
  try {
    const result = f.run(["--force-all"]);
    expect(result.stderr).toBe("");
    expect(result.status).toBe(0);
    const calls = f.calls();
    const identity = calls.findIndex(
      ({ command, args }) =>
        command === "security" && args[0] === "find-identity",
    );
    const extensions = calls.findIndex(({ command }) => command === "bun");
    expect(identity).toBeLessThan(extensions);
    expect(calls[extensions].sha).toBe("a".repeat(40));
    expect(calls[extensions].ref).toBe("refs/heads/main");
    expect(calls[extensions].force).toBe("true");
    const preflight = calls.findIndex(
      ({ command, args }) => command === "node" && args.includes("--preflight"),
    );
    const commit = calls.findIndex(
      ({ command }) => command === "release-state",
    );
    expect(commit).toBeGreaterThan(preflight);
    expect(
      calls.some(
        ({ command, args }) => command === "git" && args[0] === "switch",
      ),
    ).toBe(false);
    expect(calls.some(({ args }) => args.includes("--install"))).toBe(false);
    const restored = calls
      .filter(
        ({ command, args }) =>
          command === "security" &&
          args[0] === "list-keychains" &&
          args.includes("-s"),
      )
      .at(-1);
    expect(restored.args.slice(4)).toEqual([
      "/synthetic/login.keychain-db",
      "/synthetic/Work Keys.keychain-db",
    ]);
  } finally {
    f.clean();
  }
});

test("extension failure restores the keychain and stops before the host build or release commit", () => {
  const f = fixture();
  try {
    const result = f.run([], { MOCK_EXTENSION_FAILURE: "1" });
    expect(result.status).toBe(23);
    const calls = f.calls();
    expect(
      calls.some(({ command }) =>
        ["build.sh", "release-state"].includes(command),
      ),
    ).toBe(false);
    expect(
      calls.some(
        ({ command, args }) =>
          command === "security" && args[0] === "delete-keychain",
      ),
    ).toBe(true);
    expect(
      calls.some(
        ({ command, args }) => command === "git" && args[0] === "checkout",
      ),
    ).toBe(true);
  } finally {
    f.clean();
  }
});

test("host asset preflight failure never cuts a release commit", () => {
  const f = fixture();
  try {
    const result = f.run([], { MOCK_PREFLIGHT_FAILURE: "1" });
    expect(result.status).toBe(31);
    expect(f.calls().some(({ command }) => command === "release-state")).toBe(
      false,
    );
  } finally {
    f.clean();
  }
});

test("dirty sources and non-main branches are rejected before importing credentials", () => {
  for (const environment of [
    { MOCK_DIRTY: " M source.swift\n" },
    { MOCK_BRANCH: "feature" },
  ]) {
    const f = fixture();
    try {
      expect(f.run([], environment).status).toBe(1);
      expect(f.calls().some(({ command }) => command === "security")).toBe(
        false,
      );
    } finally {
      f.clean();
    }
  }
});

test("a host dry run performs no extension or release publication", () => {
  const f = fixture();
  try {
    const result = f.run(["--dry-run"], { MOCK_BRANCH: "feature" });
    expect(result.status).toBe(0);
    const calls = f.calls();
    expect(
      calls.some(
        ({ command }) => command === "bun" || command === "release-state",
      ),
    ).toBe(false);
    expect(
      calls.some(
        ({ command, args }) =>
          command === "node" && args[0] === "scripts/publish-host-release.mjs",
      ),
    ).toBe(false);
  } finally {
    f.clean();
  }
});
