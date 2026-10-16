import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  chmod,
  link,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  registerJourneyApplication,
  validateJourneyRegistrationReceipt,
} from "./hosted-original-shell/registration.mjs";

const hosted = {
  GITHUB_ACTIONS: "true",
  RUNNER_OS: "macOS",
  RUNNER_ENVIRONMENT: "github-hosted",
  EDITH_HOSTED_SHELL_JOURNEY: "1",
};
const uuid = "00000000-0000-4000-8000-000000000001";
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");

async function setup() {
  const accountHome = await realpath(
    await mkdtemp(join(tmpdir(), "journey-registration-")),
  );
  const directory = join(
    accountHome,
    "Applications",
    `Edith Remote Fixture Journey ${uuid}`,
  );
  await mkdir(join(directory, "Host.app/Contents/MacOS"), {
    recursive: true,
    mode: 0o700,
  });
  const bytes = Buffer.from("synthetic application executable");
  const fixture = {
    schema: 1,
    identifier: `com.pulkit.edith.tests.remote-${uuid}`,
    directory,
    sourceCommit: "a".repeat(40),
    executableSHA256: {
      "1.0.0": sha(bytes),
      "2.0.0": sha(Buffer.from("synthetic updated executable")),
    },
    versions: ["1.0.0", "1.1.0"],
    appVersions: ["1.0.0", "2.0.0"],
    protectedSHA256: {},
  };
  await writeFile(join(directory, "journey.json"), JSON.stringify(fixture), {
    mode: 0o600,
  });
  await writeFile(join(directory, "Host.app/Contents/MacOS/Edith"), bytes, {
    mode: 0o700,
  });
  await writeFile(
    join(directory, "Host.app/Contents/Info.plist"),
    "synthetic plist validated by injected native executor",
    { mode: 0o600 },
  );
  const registrationExecutable = join(accountHome, "JourneyRegistration");
  await writeFile(registrationExecutable, "synthetic tool never executed", {
    mode: 0o700,
  });
  const options = {
    directory,
    fixture,
    environment: hosted,
    accountHome,
    version: "1.0.0",
    registrationExecutable,
  };
  const receipt = {
    schema: 1,
    hostIdentifier: fixture.identifier,
    sourceCommit: fixture.sourceCommit,
    applicationVersion: "1.0.0",
    executableSHA256: fixture.executableSHA256["1.0.0"],
    registrationStatus: 0,
    registeredCount: 1,
    uniqueRegisteredPathMatched: true,
  };
  return {
    options,
    receipt,
    close: () => rm(accountHome, { recursive: true, force: true }),
  };
}

test("producer registration uses only the closed native tool and retains its owned receipt", async () => {
  const { options, receipt, close } = await setup();
  try {
    await writeFile(
      join(options.directory, "registration.json"),
      JSON.stringify(receipt),
      { mode: 0o600 },
    );
    let calls = 0;
    const result = await registerJourneyApplication({
      ...options,
      environment: {
        ...hosted,
        SSH_AUTH_SOCK: "/private/synthetic-agent",
        SECRET: "synthetic-secret",
      },
      execute: async (executable, args, commandOptions) => {
        calls++;
        expect(executable).toBe(options.registrationExecutable);
        expect(args).toEqual([
          options.directory,
          "1.0.0",
          options.fixture.sourceCommit,
          options.fixture.executableSHA256["1.0.0"],
        ]);
        expect(commandOptions.timeout).toBe(30_000);
        expect(commandOptions.maxBuffer).toBe(16_384);
        expect(commandOptions.env.SSH_AUTH_SOCK).toBeUndefined();
        expect(commandOptions.env.SECRET).toBeUndefined();
        expect(commandOptions.env.HOME).toBe(options.accountHome);
        expect(commandOptions.env.CFFIXED_USER_HOME).toBe(options.accountHome);
        await expect(
          readFile(join(options.directory, "registration.json")),
        ).rejects.toThrow();
        await writeFile(
          join(options.directory, "registration.json"),
          JSON.stringify(receipt),
          { mode: 0o600 },
        );
      },
    });
    expect(calls).toBe(1);
    expect(result).toEqual(receipt);
  } finally {
    await close();
  }
});

test("local runners, foreign source, unknown versions and unowned namespaces reject before execution", async () => {
  for (const mutate of [
    (value) => {
      value.environment = {};
    },
    (value) => {
      value.fixture = { ...value.fixture, identifier: "com.pulkit.edith" };
    },
    (value) => {
      value.fixture = { ...value.fixture, sourceCommit: "b".repeat(40) };
    },
    (value) => {
      value.version = "3.0.0";
    },
    (value) => {
      value.directory += "/../outside";
    },
    (value) => {
      value.registrationExecutable = "/bin/sh";
    },
    (value) => {
      value.fixture = { ...value.fixture, schema: 2 };
    },
  ]) {
    const { options, close } = await setup();
    try {
      mutate(options);
      let called = false;
      await expect(
        registerJourneyApplication({
          ...options,
          execute: async () => {
            called = true;
          },
        }),
      ).rejects.toMatchObject({
        phase: "registration-admission",
        category: "invalid-registration-input",
      });
      expect(called).toBe(false);
    } finally {
      await close();
    }
  }
});

