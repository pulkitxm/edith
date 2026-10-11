import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, sign } from "node:crypto";
import { lstat, open, readFile, realpath, rename } from "node:fs/promises";
import { join } from "node:path";
import { canonicalSparkleJSON } from "./prepare-update.mjs";
import {
  validateSparkleProcess,
  validateSparkleSnapshot,
} from "./process-ledger.mjs";

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
export function admitSparkleProducer(environment, sourceCommit) {
  assert.equal(environment.GITHUB_ACTIONS, "true");
  assert.equal(environment.RUNNER_OS, "macOS");
  assert.equal(environment.RUNNER_ENVIRONMENT, "github-hosted");
  assert.equal(environment.GITHUB_REPOSITORY, "pulkitxm/edith");
  assert(["65671483", "320458784"].includes(environment.GITHUB_ACTOR_ID));
  assert(
    [
      "refs/heads/main",
      "refs/heads/feat/extension-marketplace",
      "refs/heads/feat/hosted-sparkle-update",
      "refs/heads/feat/hosted-sparkle-execution",
    ].includes(environment.GITHUB_REF),
  );
  assert(
    typeof sourceCommit === "string" &&
      sourceCommit.length === 40 &&
      /^[a-f0-9]{40}$/.test(sourceCommit),
  );
  assert.equal(environment.GITHUB_SHA, sourceCommit);
  assert.equal(environment.EDITH_HOSTED_SPARKLE_UPDATE, "1");
  assert.equal(environment.EDITH_HOSTED_RELEASE, "false");
  assert.equal(environment.EDITH_HOSTED_REBUILD, "");
}

export function sparkleCompilerEnvironment(environment) {
  const result = {};
  for (const key of [
    "PATH",
    "HOME",
    "CFFIXED_USER_HOME",
    "TMPDIR",
    "DEVELOPER_DIR",
    "LANG",
    "LC_ALL",
  ])
    if (environment[key] !== undefined) result[key] = environment[key];
  assert(typeof result.HOME === "string" && result.HOME.startsWith("/"));
  if (result.CFFIXED_USER_HOME !== undefined)
    assert.equal(result.CFFIXED_USER_HOME, result.HOME);
  return result;
}

export function sparkleProbeSource(source, sourceCommit, issuerPublicKey) {
  assert(sourceCommit.length === 40 && /^[a-f0-9]{40}$/.test(sourceCommit));
  const key = Buffer.from(issuerPublicKey, "base64");
  assert.equal(key.length, 32);
  assert.equal(key.toString("base64"), issuerPublicKey);
  for (const anchor of ["__SPARKLE_ISSUER_KEY__", "__SPARKLE_SOURCE_COMMIT__"])
    assert.equal(source.split(anchor).length, 2);
  return source
    .replace("__SPARKLE_ISSUER_KEY__", issuerPublicKey)
    .replace("__SPARKLE_SOURCE_COMMIT__", sourceCommit);
}

