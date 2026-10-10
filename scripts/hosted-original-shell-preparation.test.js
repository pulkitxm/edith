import { expect, test } from "bun:test";
import { createPublicKey, verify } from "node:crypto";
import {
  admitHostedJourney,
  journeyEnvelope,
  prepareJourneyParent,
} from "./hosted-original-shell/prepare-journey.mjs";

const identifier =
  "com.pulkit.edith.tests.remote-00000000-0000-4000-8000-000000000001";
const directory =
  "/Users/fixture/Applications/Edith Remote Fixture Journey 00000000-0000-4000-8000-000000000001";
const environment = {
  GITHUB_ACTIONS: "true",
  RUNNER_OS: "macOS",
  RUNNER_ENVIRONMENT: "github-hosted",
  EDITH_HOSTED_SHELL_JOURNEY: "1",
};

test("journey preparation rejects local runners and any unowned application namespace before signing or building", () => {
  admitHostedJourney(environment, directory, identifier, "/Users/fixture");
  for (const key of Object.keys(environment))
    expect(() =>
      admitHostedJourney(
        { ...environment, [key]: "false" },
        directory,
        identifier,
        "/Users/fixture",
      ),
    ).toThrow();
  expect(() =>
    admitHostedJourney(
      environment,
      directory,
      "com.pulkit.edith",
      "/Users/fixture",
    ),
  ).toThrow();
  expect(() =>
    admitHostedJourney(
      environment,
      `${directory}/../other`,
      identifier,
      "/Users/fixture",
    ),
  ).toThrow();
  expect(() =>
    admitHostedJourney(environment, directory, identifier, "/Users/other"),
  ).toThrow();
});

test("isolated catalog versions are signed envelopes with distinct monotonic revisions", () => {
  const packages = [
    { id: "calendar", version: "1.0.0" },
    { id: "calendar", version: "1.1.0" },
  ];
  const first = journeyEnvelope(packages.slice(0, 1), 1);
  const next = journeyEnvelope(packages, 2);
  const seed = Buffer.alloc(32, 90);
  const key = createPublicKey({
    key: Buffer.concat([
      Buffer.from("302e020100300506032b657004220420", "hex"),
      seed,
    ]),
    format: "der",
    type: "pkcs8",
  });
  for (const [revision, envelope] of [
    [1, first],
    [2, next],
  ]) {
    const payload = Buffer.from(envelope.payload, "base64");
    expect(
      verify(null, payload, key, Buffer.from(envelope.signature, "base64")),
    ).toBe(true);
    expect(JSON.parse(payload.toString()).revision).toBe(revision);
    expect(JSON.parse(payload.toString()).packages.length).toBe(revision);
    expect(
      verify(
        null,
        Buffer.concat([payload, Buffer.from("x")]),
        key,
        Buffer.from(envelope.signature, "base64"),
      ),
    ).toBe(false);
  }
  expect(() => journeyEnvelope(packages, 1)).toThrow();
});

