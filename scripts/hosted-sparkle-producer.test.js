import { expect, test } from "bun:test";
import { generateKeyPairSync, verify } from "node:crypto";
import { readFile } from "node:fs/promises";
import {
  admitSparkleProducer,
  createSparkleCapturedProcesses,
  sparkleCompilerEnvironment,
  sparkleProbeSource,
} from "./hosted-sparkle-update/producer.mjs";

test("only source-pinned nonpublishing hosted actors and closed compiler environments are admitted", () => {
  const source = "a".repeat(40);
  const environment = {
    GITHUB_ACTIONS: "true",
    RUNNER_OS: "macOS",
    RUNNER_ENVIRONMENT: "github-hosted",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_ACTOR_ID: "65671483",
    GITHUB_REF: "refs/heads/feat/hosted-sparkle-execution",
    GITHUB_SHA: source,
    EDITH_HOSTED_SPARKLE_UPDATE: "1",
    EDITH_HOSTED_RELEASE: "false",
    EDITH_HOSTED_REBUILD: "",
  };
  expect(() => admitSparkleProducer(environment, source)).not.toThrow();
  for (const [key, value] of Object.entries({
    GITHUB_SHA: "b".repeat(40),
    GITHUB_ACTOR_ID: "1",
    GITHUB_REF: "refs/heads/foreign",
    EDITH_HOSTED_RELEASE: "true",
    EDITH_HOSTED_REBUILD: "calendar",
  }))
    expect(() =>
      admitSparkleProducer({ ...environment, [key]: value }, source),
    ).toThrow();
  expect(
    sparkleCompilerEnvironment({
      HOME: "/owned",
      CFFIXED_USER_HOME: "/owned",
      PATH: "/bin",
      GITHUB_TOKEN: "private",
      SSH_AUTH_SOCK: "/foreign",
      EDITH_EXTENSION_ID: "foreign",
    }),
  ).toEqual({ HOME: "/owned", CFFIXED_USER_HOME: "/owned", PATH: "/bin" });
});

test("the actual probe template contains exactly one issuer and source pin and changed templates reject", async () => {
  const template = await readFile(
    "Tests/HostedSparkleUpdate/ProducerSources/SparkleProcessProbe.swift",
    "utf8",
  );
  const key = Buffer.alloc(32, 3).toString("base64");
  const result = sparkleProbeSource(template, "a".repeat(40), key);
  expect(result).toContain(
    `static let issuer = Data(base64Encoded: "${key}")!`,
  );
  expect(result).not.toContain("__SPARKLE_");
  expect(() =>
    sparkleProbeSource(
      `${template}__SPARKLE_ISSUER_KEY__`,
      "a".repeat(40),
      key,
    ),
  ).toThrow();
});

test("only real captured immutable role generations enter signed cleanup authority", async () => {
  const keys = generateKeyPairSync("ed25519");
  const fixture = {
    sourceCommit: "a".repeat(40),
    session: "00000000-0000-4000-8000-000000000001",
    directory:
      "/Users/runner/Applications/Edith Remote Fixture Journey 00000000-0000-4000-8000-000000000001",
    expectedUID: 501,
    producer: {
      pid: 111,
      birth: "1.2",
      uid: 501,
      executable: "/owned/node",
      executableSHA256: "b".repeat(64),
    },
    ownedRolePaths: { engine: "/owned/engine", managedUI: "/owned/ui" },
  };
  const row = {
    role: "host",
    pid: 222,
    birth: "2.3",
    uid: 501,
    executable: `${fixture.directory}/Host.app/Contents/MacOS/Edith`,
    running: true,
  };
  const calls = [];
  let bytes;
  const owned = createSparkleCapturedProcesses({
    fixture,
    issuer: keys.privateKey,
    inspect: async (operation, _directory, observations) => {
      calls.push(operation);
      return operation === "snapshot"
        ? [{ ...row }]
        : observations.map((item) => ({ ...item, running: false }));
    },
    persist: async (value) => {
      bytes = value;
    },
  });
  await expect(owned.signal(row, "TERM")).rejects.toThrow();
  expect(calls).toEqual([]);
  await owned.snapshot();
  const envelope = JSON.parse(bytes);
  const payload = Buffer.from(envelope.payload, "base64");
  expect(
    verify(
      null,
      payload,
      keys.publicKey,
      Buffer.from(envelope.signature, "base64"),
    ),
  ).toBe(true);
  expect(JSON.parse(payload).observations).toEqual([row]);
  const exposed = owned.captured();
  exposed[0].pid = 999;
  expect(owned.captured()).toEqual([row]);
  expect(await owned.observe(row)).toEqual({ ...row, running: false });
  await expect(
    owned.signal({ ...row, birth: "9.9" }, "KILL"),
  ).rejects.toThrow();
  await owned.signal(row, "TERM");
  expect(calls).toEqual(["snapshot", "observe", "TERM"]);
});
