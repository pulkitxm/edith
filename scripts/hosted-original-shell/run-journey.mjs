import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  mkdir,
  readdir,
  readFile,
  realpath,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import {
  exportJourneyAttachments,
  retainJourneyAttachmentProof,
} from "./attachments.mjs";
import { journeyImageNames, validateJourneyImage } from "./evidence.mjs";
import { validateDisabledJourneyProcesses } from "./outcomes.mjs";
import { runOwnedJourneyCommand } from "./owned-command.mjs";
import { admitHostedJourney, prepareJourney } from "./prepare-journey.mjs";
import {
  createJourneyReplacement,
  createJourneyStateReader,
  startJourneyReplacementOperator,
} from "./replacement.mjs";
import {
  configureUITestRun,
  journeyRunnerEnvironment,
  writeUIProject,
} from "./ui-project.mjs";

assert.deepEqual(process.argv.slice(2), []);
const uuid = randomUUID();
const identifier = `com.pulkit.edith.tests.remote-${uuid}`;
const directory = join(
  homedir(),
  "Applications",
  `Edith Remote Fixture Journey ${uuid}`,
);
admitHostedJourney(process.env, directory, identifier, homedir());
assert.equal(process.arch, "arm64");
const root = await realpath(process.cwd());
const output = resolve("local/hosted-original-shell");
const derived = join(output, "DerivedData");
let outcome = {
  schema: 1,
  outcome: "failed",
  hostIdentifier: identifier,
  actualJourneyValidated: false,
};
let failure;
let replacementOperator;
try {
  const receipt = JSON.parse(
    await readFile(join(output, "build-receipt.json"), "utf8"),
  );
  assert.equal(
    receipt.sourceCommit,
    execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
  );
  assert.equal(receipt.productionExecutableUnchangedProof, false);
  assert.equal(receipt.frozenHost, join(output, "frozen/Edith.app"));
  assert.deepEqual(Object.keys(receipt.overlays).sort(), [
    "HostApplication.swift",
    "HostPermissions.swift",
    "HostRemoteContentPresenter.swift",
    "HostWorkspace.swift",
  ]);
  await prepareJourney({
    root,
    directory,
    identifier,
    frozenHost: receipt.frozenHost,
    sourceCommit: receipt.sourceCommit,
    executableSHA256: receipt.fixtureExecutableSHA256,
  });
  const variables = {
    GITHUB_ACTIONS: "true",
    RUNNER_OS: "macOS",
    RUNNER_ENVIRONMENT: "github-hosted",
    EDITH_HOSTED_SHELL_JOURNEY: "1",
    EDITH_GUI_FIXTURE_DIRECTORY: directory,
    EDITH_JOURNEY_ACCOUNT_HOME: homedir(),
    HOME: join(directory, "synthetic-data"),
    CFFIXED_USER_HOME: join(directory, "synthetic-data"),
    SSH_AUTH_SOCK: "",
    XDG_CONFIG_HOME: join(directory, "synthetic-data/.config"),
    XDG_CACHE_HOME: join(directory, "synthetic-data/.cache"),
    XDG_DATA_HOME: join(directory, "synthetic-data/.local/share"),
    EDITH_APPLICATION_IDENTIFIER: identifier,
    EDITH_SHARED_DEFAULTS_SUITE: identifier,
    EDITH_EXTENSION_FIXTURE_HOME: join(directory, "synthetic-data"),
    CFFIXED_USER_HOME: join(directory, "synthetic-data"),
    SSH_AUTH_SOCK: "",
  };
  const auditExecutable = join(output, "JourneyProcessAudit");
  execFileSync(
    "xcrun",
    [
      "swiftc",
      "-parse-as-library",
      "-target",
      "arm64-apple-macos14.0",
      "Tests/HostedOriginalShell/Sources/JourneyContract/JourneyContract.swift",
      "Tests/HostedOriginalShell/FixtureSources/ProcessAudit.swift",
      "-o",
      auditExecutable,
    ],
    { stdio: "inherit" },
  );
  const fixture = JSON.parse(
    await readFile(join(directory, "journey.json"), "utf8"),
  );
  assert.equal(fixture.identifier, identifier);
  assert.equal(fixture.sourceCommit, receipt.sourceCommit);
  const replacement = await createJourneyReplacement({
    directory,
    environment: variables,
    accountHome: homedir(),
    fixture,
    audit: async () =>
      JSON.parse(
        execFileSync(auditExecutable, [directory], {
          env: { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", ...variables },
          encoding: "utf8",
          timeout: 10_000,
          maxBuffer: 131_072,
        }),
      ),
  });
  const readState = await createJourneyStateReader({
    directory,
    environment: variables,
    accountHome: homedir(),
    fixture,
  });
  replacementOperator = await startJourneyReplacementOperator(replacement, {
    readState,
  });
  const runnerVariables = journeyRunnerEnvironment({
    ...variables,
    EDITH_JOURNEY_OPERATOR_ENDPOINT: replacementOperator.endpoint,
    EDITH_JOURNEY_OPERATOR_TOKEN: replacementOperator.token,
  });
  const project = await writeUIProject(output, runnerVariables);
  const args = [
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
  ];
  execFileSync("xcodebuild", ["build-for-testing", ...args], {
    stdio: "inherit",
    timeout: 180_000,
  });
  const products = join(derived, "Build/Products");
  const plans = (await readdir(products)).filter((entry) =>
    entry.endsWith(".xctestrun"),
  );
  assert.equal(plans.length, 1);
  const plan = join(products, plans[0]);
  configureUITestRun(plan, runnerVariables);
  let testFailure;
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
        join(output, "HostedShellJourney.xcresult"),
      ],
      { stdio: "inherit" },
    );
  } catch (error) {
    testFailure = error;
  }
  let attachments;
  try {
    attachments = await exportJourneyAttachments({
      resultBundle: join(output, "HostedShellJourney.xcresult"),
      outputDirectory: join(output, "journey-attachments"),
    });
    outcome.attachmentExportDiagnostic = attachments.diagnostic;
    await retainJourneyAttachmentProof(attachments, output);
  } catch (error) {
    outcome.attachmentExportDiagnostic = error.diagnostic;
    outcome.attachmentExportFailed = true;
    outcome.attachmentExportFailure = {
      phase: error.phase ?? "attachment-read",
      category: error.category ?? "invalid-export",
    };
    if (!testFailure) throw error;
  }
  if (testFailure) throw testFailure;
  const currentProcesses = JSON.parse(
    execFileSync(auditExecutable, [directory], {
      env: { ...process.env, ...variables },
      encoding: "utf8",
      timeout: 10_000,
    }),
  );
  assert(Array.isArray(currentProcesses) && currentProcesses.length <= 64);
  assert(
    currentProcesses.every((item) => !item.running),
    "Known owned process generations remained after actual UI shutdown",
  );
  assert(attachments);
  const proof = attachments.proof;
  assert.equal(proof.schema, 1);
  assert.deepEqual(
    proof.snapshots.map((item) => item.stage),
    [
      "empty-idle",
      "recommended-calendar-installed",
      "calendar-native-view",
      "calendar-native-use",
      "home-customized",
      "notch-customized",
      "disabled-drained",
      "reenabled-original-version",
      "replacement-restored-installed-state",
      "updated-calendar-version",
      "updated-disabled-drained",
      "removed-packages",
      "storage-after-removal",
    ],
  );
  assert(
    proof.snapshots.every(
      (item) =>
        item.state.hostIdentifier === identifier &&
        item.state.protectedDataUnchanged === true &&
        item.state.declinedPermissionRequests === 0,
    ),
  );
  const idle = proof.snapshots[0].state.ownedProcesses;
  const enabled = proof.snapshots[2].state.ownedProcesses;
  assert(
    idle.some(
      (item) => item.role === "host" && item.running && item.residentBytes > 0,
    ),
  );
  for (const role of ["engine", "managedUI"])
    assert(
      enabled.some(
        (item) => item.role === role && item.running && item.residentBytes > 0,
      ),
    );
  const final = proof.snapshots.at(-1).state;
  assert.deepEqual(final.workers, {});
  assert.deepEqual(final.presentationCounts, {});
  assert(
    !final.ownedProcesses.some(
      (item) => item.role === "engine" && item.running,
    ),
  );
  outcome = {
    ...outcome,
    outcome: "passed",
    actualJourneyValidated: true,
    sourceCommit: receipt.sourceCommit,
    productionExecutableUnchangedProof: false,
    postQuitProcesses: currentProcesses,
    disabledProcessObservations: validateDisabledJourneyProcesses(proof),
    proof,
  };
  assert.deepEqual(
    attachments.images.map(({ name }) => name).sort(),
    [...journeyImageNames].sort(),
  );
  const images = [];
  for (const image of attachments.images) {
    const bytes = await attachments.readOwned(image.file, image.maximumBytes);
    images.push(validateJourneyImage(image.name, bytes, outcome));
    await writeFile(join(output, image.name), bytes, {
      mode: 0o600,
      flag: "wx",
    });
  }
  outcome.images = images;
} catch (error) {
  failure = error;
  outcome = { ...outcome, reason: "hosted-journey-failed" };
} finally {
  if (replacementOperator) await replacementOperator.close();
  await mkdir(output, { recursive: true });
  for (const name of ["state.json", "journey.json", "producer.json"])
    try {
      const bytes = await readFile(join(directory, name));
      assert(
        bytes.length <= (name === "journey-outcome.json" ? 2_097_152 : 131_072),
      );
      await writeFile(join(output, name), bytes);
    } catch {
      outcome = { ...outcome, diagnosticsIncomplete: true };
    }
  await writeFile(
    join(output, "result.json"),
    JSON.stringify(outcome, null, 2),
  );
  console.log(JSON.stringify(outcome));
}
if (failure) throw failure;
