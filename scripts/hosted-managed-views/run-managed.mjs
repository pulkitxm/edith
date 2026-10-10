import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  cp,
  lstat,
  mkdir,
  readdir,
  readFile,
  realpath,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { extensionFingerprint } from "../extension-release-plan.mjs";
import { loadManagedViewReview } from "./contract.mjs";
import {
  admitManagedExecution,
  parseManagedExecutionArguments,
  validateManagedExecutionResults,
} from "./execution-contract.mjs";
import { prepareFrozenHost } from "./frozen-host.mjs";
import { prepareCIArtifacts } from "./package-preparation.mjs";
import { prepareManagedOwner } from "./prepare-owner.mjs";
import { runManagedOwner } from "./run-owner.mjs";
import { installManagedFixture } from "./store-fixture.mjs";
import {
  managedRunnerEnvironment,
  writeManagedUIProject,
} from "./ui-project.mjs";

const root = await realpath(process.cwd());
const sourceCommit = execFileSync("git", ["rev-parse", "HEAD"], {
  encoding: "utf8",
}).trim();
admitManagedExecution(process.env, sourceCommit);
assert.equal(process.platform, "darwin");
assert.equal(process.arch, "arm64");
const options = parseManagedExecutionArguments(process.argv.slice(2));
const { runOwnedJourneyCommand } = await import(
  "../hosted-original-shell/owned-command.mjs"
);
const accountHome = await realpath(homedir());
const accountStatus = await lstat(accountHome);
assert(
  accountStatus.isDirectory() &&
    accountStatus.uid === process.getuid() &&
    (accountStatus.mode & 0o022) === 0,
);
const applications = join(accountHome, "Applications");
try {
  await mkdir(applications, { mode: 0o700 });
} catch (error) {
  if (error.code !== "EEXIST") throw error;
}
assert.equal(await realpath(applications), applications);
const applicationStatus = await lstat(applications);
assert(
  applicationStatus.isDirectory() &&
    !applicationStatus.isSymbolicLink() &&
    applicationStatus.uid === process.getuid() &&
    (applicationStatus.mode & 0o022) === 0,
);
const output = resolve("local/hosted-managed-execution");
await mkdir(output, { mode: 0o700 });
assert.equal(await realpath(output), output);
const review = await loadManagedViewReview(root);
const definitions = JSON.parse(
  await readFile(join(root, "Extensions/manifest.json")),
);
const fingerprints = {};
for (const definition of definitions)
  fingerprints[definition.id] = await extensionFingerprint(
    root,
    definition,
    definitions,
  );
const hostReceipt = JSON.parse(
  await readFile(
    join(root, "local/hosted-managed-views/host-build-receipt.json"),
  ),
);
assert.equal(hostReceipt.sourceCommit, sourceCommit);
assert.equal(hostReceipt.productionExecutableUnchangedProof, false);
assert.equal(
  hostReceipt.app,
  join(root, "local/hosted-managed-views/frozen/Edith.app"),
);
assert.deepEqual(
  Object.keys(hostReceipt.additions).sort(),
  [
    "WorkerLifecycleFixture.swift",
    "HostedManagedViewRoute.swift",
    "HostedManagedViewRoute+Package.swift",
    "HostedManagedApprovalContract.swift",
    "HostedManagedApprovalHost.swift",
  ].sort(),
);
const identityOutput = execFileSync(
  "security",
  ["find-identity", "-v", "-p", "codesigning"],
  { encoding: "utf8", maxBuffer: 65536 },
);
const identities = [...identityOutput.matchAll(/\b([A-Fa-f0-9]{40})\b/g)].map(
  (match) => match[1],
);
assert.equal(
  identities.length,
  1,
  "Expected one disposable hosted signing identity",
);
const token = process.env.GITHUB_TOKEN;
assert(typeof token === "string" && token.length > 0);
const authenticatedFetch = (url, init = {}) => {
  assert.equal(new URL(url).origin, "https://api.github.com");
  return fetch(url, {
    ...init,
    headers: { ...init.headers, Authorization: `Bearer ${token}` },
  });
};
const fixtures = [],
  results = [];