test("symlinks, hard links, public roots, altered executables and nonexecutable tools fail closed", async () => {
  for (const mode of [
    "symlink",
    "hardlink",
    "public-root",
    "tamper",
    "tool",
    "receipt-symlink",
    "public-fixture",
  ]) {
    const { options, close } = await setup();
    try {
      const executable = join(
        options.directory,
        "Host.app/Contents/MacOS/Edith",
      );
      if (mode === "symlink") {
        await rm(executable);
        await symlink(options.registrationExecutable, executable);
      } else if (mode === "hardlink")
        await link(executable, join(options.accountHome, "linked"));
      else if (mode === "public-root") await chmod(options.directory, 0o755);
      else if (mode === "tamper")
        await writeFile(executable, "changed synthetic executable");
      else if (mode === "tool")
        await chmod(options.registrationExecutable, 0o600);
      else if (mode === "receipt-symlink")
        await symlink(
          options.registrationExecutable,
          join(options.directory, "registration.json"),
        );
      else await chmod(join(options.directory, "journey.json"), 0o644);
      let called = false;
      await expect(
        registerJourneyApplication({
          ...options,
          execute: async () => {
            called = true;
          },
        }),
      ).rejects.toMatchObject({
        phase: "registration-admission",
        category: "invalid-registration-input",
      });
      expect(called).toBe(false);
    } finally {
      await close();
    }
  }
});

test("signature, registration status and registered path failures retain closed categories only", async () => {
  for (const category of [
    "signature-rejected",
    "registration-status-rejected",
    "registered-path-rejected",
    "metadata-rejected",
  ]) {
    const { options, close } = await setup();
    try {
      let error;
      try {
        await registerJourneyApplication({
          ...options,
          execute: async () => {
            throw Object.assign(Error("/private/synthetic-secret"), {
              stderr: JSON.stringify({ category }),
            });
          },
        });
      } catch (failure) {
        error = failure;
      }
      expect(error.phase).toBe("registration-command");
      expect(error.category).toBe(category);
      expect(error.message).not.toContain("/private");
      expect(JSON.stringify(error)).not.toContain("synthetic-secret");
    } finally {
      await close();
    }
  }
});

test("only exact successful registration receipts are admitted", async () => {
  const { options, receipt, close } = await setup();
  try {
    expect(
      validateJourneyRegistrationReceipt(receipt, options.fixture, "1.0.0"),
    ).toEqual(receipt);
    for (const changes of [
      { schema: 2 },
      { hostIdentifier: "foreign" },
      { sourceCommit: "b".repeat(40) },
      { applicationVersion: "2.0.0" },
      { executableSHA256: "b".repeat(64) },
      { registrationStatus: -10819 },
      { registeredCount: 2 },
      { uniqueRegisteredPathMatched: false },
      { unexpected: "/private/synthetic-secret" },
    ])
      expect(() =>
        validateJourneyRegistrationReceipt(
          { ...receipt, ...changes },
          options.fixture,
          "1.0.0",
        ),
      ).toThrow();
  } finally {
    await close();
  }
});

test("command bounds and invalid receipt permissions remain failures", async () => {
  for (const mode of ["timeout", "overflow", "public", "oversize", "missing"]) {
    const { options, receipt, close } = await setup();
    try {
      const category =
        mode === "timeout"
          ? "timed-out"
          : mode === "overflow"
            ? "output-limit-exceeded"
            : "invalid-registration-receipt";
      await expect(
        registerJourneyApplication({
          ...options,
          execute: async () => {
            if (mode === "timeout") throw { killed: true };
            if (mode === "overflow")
              throw { killed: true, code: "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" };
            if (mode !== "missing")
              await writeFile(
                join(options.directory, "registration.json"),
                mode === "oversize"
                  ? " ".repeat(16_385)
                  : JSON.stringify(receipt),
                { mode: mode === "public" ? 0o644 : 0o600 },
              );
            if (mode === "public")
              await chmod(join(options.directory, "registration.json"), 0o644);
          },
        }),
      ).rejects.toMatchObject({ category });
    } finally {
      await close();
    }
  }
});

test("initial, replacement and rollback registration retain the exact current executable proof", async () => {
  const { options, receipt, close } = await setup();
  try {
    const original = Buffer.from("synthetic application executable");
    const replacement = Buffer.from("synthetic updated executable");
    for (const version of ["1.0.0", "2.0.0", "1.0.0"]) {
      await writeFile(
        join(options.directory, "Host.app/Contents/MacOS/Edith"),
        version === "1.0.0" ? original : replacement,
      );
      const current = {
        ...receipt,
        applicationVersion: version,
        executableSHA256: options.fixture.executableSHA256[version],
      };
      const result = await registerJourneyApplication({
        ...options,
        version,
        execute: async (_, args) => {
          expect(args[1]).toBe(version);
          expect(args[3]).toBe(current.executableSHA256);
          await writeFile(
            join(options.directory, "registration.json"),
            JSON.stringify(current),
            { mode: 0o600 },
          );
        },
      });
      expect(result).toEqual(current);
    }
  } finally {
    await close();
  }
});

test("post-command source or executable mutation rejects even a valid native receipt", async () => {
  for (const mode of ["source", "executable"]) {
    const { options, receipt, close } = await setup();
    try {
      await expect(
        registerJourneyApplication({
          ...options,
          execute: async () => {
            await writeFile(
              join(options.directory, "registration.json"),
              JSON.stringify(receipt),
              { mode: 0o600 },
            );
            if (mode === "source")
              await writeFile(
                join(options.directory, "journey.json"),
                JSON.stringify({
                  ...options.fixture,
                  sourceCommit: "b".repeat(40),
                }),
              );
            else
              await writeFile(
                join(options.directory, "Host.app/Contents/MacOS/Edith"),
                "changed after registration",
              );
          },
        }),
      ).rejects.toMatchObject({
        phase: "registration-read",
        category: "invalid-registration-receipt",
      });
    } finally {
      await close();
    }
  }
});
