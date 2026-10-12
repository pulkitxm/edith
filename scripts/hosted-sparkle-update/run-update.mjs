import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, generateKeyPairSync, randomUUID } from "node:crypto";
import {
  lstat,
  mkdir,
  readdir,
  readFile,
  realpath,
  writeFile,
} from "node:fs/promises";
import { userInfo } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  exportJourneyAttachments,
  retainJourneyAttachmentProof,
} from "../hosted-original-shell/attachments.mjs";
import {
  journeyImageNames,
  validateJourneyImage,
} from "../hosted-original-shell/evidence.mjs";
import {
  validateDisabledJourneyProcesses,
  validateRemovedJourneyPackages,
} from "../hosted-original-shell/outcomes.mjs";
import { runOwnedJourneyCommand } from "../hosted-original-shell/owned-command.mjs";
import { registerJourneyApplication } from "../hosted-original-shell/registration.mjs";
import {
  createJourneyStateReader,
  startJourneyReplacementOperator,
} from "../hosted-original-shell/replacement.mjs";
import {
  configureUITestRun,
  journeyRunnerEnvironment,
  writeUIProject,
} from "../hosted-original-shell/ui-project.mjs";
import { buildSparkleHost, requireCleanSparkleSources } from "./build-host.mjs";
import { validateSparkleOutcome } from "./contract.mjs";
import {
  createSparkleActions,
  readSparkleEvents,
  validateSparkleEvents,
} from "./control.mjs";
import { createSparkleCatalogSwitch } from "./fixed-files.mjs";
import { sparkleChildEnvironment } from "./implementations.mjs";
import {
  bindSparkleProtectedState,
  inventorySparkleApp,
  prepareSparkleUpdate,
} from "./prepare-update.mjs";
import {
  createSparkleProcessLedger,
  retireSparkleProcesses,
  validateSparkleSnapshot,
} from "./process-ledger.mjs";
import {
  admitSparkleProducer,
  compileSparkleProbe,
  createSparkleCapturedProcesses,
  persistSparkleLedger,
  sparkleCompilerEnvironment,
} from "./producer.mjs";
import { reserveSparkleServer } from "./server.mjs";
import { sparkleJourneyUIOverlay } from "./source-ui.mjs";