let failure;
let stage = "original-ci-intake";
try {
  const frozen = await prepareFrozenHost({
    runID: options.runID,
    sourceCommit: options.artifactSource,
    output,
    fetch: authenticatedFetch,
  });
  const originals = await prepareCIArtifacts({
    repository: "pulkitxm/edith",
    runID: options.runID,
    sourceCommit: options.artifactSource,
    definitions,
    fingerprints,
    hostApp: frozen.hostApp,
    hostSHA256: frozen.hostSHA256,
    hostBuildMetadata: frozen.hostBuildMetadata,
    output: join(output, "original-packages"),
    fetch: authenticatedFetch,
  });
  stage = "fixture-transform";
  for (const owner of review.owners) {
    const uuid = randomUUID();
    const directory = join(applications, `Edith Managed Views ${uuid}`);
    const identifier = `com.pulkit.edith.tests.${owner.id === "calendar" ? "remote" : "worker"}-${uuid}`;
    const preparation = await prepareManagedOwner({
      root,
      directory,
      identifier,
      accountHome,
      owner,
      definition: definitions.find(({ id }) => id === owner.id),
      original: originals.originals.find(
        ({ extensionID }) => extensionID === owner.id,
      ),
      sourceHost: hostReceipt.app,
      sourceHostReceipt: hostReceipt,
      identity: identities[0],
      environment: process.env,
    });
    const fixture = await installManagedFixture({ preparation, owner });
    fixtures.push(fixture);
  }
  stage = "approval-test-build";
  const project = await writeManagedUIProject(
    output,
    managedRunnerEnvironment(process.env, fixtures[0]),
  );
  const derived = join(output, "DerivedData");
  await runOwnedJourneyCommand(
    "xcodebuild",
    [
      "build-for-testing",
      "-project",
      project,
      "-scheme",
      "HostedManagedApproval",
      "-destination",
      "platform=macOS,arch=arm64",
      "-derivedDataPath",
      derived,
      "-jobs",
      "1",
      "-parallel-testing-enabled",
      "NO",
    ],
    { stdio: "inherit", timeoutMs: 180000 },
  );
  const products = join(derived, "Build/Products");
  const plans = (await readdir(products)).filter((name) =>
    name.endsWith(".xctestrun"),
  );
  assert.equal(plans.length, 1);
  const auditExecutable = join(output, "HostedManagedProcessAudit");
  execFileSync(
    "xcrun",
    [
      "swiftc",
      "-swift-version",
      "6",
      "-parse-as-library",
      "-target",
      "arm64-apple-macos14.0",
      "Tests/HostedManagedViews/ApprovalSources/HostedManagedApprovalContract.swift",
      "Tests/HostedManagedViews/FixtureSources/HostedManagedProcessAudit.swift",
      "-o",
      auditExecutable,
    ],
    { stdio: "inherit", timeout: 180000 },
  );
  for (const owner of review.owners) {
    stage = `managed-view-${owner.id}`;
    const fixture = fixtures.find(
      ({ extensionID }) => extensionID === owner.id,
    );
    const plan = join(output, `${owner.id}.xctestrun`);
    await cp(join(products, plans[0]), plan, {
      force: false,
      errorOnExist: true,
    });
    execFileSync(
      "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
      ["-f", fixture.app],
      { timeout: 30000, stdio: "pipe" },
    );
    const result = await runManagedOwner({
      fixture,
      owner,
      plan,
      resultBundle: join(output, `${owner.id}.xcresult`),
      auditExecutable,
      environment: process.env,
      runCommand: runOwnedJourneyCommand,
    });
    results.push(result);
    await writeFile(
      join(output, `${owner.id}.json`),
      JSON.stringify(result, null, 2),
      { mode: 0o600, flag: "wx" },
    );
  }
  const aggregate = validateManagedExecutionResults(results, review, fixtures);
  await writeFile(
    join(output, "result.json"),
    JSON.stringify(
      {
        ...aggregate,
        fixtureSourceCommit: sourceCommit,
        originalSourceCommit: options.artifactSource,
        originalCIRun: options.runID,
      },
      null,
      2,
    ),
    { mode: 0o600, flag: "wx" },
  );
  console.log(
    JSON.stringify({
      outcome: "passed",
      owners: 39,
      managedNativeViewSmokeValidated: true,
      functionalActionsValidated: false,
      fixtureSourceCommit: sourceCommit,
      originalSourceCommit: options.artifactSource,
    }),
  );
} catch (error) {
  failure = error;
  await writeFile(
    join(output, "result.json"),
    JSON.stringify(
      {
        schema: 1,
        outcome: "failed",
        stage,
        category: error.name,
        completedOwners: results.map(({ extensionID }) => extensionID),
        fixtureSourceCommit: sourceCommit,
        originalSourceCommit: options.artifactSource,
        managedNativeViewSmokeValidated: false,
        functionalActionsValidated: false,
      },
      null,
      2,
    ),
    { mode: 0o600, flag: "wx" },
  );
}
if (failure) throw failure;
