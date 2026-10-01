import { describe, expect, test } from "bun:test";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "edith-install-signing-"));
  const checkout = join(root, "worktree");
  const primary = join(root, "primary checkout");
  const bin = join(root, "bin");
  const developer = join(root, "developer");
  const log = join(root, "security.log");
  for (const directory of [
    checkout,
    primary,
    bin,
    join(developer, "usr/bin"),
  ]) {
    mkdirSync(directory, { recursive: true });
  }
  mkdirSync(join(checkout, "scripts"));
  copyFileSync("build.sh", join(checkout, "build.sh"));
  copyFileSync(
    "scripts/signing-keychain.sh",
    join(checkout, "scripts/signing-keychain.sh"),
  );
  const executable = (path, body) =>
    writeFileSync(path, `#!/usr/bin/env bash\n${body}\n`, { mode: 0o755 });
  executable(
    join(bin, "git"),
    'printf "worktree %s\\n" "$EDITH_FIXTURE_PRIMARY"',
  );
  executable(join(bin, "python3"), "exit 0");
  executable(join(bin, "codesign"), "exit 0");
  executable(join(bin, "find"), "exit 0");
  executable(join(bin, "base64"), "cat >/dev/null; printf fixture");
  executable(
    join(bin, "security"),
    `printf '%s\\n' "$1" >> "$EDITH_FIXTURE_LOG"
case "$1" in
  find-identity) printf '1) fixture "%s"\\n' "$EDITH_FIXTURE_AVAILABLE_IDENTITY" ;;
  find-certificate) exit 1 ;;
  list-keychains) printf '"/fixture/login.keychain-db"\\n' ;;
esac`,
  );
  executable(
    join(bin, "xcodebuild"),
    'printf "build reached: %s\\n" "$*"; exit 73',
  );
  copyFileSync(join(bin, "xcodebuild"), join(developer, "usr/bin/xcodebuild"));
  executable(join(checkout, "scripts/dev-slots.sh"), "echo fixture");
  return {
    checkout,
    primary,
    log,
    writeConfig(directory, body) {
      writeFileSync(join(directory, ".env"), body);
    },
    run(options = ["--release", "--install"], available = "") {
      const result = Bun.spawnSync(["bash", "build.sh", ...options], {
        cwd: checkout,
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH}`,
          DEVELOPER_DIR: developer,
          EDITH_RELEASE: "0",
          EDITH_SIGN_IDENTITY: "",
          EDITH_RELEASE_ALLOW_DEV_SIGNING: "0",
          MACOS_CERT_P12_BASE64: "Zml4dHVyZQ==",
          MACOS_CERT_PASSWORD: "fixture",
          EDITH_FIXTURE_PRIMARY: primary,
          EDITH_FIXTURE_LOG: log,
          EDITH_FIXTURE_AVAILABLE_IDENTITY: available,
        },
        stdout: "pipe",
        stderr: "pipe",
        timeout: 10000,
      });
      return {
        code: result.exitCode,
        output: new TextDecoder().decode(result.stdout),
        error: new TextDecoder().decode(result.stderr),
      };
    },
    cleanup() {
      rmSync(root, { recursive: true, force: true });
    },
  };
}

describe("local install signing configuration", () => {
  const development = "Apple Development: Fixture (FIXTURETEAM)";
  const developerID = "Developer ID Application: Fixture (FIXTURETEAM)";

  test("loads the primary checkout configuration from a worktree", () => {
    const value = fixture();
    try {
      value.writeConfig(
        value.primary,
        `EDITH_SIGN_IDENTITY='${development}'\nEDITH_RELEASE_ALLOW_DEV_SIGNING=1\n`,
      );
      const result = value.run(undefined, development);
      expect(result.code).toBe(73);
      expect(result.output).toContain(`CODE_SIGN_IDENTITY=${development}`);
      expect(readFileSync(value.log, "utf8")).not.toContain("create-keychain");
    } finally {
      value.cleanup();
    }
  });

  test("prefers the selected worktree configuration", () => {
    const value = fixture();
    try {
      value.writeConfig(
        value.primary,
        `EDITH_SIGN_IDENTITY='${development}'\n`,
      );
      value.writeConfig(
        value.checkout,
        `EDITH_SIGN_IDENTITY='${developerID}'\n`,
      );
      const result = value.run(undefined, developerID);
      expect(result.code).toBe(73);
      expect(result.output).toContain(`CODE_SIGN_IDENTITY=${developerID}`);
    } finally {
      value.cleanup();
    }
  });

  test("keeps development signing opt-in mandatory", () => {
    const value = fixture();
    try {
      value.writeConfig(
        value.checkout,
        `EDITH_SIGN_IDENTITY='${development}'\n`,
      );
      const result = value.run(undefined, development);
      expect(result.code).toBe(1);
      expect(result.error).toContain(
        "Developer ID Application signing identity is required",
      );
      expect(result.output).not.toContain("build reached");
    } finally {
      value.cleanup();
    }
  });

  test("still requires Developer ID without local configuration", () => {
    const value = fixture();
    try {
      const result = value.run(undefined, development);
      expect(result.code).toBe(1);
      expect(result.error).toContain(
        "Developer ID Application signing identity is required",
      );
    } finally {
      value.cleanup();
    }
  });

  test("does not load production configuration for development builds", () => {
    const value = fixture();
    const marker = resolve(value.checkout, "loaded");
    try {
      value.writeConfig(value.checkout, `touch '${marker}'\nexit 99\n`);
      const result = value.run([]);
      expect(result.code).toBe(73);
      expect(existsSync(marker)).toBe(false);
    } finally {
      value.cleanup();
    }
  });

  test("removes the temporary signing keychain after a failed build", () => {
    const value = fixture();
    try {
      value.writeConfig(
        value.checkout,
        `EDITH_SIGN_IDENTITY='${development}'\nEDITH_RELEASE_ALLOW_DEV_SIGNING=1\n`,
      );
      const result = value.run();
      expect(result.code).toBe(73);
      const operations = readFileSync(value.log, "utf8").trim().split("\n");
      expect(operations).toContain("create-keychain");
      expect(operations.at(-1)).toBe("delete-keychain");
    } finally {
      value.cleanup();
    }
  });
});