const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
export function sparkleVariables(journey, accountHome) {
  return {
    GITHUB_ACTIONS: "true",
    RUNNER_OS: "macOS",
    RUNNER_ENVIRONMENT: "github-hosted",
    EDITH_HOSTED_SHELL_JOURNEY: "1",
    EDITH_GUI_FIXTURE_DIRECTORY: journey.directory,
    EDITH_JOURNEY_ACCOUNT_HOME: accountHome,
    EDITH_APPLICATION_IDENTIFIER: journey.identifier,
    EDITH_SHARED_DEFAULTS_SUITE: journey.identifier,
    EDITH_EXTENSION_FIXTURE_HOME: join(journey.directory, "synthetic-data"),
  };
}
export async function verifySparkleRemovedVersions(fixture) {
  assert.equal(await realpath(fixture.directory), fixture.directory);
  const root = await lstat(fixture.directory);
  assert(
    root.isDirectory() &&
      root.uid === fixture.expectedUID &&
      (root.mode & 0o777) === 0o700,
  );
  for (const version of ["1.0.0", "1.1.0"]) {
    const path = join(
      fixture.directory,
      `support/Edith Tests/remote-${fixture.session}/Extensions/calendar/edith-host-2/arm64/${version}`,
    );
    try {
      await lstat(path);
      assert.fail("Captured Calendar version directory remained after Remove");
    } catch (error) {
      assert.equal(error.code, "ENOENT");
    }
  }
  return ["1.0.0", "1.1.0"];
}
async function protectedFiles(journey) {
  const expected = [
    `production-sentinel/usage.json`,
    `support/Edith Tests/remote-${journey.identifier.slice("com.pulkit.edith.tests.remote-".length)}/Data/calendar/retained-fixture.json`,
  ];
  assert.deepEqual(
    Object.keys(journey.protectedSHA256).sort(),
    expected.sort(),
  );
  for (const [relative, hash] of Object.entries(journey.protectedSHA256)) {
    const path = join(journey.directory, relative);
    assert.equal(await realpath(path), path);
    const info = await lstat(path);
    assert(
      info.isFile() &&
        info.nlink === 1 &&
        info.uid === process.getuid() &&
        (info.mode & 0o777) === 0o600 &&
        info.size > 0 &&
        info.size <= 4096,
    );
    assert.equal(digest(await readFile(path)), hash);
  }
}
function hostOutcome(row, hash, version) {
  const { role: _role, running: _running, ...identity } = row;
  return { ...identity, executableSHA256: hash, version };
}
export function assembleSparkleOutcome(control, wrong, tampered) {
  const {
    fixture,
    original,
    installation,
    reopened,
    disabled,
    resumed,
    updated,
    finished,
  } = control;
  assert(finished?.naturalDisableValidated);
  const ledger = createSparkleProcessLedger(fixture);
  ledger.arm(original);
  ledger.installed(installation.rows, installation.old);
  ledger.reopened(reopened);
  ledger.disabled(disabled);
  const current = validateSparkleSnapshot(updated, fixture, { complete: true });
  validateSparkleSnapshot(resumed, fixture);
  assert(resumed.some((row) => row.role === "engine" && row.running));
  assert.deepEqual(
    current.find((row) => row.role === "host"),
    installation.host,
  );
  for (const prior of resumed.filter((row) => row.role !== "host")) {
    const next = current.find((row) => row.role === prior.role);
    assert.notEqual(next.pid, prior.pid);
    assert.notEqual(next.birth, prior.birth);
  }
  assert.equal(
    current.find((row) => row.role === "managedUI").executable,
    fixture.ownedRolePaths.managedUI.replace(
      "/arm64/1.0.0/calendar/",
      "/arm64/1.1.0/calendar/",
    ),
  );
  assert.deepEqual(
    finished.absent,
    current
      .filter((row) => row.role !== "host")
      .map((row) => ({ ...row, running: false })),
  );
  assert.deepEqual(finished.removed, ["1.0.0", "1.1.0"]);
  assert.deepEqual(
    validateSparkleEvents(installation.events, fixture).map(
      (row) => row.category,
    ),
    ["downloaded", "extracted", "installing", "relaunching"],
  );
  assert(
    installation.events.every(
      (row) => row.pid === original.find((row) => row.role === "host").pid,
    ),
  );
  const sessions = [fixture.session];
  for (const [proof, recipe] of [
    [wrong, "wrong-signature"],
    [tampered, "tampered-archive"],
  ]) {
    assert.equal(proof.fixture.sourceCommit, fixture.sourceCommit);
    assert.equal(proof.fixture.expectedUID, fixture.expectedUID);
    assert.equal(
      proof.fixture.identifier,
      `com.pulkit.edith.tests.remote-${proof.fixture.session}`,
    );
    assert(
      proof.fixture.session.length === 36 &&
        /^[a-f0-9-]+$/.test(proof.fixture.session),
    );
    sessions.push(proof.fixture.session);
    validateSparkleSnapshot(proof.original, proof.fixture, { complete: true });
    assert.equal(proof.negative.recipe, recipe);
    assert.equal(proof.negative.actualSparkleRejectionValidated, true);
    const events = validateSparkleEvents(proof.negative.events, proof.fixture);
    assert(
      events.every(
        (row) =>
          row.pid === proof.original.find((row) => row.role === "host").pid,
      ),
    );
    assert(
      !events.some((row) =>
        ["installing", "relaunching"].includes(row.category),
      ),
    );
    const rejections = events.filter((row) => row.category === "rejected");
    assert.equal(rejections.length, 1);
    assert(
      rejections[0].errors.some(
        (row) =>
          row.domain === "SUSparkleErrorDomain" &&
          [3001, 3002].includes(row.code),
      ),
    );
    const receipt = proof.negative.archive;
    assert.deepEqual(Object.keys(receipt).sort(), [
      "actualSparkleRejectionValidated",
      "baselineArchiveSHA256",
      "recipe",
      "servedArchiveSHA256",
      "servedSignatureSHA256",
    ]);
    assert.equal(receipt.recipe, recipe);
    assert.equal(receipt.actualSparkleRejectionValidated, false);
    assert.equal(receipt.baselineArchiveSHA256, proof.fixture.archiveSHA256);
    for (const key of [
      "baselineArchiveSHA256",
      "servedArchiveSHA256",
      "servedSignatureSHA256",
    ])
      assert(
        typeof receipt[key] === "string" &&
          receipt[key].length === 64 &&
          /^[a-f0-9]{64}$/.test(receipt[key]),
      );
    if (recipe === "wrong-signature")
      assert.equal(receipt.servedArchiveSHA256, receipt.baselineArchiveSHA256);
    else
      assert.notEqual(
        receipt.servedArchiveSHA256,
        receipt.baselineArchiveSHA256,
      );
  }
  assert.equal(new Set(sessions).size, 3);
  const roles = (rows) =>
    ["engine", "managedUI"].map((role) =>
      rows.find((row) => row.role === role),
    );
  const outcome = validateSparkleOutcome(
    {
      schema: 1,
      sourceCommit: fixture.sourceCommit,
      session: fixture.session,
      identifier: fixture.identifier,
      outcome: "passed",
      versions: fixture.versions,
      archiveSHA256: fixture.archiveSHA256,
      downloadedBytes: fixture.archiveBytes,
      sparkleInstallObserved: true,
      nativeRelaunchObserved: true,
      producerReplacementUsed: false,
      testLaunchAfterInstall: false,
      oldHost: hostOutcome(
        original.find((row) => row.role === "host"),
        fixture.initialCodeSHA256,
        "1.0.0",
      ),
      newHost: hostOutcome(
        installation.host,
        fixture.installedCodeSHA256,
        "2.0.0",
      ),
      oldOwnedSurvivors: 0,
      ownedConflicts: 0,
      protectedSHA256: fixture.protectedSHA256,
      calendarReopened: true,
      newEngineObserved: true,
      newManagedUIObserved: true,
      disabledOwnedSurvivors: 0,
      removedVersions: finished.removed,
      wrongSignatureRejected: true,
      tamperedArchiveRejected: true,
      productionGateUnchanged: true,
      hostImplementations: fixture.hostImplementations,
      installedCodeSHA256: fixture.installedCodeSHA256,
      installedResourcesSHA256: fixture.installedResourcesSHA256,
      signingRequirementSHA256: fixture.signingRequirementSHA256,
      installedSignatureVerified: installation.application.signatureVerified,
      initialMetadataSHA256: fixture.initialMetadataSHA256,
      installedMetadataSHA256: fixture.installedMetadataSHA256,
      oldRoles: roles(original),
      oldRolesAfterInstall: roles(installation.old),
      reopenedRoles: roles(reopened),
      disabledRoles: disabled,
    },
    fixture,
  );
  return {
    ...outcome,
    updatedRoles: current.filter((row) => row.role !== "host"),
    updatedDisabledRoles: finished.absent,
    naturalUpdatedDisableValidated: true,
  };
}

