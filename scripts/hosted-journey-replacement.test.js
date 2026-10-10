import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  cp,
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
  createJourneyReplacement,
  validateReplacementAuthorization,
  validateReplacementProcesses,
  validateReplacementRequest,
} from "./hosted-original-shell/replacement.mjs";

const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const environment = {
  GITHUB_ACTIONS: "true",
  RUNNER_OS: "macOS",
  RUNNER_ENVIRONMENT: "github-hosted",
  EDITH_HOSTED_SHELL_JOURNEY: "1",
};
const uuid = "00000000-0000-4000-8000-000000000001";
const processes = ["host", "engine", "managedUI"].map((role, index) => ({
  role,
  pid: 100 + index,
  generation: "10:20",
  running: false,
  residentBytes: null,
}));
const request = (fixture) => ({
  operation: "replaceApplication",
  hostIdentifier: fixture.identifier,
  sourceCommit: fixture.sourceCommit,
  previousVersion: "1.0.0",
  nextVersion: "2.0.0",
});
async function setup(options = {}) {
  const accountHome = await realpath(
    await mkdtemp(join(tmpdir(), "edith-replacement-")),
  );
  const directory = join(
    accountHome,
    "Applications",
    `Edith Remote Fixture Journey ${uuid}`,
  );
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const fixture = {
    identifier: `com.pulkit.edith.tests.remote-${uuid}`,
    directory,
    sourceCommit: "a".repeat(40),
    appVersions: ["1.0.0", "2.0.0"],
    executableSHA256: {
      "1.0.0": sha(Buffer.from("old")),
      "2.0.0": sha(Buffer.from("new")),
    },
    protectedSHA256: {
      "production-sentinel/usage.json": sha(Buffer.from("sentinel")),
    },
  };
  for (const [app, bytes] of [
    ["Host.app", "old"],
    ["replacement/Host.payload", "new"],
  ]) {
    await mkdir(join(directory, app, "Contents/MacOS"), {
      recursive: true,
      mode: 0o700,
    });
    await writeFile(join(directory, app, "Contents/MacOS/Edith"), bytes, {
      mode: 0o600,
    });
  }
  await mkdir(join(directory, "production-sentinel"), { mode: 0o700 });
  await writeFile(
    join(directory, "production-sentinel/usage.json"),
    "sentinel",
    { mode: 0o600 },
  );
  for (const [name, version] of [
    ["active-catalog.json", "old"],
    ["updated-catalog.json", "new"],
  ])
    await writeFile(
      join(directory, name),
      JSON.stringify({ payload: version, signature: "fixture" }),
      { mode: 0o600 },
    );
  const replace = await createJourneyReplacement({
    directory,
    environment,
    accountHome,
    fixture,
    audit: async () => processes,
    verifyApplication: async () => {},
    ...options,
  });
  return {
    fixture,
    directory,
    replace,
    cleanup: () => rm(accountHome, { recursive: true, force: true }),
  };
}

test("replacement request rejects arbitrary paths, wrong identity/source/version and unknown commands", () => {
  const fixture = { identifier: "owned", sourceCommit: "a".repeat(40) };
  validateReplacementRequest(request(fixture), fixture);
  for (const change of [
    { path: "/outside" },
    { operation: "shell" },
    { hostIdentifier: "other" },
    { sourceCommit: "b".repeat(40) },
    { nextVersion: "3.0.0" },
  ])
    expect(() =>
      validateReplacementRequest({ ...request(fixture), ...change }, fixture),
    ).toThrow();
});

test("exact known roles/generations must have actually exited before replacement", () => {
  validateReplacementProcesses(processes);
  for (const values of [
    [],
    processes.slice(0, 2),
    [...processes, processes[0]],
    processes.map((item, index) => (index ? item : { ...item, running: true })),
    processes.map((item, index) =>
      index ? item : { ...item, generation: "forged" },
    ),
    processes.map((item, index) =>
      index ? item : { ...item, residentBytes: 100 },
    ),
  ])
    expect(() => validateReplacementProcesses(values)).toThrow();
});

