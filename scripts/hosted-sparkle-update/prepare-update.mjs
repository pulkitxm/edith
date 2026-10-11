import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, createPublicKey, sign } from "node:crypto";
import {
  chmod,
  lstat,
  mkdir,
  readdir,
  readFile,
  readlink,
  realpath,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";
import {
  copyJourneyApplication,
  prepareJourney,
} from "../hosted-original-shell/prepare-journey.mjs";
import { sparkleURL, validateSparkleFixture } from "./contract.mjs";

export const sparkleLoopbackTransport = Object.freeze({
  NSExceptionDomains: {
    "127.0.0.1": { NSExceptionAllowsInsecureHTTPLoads: true },
  },
});
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
export function canonicalSparkleJSON(value) {
  const order = (entry) =>
    Array.isArray(entry)
      ? entry.map(order)
      : entry && typeof entry === "object"
        ? Object.fromEntries(
            Object.keys(entry)
              .sort()
              .map((key) => [key, order(entry[key])]),
          )
        : entry;
  return Buffer.from(JSON.stringify(order(value)));
}

export function createSparkleDescriptor(
  {
    session,
    sourceCommit,
    identifier,
    directory,
    port,
    updatePublicKey,
    producer,
  },
  issuer,
) {
  const payload = canonicalSparkleJSON({
    schema: 1,
    session,
    sourceCommit,
    identifier,
    directory,
    port,
    updatePublicKey,
    producer,
  });
  assert(payload.length <= 8192);
  return canonicalSparkleJSON({
    payload: payload.toString("base64"),
    signature: sign(null, payload, issuer).toString("base64"),
  });
}

export async function sparkleResourceInventory(directory) {
  const root = await realpath(directory);
  assert.equal(root, directory);
  const entries = [];
  async function visit(path, relative) {
    const info = await lstat(path);
    assert.equal(info.uid, process.getuid());
    if (info.isSymbolicLink()) {
      const target = await readlink(path);
      assert(!target.startsWith("/") && !/[\0\r\n]/.test(target));
      const actual = await realpath(path);
      assert(actual.startsWith(`${root}/`));
      entries.push([relative, "symlink", target]);
    } else if (info.isDirectory()) {
      assert.equal(info.mode & 0o022, 0);
      for (const name of (await readdir(path)).sort())
        await visit(join(path, name), relative ? `${relative}/${name}` : name);
    } else {
      assert.equal(info.mode & 0o022, 0);
      assert(info.isFile() && info.nlink === 1);
      entries.push([relative, "file", info.size, hash(await readFile(path))]);
    }
  }
  await visit(root, "");
  return { entries, sha256: hash(canonicalSparkleJSON(entries)) };
}

export async function inventorySparkleApp(
  app,
  { identifier, version, requirement, execute = execFileSync },
) {
  assert.equal(await realpath(app), app);
  const infoBytes = await readFile(join(app, "Contents/Info.plist"));
  const info = JSON.parse(
    execute(
      "python3",
      [
        "-c",
        "import json,plistlib,sys; print(json.dumps(plistlib.load(open(sys.argv[1],'rb'))))",
        join(app, "Contents/Info.plist"),
      ],
      { encoding: "utf8", timeout: 5000 },
    ),
  );
  assert.equal(info.CFBundleIdentifier, identifier);
  assert.equal(info.CFBundleExecutable, "Edith");
  assert.equal(info.CFBundlePackageType, "APPL");
  assert.equal(info.CFBundleShortVersionString, version);
  assert.equal(info.CFBundleVersion, version === "1.0.0" ? "1" : "2");
  assert.deepEqual(info.NSAppTransportSecurity, sparkleLoopbackTransport);
  assert.equal(info.SUVerifyUpdateBeforeExtraction, true);
  execute("codesign", ["--verify", "--deep", "--strict", app], {
    stdio: "pipe",
    timeout: 10000,
  });
  execute("codesign", ["--verify", "--strict", "-R", requirement, app], {
    stdio: "pipe",
    timeout: 10000,
  });
  const resources = await sparkleResourceInventory(
    join(app, "Contents/Resources"),
  );
  const application = await sparkleResourceInventory(app);
  return {
    executableSHA256: hash(await readFile(join(app, "Contents/MacOS/Edith"))),
    metadataSHA256: hash(infoBytes),
    resourcesSHA256: resources.sha256,
    resources: resources.entries,
    applicationSHA256: application.sha256,
    application: application.entries,
    signatureVerified: true,
    signingRequirementSHA256: hash(requirement),
  };
}

export async function prepareSparkleUpdate({
  root,
  buildReceipt,
  session,
  directory,
  identifier,
  port,
  issuer,
  updateKeys,
  producer,
  signingIdentity,
  requirement,
  accountHome,
  execute = execFileSync,
}) {
  assert.equal(process.env.EDITH_HOSTED_SPARKLE_UPDATE, "1");
  assert.equal(process.env.GITHUB_SHA, buildReceipt.sourceCommit);
  assert.equal(
    createPublicKey(issuer)
      .export({ format: "der", type: "spki" })
      .subarray(-32)
      .toString("base64"),
    buildReceipt.issuerPublicKey,
  );
  assert.equal(hash(requirement), buildReceipt.signingRequirementSHA256);
  assert.equal(session.length, 36);
  assert.equal(identifier, `com.pulkit.edith.tests.remote-${session}`);
  assert.equal(producer.pid, process.pid);
  assert.equal(producer.uid, process.getuid());
  assert.equal(producer.executable, await realpath(process.execPath));
  assert.equal(
    producer.executableSHA256,
    hash(await readFile(producer.executable)),
  );
  assert.equal(
    requirement,
    `identifier "${identifier}" and certificate leaf = H"${signingIdentity}"`,
  );
  assert(
    /^[A-F0-9]{40}$/.test(signingIdentity) && signingIdentity.length === 40,
  );
  const journey = await prepareJourney({
    root,
    directory,
    identifier,
    frozenHost: buildReceipt.frozenHost,
    sourceCommit: buildReceipt.sourceCommit,
    executableSHA256: buildReceipt.fixtureExecutableSHA256,
  });
  const publicKey = updateKeys.publicKey
    .export({ format: "der", type: "spki" })
    .subarray(-32)
    .toString("base64");
  const descriptor = createSparkleDescriptor(
    {
      session,
      sourceCommit: buildReceipt.sourceCommit,
      identifier,
      directory,
      port,
      updatePublicKey: publicKey,
      producer,
    },
    issuer,
  );
  await writeFile(join(directory, "sparkle-bootstrap.json"), descriptor, {
    mode: 0o600,
    flag: "wx",
  });
  const applications = [
    join(directory, "Host.app"),
    join(directory, "replacement/Host.payload"),
  ];
  for (const path of ["tmp", "synthetic-data/.local"])
    await mkdir(join(directory, path), { mode: 0o700 }).catch((error) =>
      assert.equal(error.code, "EEXIST"),
    );
  for (const app of applications) {
    const infoPath = join(app, "Contents/Info.plist");
    const info = JSON.parse(
      execute(
        "python3",
        [
          "-c",
          "import json,plistlib,sys; print(json.dumps(plistlib.load(open(sys.argv[1],'rb'))))",
          infoPath,
        ],
        { encoding: "utf8" },
      ),
    );
    info.SUPublicEDKey = publicKey;
    info.SUFeedURL = sparkleURL({ session, port }, "appcast.xml");
    info.NSAppTransportSecurity = sparkleLoopbackTransport;
    info.SUEnableAutomaticChecks = false;
    info.SUAutomaticallyUpdate = false;
    info.SUVerifyUpdateBeforeExtraction = true;
    info.SUScheduledCheckInterval = 86400;
    execute(
      "python3",
      [
        "-c",
        "import json,plistlib,sys; plistlib.dump(json.loads(sys.argv[1]),open(sys.argv[2],'wb'))",
        JSON.stringify(info),
        infoPath,
      ],
      { stdio: "pipe" },
    );
    const seal = join(app, "Contents/Resources/hosted-sparkle-fixture.json");
    await writeFile(seal, descriptor, { mode: 0o600, flag: "wx" });
    await chmod(seal, 0o600);
    execute(
      "codesign",
      [
        "--force",
        "--sign",
        signingIdentity,
        "--timestamp=none",
        "--options",
        "runtime",
        app,
      ],
      { stdio: "pipe", timeout: 10000 },
    );
  }
  const initial = await inventorySparkleApp(applications[0], {
    identifier,
    version: "1.0.0",
    requirement,
    execute,
  });
  const installed = await inventorySparkleApp(applications[1], {
    identifier,
    version: "2.0.0",
    requirement,
    execute,
  });
  journey.executableSHA256 = {
    "1.0.0": initial.executableSHA256,
    "2.0.0": installed.executableSHA256,
  };
  await writeFile(join(directory, "journey.json"), JSON.stringify(journey), {
    mode: 0o600,
  });
  const stage = join(directory, "sparkle-archive");
  await mkdir(stage, { mode: 0o700 });
  await copyJourneyApplication(applications[1], join(stage, "Host.app"));
  const archivePath = join(directory, "sparkle-update.zip");
  execute(
    "/usr/bin/ditto",
    [
      "-c",
      "-k",
      "--sequesterRsrc",
      "--keepParent",
      join(stage, "Host.app"),
      archivePath,
    ],
    { stdio: "pipe", timeout: 30000 },
  );
  await chmod(archivePath, 0o600);
  const archive = await readFile(archivePath);
  const fixture = {
    schema: 1,
    session,
    sourceCommit: journey.sourceCommit,
    identifier,
    directory,
    publicKey,
    port,
    archiveSHA256: hash(archive),
    archiveBytes: archive.length,
    versions: ["1.0.0", "2.0.0"],
    producer,
    expectedUID: producer.uid,
    initialCodeSHA256: initial.executableSHA256,
    installedCodeSHA256: installed.executableSHA256,
    initialMetadataSHA256: initial.metadataSHA256,
    installedMetadataSHA256: installed.metadataSHA256,
    installedResourcesSHA256: installed.resourcesSHA256,
    signingRequirementSHA256: installed.signingRequirementSHA256,
    protectedSHA256: {
      sentinel: Object.values(journey.protectedSHA256)[0],
      calendarData: Object.values(journey.protectedSHA256)[1],
    },
    ownedRolePaths: {
      engine: `${directory}/Host.app/Contents/MacOS/Edith`,
      managedUI: `${directory}/support/Edith Tests/remote-${session}/Extensions/calendar/edith-host-2/arm64/1.0.0/calendar/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith`,
    },
  };
  assert.equal(
    directory,
    `${accountHome}/Applications/Edith Remote Fixture Journey ${session}`,
  );
  return {
    fixture,
    journey,
    initial,
    installed,
    archive,
    signature: sign(null, archive, updateKeys.privateKey).toString("base64"),
  };
}

export function bindSparkleProtectedState(
  fixture,
  state,
  environment,
  accountHome,
) {
  assert.equal(state.hostIdentifier, fixture.identifier);
  assert.equal(state.sourceCommit, fixture.sourceCommit);
  assert.equal(state.applicationVersion, "1.0.0");
  assert.equal(state.protectedDataUnchanged, true);
  assert.equal(state.declinedPermissionRequests, 0);
  assert.deepEqual(state.versions, { calendar: "1.0.0" });
  assert.deepEqual(state.active, ["calendar"]);
  for (const key of ["home", "notch"])
    assert(state[key] && typeof state[key] === "object");
  return validateSparkleFixture(
    {
      ...fixture,
      protectedSHA256: {
        ...fixture.protectedSHA256,
        homeLayout: hash(canonicalSparkleJSON(state.home)),
        notchLayout: hash(canonicalSparkleJSON(state.notch)),
        installedSelection: hash(
          canonicalSparkleJSON({
            active: state.active,
            versions: state.versions,
          }),
        ),
      },
    },
    environment,
    accountHome,
  );
}