export async function observeSparkleNaturalExit(
  captured,
  { pause: wait = pause, attempts = 40 } = {},
) {
  assert(Number.isInteger(attempts) && attempts > 0 && attempts <= 40);
  let last;
  for (let index = 0; index < attempts; index++) {
    try {
      assert.equal((await captured.snapshot()).length, 0);
      const rows = captured.captured();
      assert(rows.length > 0);
      const absent = await Promise.all(
        rows.map((row) => captured.observe(row)),
      );
      assert.deepEqual(
        absent,
        rows.map((row) => ({ ...row, running: false })),
      );
      return absent;
    } catch (error) {
      last = error;
    }
    await wait(250);
  }
  throw last;
}

export async function cleanupSparkleCaptured(
  captured,
  fixture,
  { pause: wait = pause } = {},
) {
  let refreshRejected = false;
  try {
    await captured.snapshot();
  } catch {
    refreshRejected = true;
  }
  const rows = captured.captured();
  const observations = rows.length
    ? await retireSparkleProcesses(rows, fixture, {
        observe: captured.observe,
        signal: captured.signal,
        pause: wait,
      })
    : [];
  return { refreshRejected, observations };
}

export async function runSparkleUpdates() {
  assert.deepEqual(process.argv.slice(2), []);
  const sourceCommit = execFileSync("git", ["rev-parse", "HEAD"], {
    encoding: "utf8",
  }).trim();
  admitSparkleProducer(process.env, sourceCommit);
  requireCleanSparkleSources();
  assert.equal(process.arch, "arm64");
  const accountHome = userInfo().homedir;
  assert.equal(await realpath(accountHome), accountHome);
  assert.equal(process.env.HOME, accountHome);
  for (const key of ["GITHUB_TOKEN", "GH_TOKEN", "SSH_AUTH_SOCK"])
    delete process.env[key];
  process.env.EDITH_HOSTED_SHELL_JOURNEY = "1";
  const environment = sparkleCompilerEnvironment(
    sparkleChildEnvironment(process.env),
  );
  const root = await realpath(process.cwd());
  const output = resolve("local/hosted-sparkle-update");
  await mkdir(join(root, "local"), { mode: 0o700 }).catch((error) =>
    assert.equal(error.code, "EEXIST"),
  );
  await mkdir(output, { mode: 0o700 }).catch((error) =>
    assert.equal(error.code, "EEXIST"),
  );
  assert.equal(await realpath(output), output);
  const issuer = generateKeyPairSync("ed25519");
  const issuerPublicKey = issuer.publicKey
    .export({ format: "der", type: "spki" })
    .subarray(-32)
    .toString("base64");
  const identities =
    execFileSync("security", ["find-identity", "-v", "-p", "codesigning"], {
      env: environment,
      encoding: "utf8",
      timeout: 10000,
    }).match(/\b[0-9A-F]{40}\b/g) ?? [];
  assert.equal(identities.length, 1);
  const signingIdentity = identities[0];
  const results = [];
  let failure;
  for (const recipe of ["valid", "wrong-signature", "tampered-archive"]) {
    const session = randomUUID();
    const identifier = `com.pulkit.edith.tests.remote-${session}`;
    const directory = join(
      accountHome,
      "Applications",
      `Edith Remote Fixture Journey ${session}`,
    );
    const caseOutput = join(output, `case-${session}`);
    await mkdir(caseOutput, { mode: 0o700 });
    const server = await reserveSparkleServer();
    let operator;
    let captured;
    let preparation;
    let control;
    let caseFailure;
    let result = {
      schema: 1,
      sourceCommit,
      session,
      recipe,
      outcome: "failed",
      actualSparkleValidated: false,
      cleanup: null,
    };
    try {
      const requirement = `identifier "${identifier}" and certificate leaf = H"${signingIdentity}"`;
      const buildReceipt = await buildSparkleHost({
        sourceCommit,
        issuerPublicKey,
        signingRequirement: requirement,
        generation: "previous",
        environment,
      });
      const replacementReceipt = await buildSparkleHost({
        sourceCommit,
        issuerPublicKey,
        signingRequirement: requirement,
        generation: "current",
        environment,
      });
      await writeFile(
        join(caseOutput, "build-receipt.json"),
        JSON.stringify({ previous: buildReceipt, current: replacementReceipt }),
        { mode: 0o600 },
      );
      const probe = await compileSparkleProbe({
        sourceCommit,
        issuerPublicKey,
        output: caseOutput,
      });
      preparation = await prepareSparkleUpdate({
        root,
        buildReceipt,
        replacementReceipt,
        session,
        directory,
        identifier,
        port: server.port,
        issuer: issuer.privateKey,
        updateKeys: generateKeyPairSync("ed25519"),
        producer: probe.producer,
        signingIdentity,
        requirement,
        accountHome,
        environment,
      });
      server.configure({ ...preparation, recipe });
      const variables = sparkleVariables(preparation.journey, accountHome);
      const readState = await createJourneyStateReader({
        directory,
        environment: variables,
        accountHome,
        fixture: preparation.journey,
      });
      captured = createSparkleCapturedProcesses({
        fixture: preparation.fixture,
        issuer: issuer.privateKey,
        inspect: probe.inspect,
        persist: (bytes) => persistSparkleLedger(directory, bytes),
      });
      control = createSparkleActions({
        preparation,
        captured,
        readState,
        bindProtected: (fixture, state) =>
          bindSparkleProtectedState(fixture, state, process.env, accountHome),
        readEvents: () => readSparkleEvents(directory, preparation.fixture),
        inventory: (version) =>
          inventorySparkleApp(join(directory, "Host.app"), {
            identifier,
            version,
            requirement,
          }),
        switchCatalog: await createSparkleCatalogSwitch(directory),
        server,
        recipe,
        verifyRemoved: () => verifySparkleRemovedVersions(preparation.fixture),
      });
      operator = await startJourneyReplacementOperator(control.action, {
        readState,
      });
      const runnerVariables = journeyRunnerEnvironment({
        ...variables,
        EDITH_JOURNEY_OPERATOR_ENDPOINT: operator.endpoint,
        EDITH_JOURNEY_OPERATOR_TOKEN: operator.token,
      });
      const registrationExecutable = join(caseOutput, "JourneyRegistration");
      execFileSync(
        "xcrun",
        [
          "swiftc",
          "-parse-as-library",
          "-target",
          "arm64-apple-macos14.0",
          "Tests/HostedOriginalShell/Sources/JourneyContract/JourneyContract.swift",
          "Tests/HostedOriginalShell/FixtureSources/JourneyRegistration.swift",
          "-o",
          registrationExecutable,
        ],
        { env: environment, stdio: "inherit", timeout: 180000 },
      );
      await registerJourneyApplication({
        directory,
        fixture: preparation.journey,
        environment: variables,
        accountHome,
        version: "1.0.0",
        registrationExecutable,
      });
      const originalPath =
        "Tests/HostedOriginalShell/UITests/OriginalShellJourneyTests.swift";
      const original = await readFile(originalPath, "utf8");
      assert.equal(
        original,
        execFileSync("git", ["show", `HEAD:${originalPath}`], {
          encoding: "utf8",
        }),
      );
      const source = sparkleJourneyUIOverlay(original, recipe);
      const sourcePath = join(caseOutput, "OriginalShellJourneyTests.swift");
      await writeFile(sourcePath, source, { mode: 0o600, flag: "wx" });
      const project = await writeUIProject(caseOutput, runnerVariables);
      const projectFile = join(project, "project.pbxproj");
      const projectSource = await readFile(projectFile, "utf8");
      const originalReference = JSON.stringify(join(root, originalPath));
      assert.equal(projectSource.split(originalReference).length, 2);
      await writeFile(
        projectFile,
        projectSource.replace(originalReference, JSON.stringify(sourcePath)),
      );
      const derived = join(caseOutput, "DerivedData");
      execFileSync(
        "xcodebuild",
        [
          "build-for-testing",
          "-project",
          project,
          "-scheme",
          "HostedShellJourney",
          "-destination",
          "platform=macOS,arch=arm64",
          "-derivedDataPath",
          derived,
          "-jobs",
          "1",
          "-parallel-testing-enabled",
          "NO",
        ],
        { env: environment, stdio: "inherit", timeout: 180000 },
      );
      const products = join(derived, "Build/Products");
      const plans = (await readdir(products)).filter((name) =>
        name.endsWith(".xctestrun"),
      );
      assert.equal(plans.length, 1);
      const plan = join(products, plans[0]);
      configureUITestRun(plan, runnerVariables);
      let commandFailure;
      try {
        await runOwnedJourneyCommand(
          "xcodebuild",
          [
            "test-without-building",
            "-xctestrun",
            plan,
            "-destination",
            "platform=macOS,arch=arm64",
            "-jobs",
            "1",
            "-parallel-testing-enabled",
            "NO",
            "-resultBundlePath",
            join(caseOutput, "HostedShellJourney.xcresult"),
          ],
          { env: environment, stdio: "inherit" },
        );
      } catch (error) {
        commandFailure = error;
      }
      let attachments;
      try {
        attachments = await exportJourneyAttachments({
          resultBundle: join(caseOutput, "HostedShellJourney.xcresult"),
          outputDirectory: join(caseOutput, "journey-attachments"),
        });
        await retainJourneyAttachmentProof(attachments, caseOutput);
      } catch (error) {
        result.attachmentFailure = {
          phase: error.phase ?? "attachment-read",
          category: error.category ?? "invalid-export",
        };
        if (!commandFailure) throw error;
      }
      if (commandFailure) throw commandFailure;
      await protectedFiles(preparation.journey);
      const proof = control.proof();
      const absent = await observeSparkleNaturalExit(captured);
      if (recipe === "valid") {
        assert(
          proof.finished?.naturalDisableValidated &&
            proof.updated?.length === 3,
        );
        validateDisabledJourneyProcesses(attachments.proof);
        validateRemovedJourneyPackages(attachments.proof);
        assert.deepEqual(
          attachments.images.map(({ name }) => name).sort(),
          [...journeyImageNames].sort(),
        );
        for (const image of attachments.images) {
          const bytes = await attachments.readOwned(
            image.file,
            image.maximumBytes,
          );
          validateJourneyImage(image.name, bytes, {
            outcome: "passed",
            actualJourneyValidated: true,
          });
          await writeFile(join(output, image.name), bytes, {
            mode: 0o600,
            flag: "wx",
          });
        }
      } else {
        assert(proof.negative?.actualSparkleRejectionValidated);
        assert.equal(attachments.images.length, 0);
      }
      result = {
        ...result,
        outcome: "passed",
        actualSparkleValidated: true,
        sourceOverlay: {
          originalSHA256: digest(original),
          fixtureSHA256: digest(source),
        },
        producerSourceSHA256: probe.sourceSHA256,
        control: proof,
        journey: attachments.proof,
        naturalExitObservations: absent,
        server: {
          recipe: server.recipe(),
          observations: server.observations(),
        },
        productionExecutableUnchangedProof: false,
      };
    } catch (error) {
      caseFailure = error;
      result.failureCategory = "sparkle-fixture-failed";
    } finally {
      if (captured) {
        try {
          result.cleanup = await cleanupSparkleCaptured(
            captured,
            preparation.fixture,
          );
          assert.equal(result.cleanup.refreshRejected, false);
        } catch (error) {
          result.cleanupRejected = true;
          caseFailure ??= error;
        }
      }
      if (operator) await operator.close();
      await server.close();
      if (caseFailure) {
        result.outcome = "failed";
        result.actualSparkleValidated = false;
      }
      const bytes = JSON.stringify(result);
      assert(Buffer.byteLength(bytes) <= 2097152);
      await writeFile(join(caseOutput, "result.json"), bytes, { mode: 0o600 });
      results.push(result);
    }
    if (caseFailure) {
      failure = caseFailure;
      break;
    }
  }
  let aggregate = {
    schema: 1,
    sourceCommit,
    outcome: "failed",
    actualSparkleFullArchiveUpdateValidated: false,
    cases: results,
  };
  if (!failure) {
    assert.deepEqual(
      results.map((row) => row.recipe),
      ["valid", "wrong-signature", "tampered-archive"],
    );
    assert.equal(new Set(results.map((row) => row.session)).size, 3);
    aggregate = {
      ...aggregate,
      outcome: "passed",
      actualSparkleFullArchiveUpdateValidated: true,
      proof: assembleSparkleOutcome(
        results[0].control,
        results[1].control,
        results[2].control,
      ),
      deltaUpdateValidated: false,
      composedHostImplementationUpdateValidated: true,
      historicalBinaryCompatibilityValidated: false,
      productionPublicReleaseValidated: false,
    };
  }
  const bytes = JSON.stringify(aggregate);
  assert(Buffer.byteLength(bytes) <= 8388608);
  await writeFile(join(output, "result.json"), bytes, { mode: 0o600 });
  if (failure) throw failure;
  console.log(
    JSON.stringify({
      schema: 1,
      sourceCommit,
      outcome: "passed",
      actualSparkleFullArchiveUpdateValidated: true,
      syntheticRejectionCases: 2,
    }),
  );
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
)
  await runSparkleUpdates();