test("actual synthetic files replace once, preserve sentinels and reject replay", async () => {
  const value = await setup();
  try {
    await expect(
      value.replace({ ...request(value.fixture), path: "/foreign" }),
    ).rejects.toThrow();
    const result = await value.replace(request(value.fixture));
    expect(result.priorOwnedGenerationsExited).toBe(true);
    expect(
      await readFile(
        join(value.directory, "Host.app/Contents/MacOS/Edith"),
        "utf8",
      ),
    ).toBe("new");
    expect(
      await readFile(
        join(value.directory, "previous/Host.payload/Contents/MacOS/Edith"),
        "utf8",
      ),
    ).toBe("old");
    expect(
      await readFile(
        join(value.directory, "production-sentinel/usage.json"),
        "utf8",
      ),
    ).toBe("sentinel");
    await expect(value.replace(request(value.fixture))).rejects.toThrow();
  } finally {
    await value.cleanup();
  }
});

test("running prior generation and tampered source reject without mutating app or catalog", async () => {
  for (const mode of ["running", "hash", "sentinel", "symlink"]) {
    const value = await setup({
      audit: async () =>
        mode === "running"
          ? processes.map((item, index) =>
              index ? item : { ...item, running: true },
            )
          : processes,
    });
    try {
      if (mode === "hash")
        await writeFile(
          join(
            value.directory,
            "replacement/Host.payload/Contents/MacOS/Edith",
          ),
          "tampered",
        );
      if (mode === "sentinel")
        await writeFile(
          join(value.directory, "production-sentinel/usage.json"),
          "changed",
        );
      if (mode === "symlink") {
        await rm(join(value.directory, "updated-catalog.json"));
        await symlink(
          join(value.directory, "active-catalog.json"),
          join(value.directory, "updated-catalog.json"),
        );
      }
      await expect(value.replace(request(value.fixture))).rejects.toThrow();
      expect(
        await readFile(
          join(value.directory, "Host.app/Contents/MacOS/Edith"),
          "utf8",
        ),
      ).toBe("old");
      expect(
        JSON.parse(
          await readFile(join(value.directory, "active-catalog.json"), "utf8"),
        ).payload,
      ).toBe("old");
    } finally {
      await value.cleanup();
    }
  }
});

test("copy failure leaves prior app untouched and post-swap verification failure rolls back", async () => {
  for (const mode of ["copy", "verify"]) {
    let checks = 0;
    const value = await setup({
      copy:
        mode === "copy"
          ? async () => {
              throw Error("copy failed");
            }
          : cp,
      verifyApplication: async (_, version) => {
        checks++;
        if (mode === "verify" && version === "2.0.0" && checks === 6)
          throw Error("verification failed");
      },
    });
    try {
      await expect(value.replace(request(value.fixture))).rejects.toThrow();
      expect(
        await readFile(
          join(value.directory, "Host.app/Contents/MacOS/Edith"),
          "utf8",
        ),
      ).toBe("old");
      expect(
        JSON.parse(
          await readFile(join(value.directory, "active-catalog.json"), "utf8"),
        ).payload,
      ).toBe("old");
    } finally {
      await value.cleanup();
    }
  }
});

test("failed final exit guard restores both application and atomic catalog before any acknowledgement", async () => {
  let calls = 0;
  const value = await setup({
    audit: async () => {
      calls++;
      return calls === 3
        ? processes.map((item, index) =>
            index ? item : { ...item, running: true },
          )
        : processes;
    },
  });
  try {
    await expect(value.replace(request(value.fixture))).rejects.toThrow();
    expect(
      await readFile(
        join(value.directory, "Host.app/Contents/MacOS/Edith"),
        "utf8",
      ),
    ).toBe("old");
    expect(
      JSON.parse(
        await readFile(join(value.directory, "active-catalog.json"), "utf8"),
      ).payload,
    ).toBe("old");
    await expect(value.replace(request(value.fixture))).rejects.toThrow();
  } finally {
    await value.cleanup();
  }
});

test("loopback authorization rejects token replay from another source and malformed HTTP requests", () => {
  const token = "a".repeat(64);
  const request = {
    method: "POST",
    url: "/replace",
    remoteAddress: "127.0.0.1",
    contentType: "application/json",
    authorization: `Bearer ${token}`,
  };
  validateReplacementAuthorization(request, token);
  for (const changed of [
    { method: "GET" },
    { url: "/replace?command=x" },
    { remoteAddress: "192.0.2.1" },
    { contentType: "text/plain" },
    { authorization: `Bearer ${"b".repeat(64)}` },
    { authorization: "Bearer short" },
  ]) {
    expect(() =>
      validateReplacementAuthorization({ ...request, ...changed }, token),
    ).toThrow();
  }
  expect(() => validateReplacementAuthorization(request, "short")).toThrow();
});