export async function compileSparkleProbe({
  sourceCommit,
  issuerPublicKey,
  output,
  execute = execFileSync,
}) {
  admitSparkleProducer(process.env, sourceCommit);
  assert.equal(await realpath(output), output);
  const info = await lstat(output);
  assert(
    info.isDirectory() &&
      info.uid === process.getuid() &&
      (info.mode & 0o777) === 0o700,
  );
  const path =
    "Tests/HostedSparkleUpdate/ProducerSources/SparkleProcessProbe.swift";
  const original = await readFile(path, "utf8");
  assert.equal(
    original,
    execute("git", ["show", `HEAD:${path}`], { encoding: "utf8" }),
  );
  const source = sparkleProbeSource(original, sourceCommit, issuerPublicKey);
  const generated = join(output, "SparkleProcessProbe.swift");
  const handle = await open(generated, "wx", 0o600);
  try {
    await handle.writeFile(source);
    await handle.sync();
  } finally {
    await handle.close();
  }
  const contract =
    "Tests/HostedSparkleUpdate/Sources/SparkleFixtureContract/SparkleFixtureContract.swift";
  assert.equal(
    await readFile(contract, "utf8"),
    execute("git", ["show", `HEAD:${contract}`], { encoding: "utf8" }),
  );
  const executable = join(output, "SparkleProcessProbe");
  const environment = sparkleCompilerEnvironment(process.env);
  execute(
    "xcrun",
    [
      "swiftc",
      "-swift-version",
      "6",
      "-parse-as-library",
      "-target",
      "arm64-apple-macos14.0",
      contract,
      generated,
      "-o",
      executable,
    ],
    { stdio: "pipe", env: environment, timeout: 180000, maxBuffer: 65536 },
  );
  const executableHash = sha256(await readFile(executable));
  const executablePin = await lstat(executable, { bigint: true });
  assert(
    executablePin.isFile() &&
      executablePin.uid === BigInt(process.getuid()) &&
      executablePin.nlink === 1n &&
      (executablePin.mode & 0o022n) === 0n &&
      (executablePin.mode & 0o111n) !== 0n,
  );
  const requirePinned = async () => {
    assert.equal(await realpath(executable), executable);
    const current = await lstat(executable, { bigint: true });
    for (const field of [
      "dev",
      "ino",
      "uid",
      "mode",
      "nlink",
      "size",
      "mtimeNs",
      "ctimeNs",
    ])
      assert.equal(current[field], executablePin[field]);
    assert.equal(sha256(await readFile(executable)), executableHash);
  };
  const invoke = async (mode, input, maxBuffer) => {
    await requirePinned();
    const result = JSON.parse(
      execute(executable, [mode], {
        input,
        encoding: "utf8",
        env: environment,
        timeout: 10000,
        maxBuffer,
      }),
    );
    await requirePinned();
    return result;
  };
  const inspect = async (operation, directory, observations = []) => {
    const request = canonicalSparkleJSON({
      operation,
      directory,
      observations,
    });
    assert(request.length <= 16384);
    return invoke("request", request, 16384);
  };
  const producer = await invoke("producer", undefined, 4096);
  assert.equal(producer.pid, process.pid);
  assert.equal(producer.uid, process.getuid());
  assert.equal(producer.executable, await realpath(process.execPath));
  assert.equal(
    producer.executableSHA256,
    sha256(await readFile(producer.executable)),
  );
  assert(/^[0-9]+\.[0-9]+$/.exec(producer.birth)?.[0] === producer.birth);
  return {
    producer,
    inspect,
    sourceSHA256: sha256(source),
    originalSHA256: sha256(original),
    executableSHA256: executableHash,
  };
}

export function createSparkleCapturedProcesses({
  fixture,
  issuer,
  inspect,
  persist,
}) {
  const captured = new Map();
  const identity = (row) => `${row.role}:${row.pid}:${row.birth}`;
  const requireCaptured = (row) => {
    const value = validateSparkleProcess(row, fixture);
    assert.deepEqual(captured.get(identity(value)), {
      ...value,
      running: true,
    });
    return value;
  };
  return {
    async snapshot() {
      const rows = validateSparkleSnapshot(
        await inspect("snapshot", fixture.directory),
        fixture,
      );
      for (const row of rows) {
        assert(row.running);
        captured.set(identity(row), { ...row });
      }
      assert(captured.size <= 12);
      const payload = canonicalSparkleJSON({
        sourceCommit: fixture.sourceCommit,
        session: fixture.session,
        producer: fixture.producer,
        observations: [...captured.values()],
      });
      assert(payload.length <= 8192);
      await persist(
        canonicalSparkleJSON({
          payload: payload.toString("base64"),
          signature: sign(null, payload, issuer).toString("base64"),
        }),
      );
      return rows;
    },
    async observe(row) {
      const expected = requireCaptured(row);
      const rows = await inspect("observe", fixture.directory, [expected]);
      assert(Array.isArray(rows) && rows.length === 1);
      const value = validateSparkleProcess(rows[0], fixture);
      assert.deepEqual(
        { ...value, running: true },
        { ...expected, running: true },
      );
      return value;
    },
    async signal(row, signal) {
      const expected = requireCaptured(row);
      assert(["TERM", "KILL"].includes(signal));
      const result = await inspect(signal, fixture.directory, [expected]);
      assert(Array.isArray(result) && result.length === 1);
      assert.deepEqual(
        { ...validateSparkleProcess(result[0], fixture), running: true },
        { ...expected, running: true },
      );
    },
    captured() {
      return [...captured.values()].map((row) => ({ ...row }));
    },
  };
}

export async function persistSparkleLedger(directory, bytes) {
  const state = await lstat(directory);
  assert.equal(await realpath(directory), directory);
  assert(
    state.isDirectory() &&
      state.uid === process.getuid() &&
      (state.mode & 0o777) === 0o700,
  );
  assert(bytes.length > 0 && bytes.length <= 16384);
  const temporary = join(directory, "sparkle-owned-ledger.tmp");
  const final = join(directory, "sparkle-owned-ledger.json");
  const handle = await open(temporary, "wx", 0o600);
  try {
    await handle.writeFile(bytes);
    await handle.sync();
  } finally {
    await handle.close();
  }
  const current = await lstat(directory);
  assert.equal(current.ino, state.ino);
  assert.equal(current.dev, state.dev);
  assert.equal(current.uid, state.uid);
  assert.equal(current.mode, state.mode);
  assert.equal(await realpath(directory), directory);
  await rename(temporary, final);
}