test("test plan construction uses original journey sources and rejects ambient SSH injection", async () => {
  const { mkdtemp, readFile, rm } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { writeUIProject, configureUITestRun } = await import(
    "./hosted-original-shell/ui-project.mjs"
  );
  const directory = await mkdtemp(join(tmpdir(), "edith-shell-plan-"));
  try {
    const runner = {
      ...environment,
      EDITH_GUI_FIXTURE_DIRECTORY:
        "/Users/fixture/Applications/Edith Remote Fixture Journey 00000000-0000-4000-8000-000000000001",
      EDITH_JOURNEY_ACCOUNT_HOME: "/Users/fixture",
      EDITH_APPLICATION_IDENTIFIER: identifier,
      EDITH_SHARED_DEFAULTS_SUITE: identifier,
      EDITH_EXTENSION_FIXTURE_HOME:
        "/Users/fixture/Applications/Edith Remote Fixture Journey 00000000-0000-4000-8000-000000000001/synthetic-data",
      EDITH_JOURNEY_OPERATOR_ENDPOINT: "http://127.0.0.1:23456/replace",
      EDITH_JOURNEY_OPERATOR_TOKEN: "a".repeat(64),
    };
    const project = await writeUIProject(directory, runner);
    const scheme = await readFile(
      join(project, "xcshareddata/xcschemes/HostedShellJourney.xcscheme"),
      "utf8",
    );
    expect(scheme).not.toContain('key="HOME"');
    expect(scheme).not.toContain('key="XDG_');
    expect(scheme).toContain('key="EDITH_JOURNEY_ACCOUNT_HOME"');
    await expect(
      writeUIProject(directory, {
        ...runner,
        HOME: runner.EDITH_EXTENSION_FIXTURE_HOME,
      }),
    ).rejects.toThrow();
    const source = await readFile(join(project, "project.pbxproj"), "utf8");
    expect(source).toContain(
      "Tests/HostedOriginalShell/UITests/OriginalShellJourneyTests.swift",
    );
    expect(source).toContain(
      "Tests/HostedOriginalShell/Sources/JourneyContract/JourneyContract.swift",
    );
    expect(source).not.toContain("HostedManagedNativeProbe");
    expect(() =>
      configureUITestRun(join(directory, "missing-plan"), {
        SSH_AUTH_SOCK: "/ambient/socket",
      }),
    ).toThrow();
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("runner proof admission includes every actual XCTest user interaction stage in order", async () => {
  const { readFile } = await import("node:fs/promises");
  const testSource = await readFile(
    "Tests/HostedOriginalShell/UITests/OriginalShellJourneyTests.swift",
    "utf8",
  );
  const runner = await readFile(
    "scripts/hosted-original-shell/run-journey.mjs",
    "utf8",
  );
  const emitted = [
    ...testSource.matchAll(/try await (?:waitState|capture)\("([^"\n]+)"/g),
  ].map((match) => match[1]);
  const expected = runner
    .split("proof.snapshots.map((item) => item.stage),")[1]
    ?.split("],")[0];
  expect(expected).toBeDefined();
  const admitted = [...expected.matchAll(/"([^"\n]+)"/g)].map(
    (match) => match[1],
  );
  expect(admitted).toEqual(emitted);
  expect(emitted.length).toBe(13);
  expect(new Set(emitted).size).toBe(emitted.length);
});

test("fresh hosted accounts get only a validated single Applications directory", async () => {
  const { mkdtemp, realpath, lstat, mkdir, chmod, symlink, rm } = await import(
    "node:fs/promises"
  );
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const temporary = await mkdtemp(join(tmpdir(), "edith-journey-parent-"));
  const home = await realpath(temporary);
  const uuid = identifier.slice("com.pulkit.edith.tests.remote-".length);
  const applications = join(home, "Applications");
  const fixture = join(applications, `Edith Remote Fixture Journey ${uuid}`);
  const options = {
    environment,
    accountHome: home,
    identifier,
    directory: fixture,
  };
  try {
    expect(await prepareJourneyParent(options)).toBe(applications);
    expect((await lstat(applications)).mode & 0o777).toBe(0o700);
    await expect(lstat(fixture)).rejects.toThrow();
    await chmod(applications, 0o755);
    expect(await prepareJourneyParent(options)).toBe(applications);
    await chmod(applications, 0o777);
    await expect(prepareJourneyParent(options)).rejects.toThrow();
    await chmod(applications, 0o700);
    await expect(
      prepareJourneyParent({ ...options, uid: process.getuid() + 1 }),
    ).rejects.toThrow();
    await rm(applications, { recursive: true });
    const target = join(home, "unrelated");
    await mkdir(target, { mode: 0o700 });
    await symlink(target, applications);
    await expect(prepareJourneyParent(options)).rejects.toThrow();
    await expect(
      lstat(join(target, `Edith Remote Fixture Journey ${uuid}`)),
    ).rejects.toThrow();
    await rm(applications);
    await chmod(home, 0o777);
    await expect(prepareJourneyParent(options)).rejects.toThrow();
    await expect(lstat(applications)).rejects.toThrow();
    await chmod(home, 0o700);
    await expect(
      prepareJourneyParent({ ...options, environment: {} }),
    ).rejects.toThrow();
    await expect(lstat(applications)).rejects.toThrow();
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("runner metadata excludes ambient home and credentials while synthetic app paths stay exact", async () => {
  const { journeyRunnerEnvironment, configureUITestRun } = await import(
    "./hosted-original-shell/ui-project.mjs"
  );
  const { mkdtemp, rm, readFile } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { execFileSync } = await import("node:child_process");
  const runner = journeyRunnerEnvironment({
    ...environment,
    EDITH_GUI_FIXTURE_DIRECTORY: directory,
    EDITH_JOURNEY_ACCOUNT_HOME: "/Users/fixture",
    EDITH_APPLICATION_IDENTIFIER: identifier,
    EDITH_SHARED_DEFAULTS_SUITE: identifier,
    EDITH_EXTENSION_FIXTURE_HOME: `${directory}/synthetic-data`,
    EDITH_JOURNEY_OPERATOR_ENDPOINT: "http://127.0.0.1:23456/replace",
    EDITH_JOURNEY_OPERATOR_TOKEN: "a".repeat(64),
    HOME: `${directory}/synthetic-data`,
    CFFIXED_USER_HOME: `${directory}/synthetic-data`,
    SSH_AUTH_SOCK: "/ambient/socket",
  });
  expect(Object.keys(runner)).toHaveLength(11);
  expect(runner.HOME).toBeUndefined();
  expect(runner.CFFIXED_USER_HOME).toBeUndefined();
  expect(runner.SSH_AUTH_SOCK).toBeUndefined();
  for (const key of [
    "EDITH_APPLICATION_IDENTIFIER",
    "EDITH_SHARED_DEFAULTS_SUITE",
    "EDITH_EXTENSION_FIXTURE_HOME",
    "EDITH_JOURNEY_ACCOUNT_HOME",
  ])
    expect(() =>
      journeyRunnerEnvironment({ ...runner, [key]: "invalid" }),
    ).toThrow();
  const temporary = await mkdtemp(join(tmpdir(), "edith-runner-environment-"));
  const plan = join(temporary, "plan.xctestrun");
  const write = (variables) =>
    execFileSync("python3", [
      "-c",
      "import json,plistlib,sys; plistlib.dump({'__xctestrun_metadata__':{'FormatVersion':1},'HostedShellJourney':{'IsUITestBundle':True,'UseUITargetAppProvidedByTests':True,'EnvironmentVariables':json.loads(sys.argv[2])}},open(sys.argv[1],'wb'))",
      plan,
      JSON.stringify(variables),
    ]);
  try {
    write({});
    configureUITestRun(plan, runner);
    const actual = JSON.parse(
      execFileSync(
        "python3",
        [
          "-c",
          "import plistlib,json,sys; print(json.dumps(plistlib.load(open(sys.argv[1],'rb'))['HostedShellJourney']['EnvironmentVariables']))",
          plan,
        ],
        { encoding: "utf8" },
      ),
    );
    expect(actual).toEqual(runner);
    for (const key of [
      "HOME",
      "CFFIXED_USER_HOME",
      "XDG_CONFIG_HOME",
      "SSH_AUTH_SOCK",
    ]) {
      write({ [key]: `${directory}/synthetic-data` });
      expect(() => configureUITestRun(plan, runner)).toThrow();
    }
    expect((await readFile(plan)).length).toBeGreaterThan(0);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("replacement credentials are runner-only and arbitrary endpoints are rejected", async () => {
  const { journeyRunnerEnvironment } = await import(
    "./hosted-original-shell/ui-project.mjs"
  );
  const base = {
    ...environment,
    EDITH_GUI_FIXTURE_DIRECTORY: directory,
    EDITH_JOURNEY_ACCOUNT_HOME: "/Users/fixture",
    EDITH_APPLICATION_IDENTIFIER: identifier,
    EDITH_SHARED_DEFAULTS_SUITE: identifier,
    EDITH_EXTENSION_FIXTURE_HOME: `${directory}/synthetic-data`,
    EDITH_JOURNEY_OPERATOR_ENDPOINT: "http://127.0.0.1:23456/replace",
    EDITH_JOURNEY_OPERATOR_TOKEN: "a".repeat(64),
  };
  for (const endpoint of [
    "https://example.com/replace",
    "http://localhost:23456/replace",
    "http://127.0.0.1:23456/shell",
    "http://user@127.0.0.1:23456/replace",
    "http://127.0.0.1:23456/replace?path=other",
  ])
    expect(() =>
      journeyRunnerEnvironment({
        ...base,
        EDITH_JOURNEY_OPERATOR_ENDPOINT: endpoint,
      }),
    ).toThrow();
  expect(() =>
    journeyRunnerEnvironment({
      ...base,
      EDITH_JOURNEY_OPERATOR_TOKEN: "a".repeat(32),
    }),
  ).toThrow();
});
