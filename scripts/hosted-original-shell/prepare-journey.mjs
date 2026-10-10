import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, createPrivateKey, sign } from "node:crypto";
import {
  chmod,
  cp,
  lstat,
  mkdir,
  readdir,
  readFile,
  realpath,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { buildExtensionPackage } from "../build-extension-package.mjs";
import { extensionUIExtensionPoint } from "../build-extension-ui-carrier.mjs";

export function admitHostedJourney(
  environment,
  directory,
  identifier,
  accountHome,
) {
  for (const [key, value] of Object.entries({
    GITHUB_ACTIONS: "true",
    RUNNER_OS: "macOS",
    RUNNER_ENVIRONMENT: "github-hosted",
    EDITH_HOSTED_SHELL_JOURNEY: "1",
  }))
    assert.equal(
      environment[key],
      value,
      "Only an owned disposable hosted runner is admitted",
    );
  const prefix = "com.pulkit.edith.tests.remote-";
  assert(identifier.startsWith(prefix));
  const uuid = identifier.slice(prefix.length);
  assert.match(
    uuid,
    /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/,
  );
  assert.equal(
    directory,
    join(accountHome, "Applications", `Edith Remote Fixture Journey ${uuid}`),
  );
  assert.equal(directory, resolve(directory));
}

export async function prepareJourneyParent({
  environment,
  directory,
  identifier,
  accountHome,
  uid = process.getuid(),
}) {
  admitHostedJourney(environment, directory, identifier, accountHome);
  const verify = async (path) => {
    const info = await lstat(path);
    assert(info.isDirectory() && !info.isSymbolicLink());
    assert.equal(info.uid, uid);
    assert.equal(info.mode & 0o022, 0);
    assert.equal(await realpath(path), path);
    return info;
  };
  const before = await verify(accountHome);
  const applications = join(accountHome, "Applications");
  try {
    await lstat(applications);
  } catch (error) {
    assert.equal(error.code, "ENOENT");
    await mkdir(applications, { mode: 0o700 });
  }
  await verify(applications);
  const after = await verify(accountHome);
  assert.equal(before.dev, after.dev);
  assert.equal(before.ino, after.ino);
  return applications;
}

export function journeyEnvelope(packages, revision) {
  assert([1, 2].includes(revision));
  assert(packages.length === revision);
  const payload = Buffer.from(
    JSON.stringify({ schemaVersion: 1, revision, packages }),
  );
  const privateKey = createPrivateKey({
    key: Buffer.concat([
      Buffer.from("302e020100300506032b657004220420", "hex"),
      Buffer.alloc(32, 90),
    ]),
    format: "der",
    type: "pkcs8",
  });
  return {
    payload: payload.toString("base64"),
    signature: sign(null, payload, privateKey).toString("base64"),
  };
}

export async function prepareJourney({
  root,
  directory,
  identifier,
  frozenHost,
  sourceCommit,
  executableSHA256: expectedExecutableSHA256,
}) {
  admitHostedJourney(process.env, directory, identifier, homedir());
  assert.equal(process.arch, "arm64");
  assert.match(sourceCommit, /^[a-f0-9]{40}$/);
  const run = (command, args) => execFileSync(command, args, { stdio: "pipe" });
  const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
  assert.match(expectedExecutableSHA256, /^[a-f0-9]{64}$/);
  assert.equal(
    hash(await readFile(join(frozenHost, "Contents/MacOS/Edith"))),
    expectedExecutableSHA256,
  );
  const identities =
    run("security", ["find-identity", "-v", "-p", "codesigning"])
      .toString()
      .match(/\b[0-9A-F]{40}\b/g) ?? [];
  assert.equal(
    identities.length,
    1,
    "A single owned hosted signing identity is required",
  );
  const identity = identities[0];
  const signPath = (path) =>
    run("codesign", [
      "--force",
      "--sign",
      identity,
      "--timestamp=none",
      "--options",
      "runtime",
      path,
    ]);
  const plist = (path, value) =>
    run("python3", [
      "-c",
      "import json,plistlib,sys; plistlib.dump(json.loads(sys.argv[1]),open(sys.argv[2],'wb'))",
      JSON.stringify(value),
      path,
    ]);
  const info = (path) =>
    JSON.parse(
      run("python3", [
        "-c",
        "import json,plistlib,sys; print(json.dumps(plistlib.load(open(sys.argv[1],'rb'))))",
        path,
      ]).toString(),
    );
  async function signRuntime(path) {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      const child = join(path, entry.name);
      if (entry.isDirectory()) await signRuntime(child);
      else if (
        entry.isFile() &&
        run("file", ["-b", child]).toString().includes("Mach-O")
      )
        signPath(child);
    }
    if (/\.(framework|app|xpc)$/.test(path)) signPath(path);
  }
  await prepareJourneyParent({
    environment: process.env,
    directory,
    identifier,
    accountHome: homedir(),
  });
  await mkdir(directory, { recursive: false, mode: 0o700 });
  await chmod(directory, 0o700);
  assert.equal(await realpath(directory), directory);
  const app = join(directory, "Host.app");
  await cp(frozenHost, app, {
    recursive: true,
    force: false,
    errorOnExist: true,
  });
  const appInfo = info(join(app, "Contents/Info.plist"));
  plist(join(app, "Contents/Info.plist"), {
    ...appInfo,
    CFBundleIdentifier: identifier,
    CFBundleName: "Edith",
    CFBundleDisplayName: "Edith",
    CFBundleShortVersionString: "1.0.0",
    CFBundleVersion: "1",
  });
  plist(
    join(app, "Contents/Extensions/ExtensionUI.appextensionpoints"),
    extensionUIExtensionPoint(identifier),
  );
  await signRuntime(join(app, "Contents/Frameworks"));
  signPath(app);
  run("codesign", ["--verify", "--deep", "--strict", app]);
  const executableSHA256 = {
    "1.0.0": hash(await readFile(join(app, "Contents/MacOS/Edith"))),
  };
  const replacement = join(directory, "replacement/Host.payload");
  await mkdir(dirname(replacement), { recursive: true, mode: 0o700 });
  await cp(app, replacement, { recursive: true });
  plist(join(replacement, "Contents/Info.plist"), {
    ...info(join(replacement, "Contents/Info.plist")),
    CFBundleShortVersionString: "2.0.0",
    CFBundleVersion: "2",
  });
  signPath(replacement);
  run("codesign", ["--verify", "--deep", "--strict", replacement]);
  executableSHA256["2.0.0"] = hash(
    await readFile(join(replacement, "Contents/MacOS/Edith")),
  );
  const uuid = identifier.slice("com.pulkit.edith.tests.remote-".length);
  const protectedFiles = {
    "production-sentinel/usage.json": Buffer.from(
      '{"synthetic":true,"tokens":73,"project":"Protected fixture"}\n',
    ),
    [`support/Edith Tests/remote-${uuid}/Data/calendar/retained-fixture.json`]:
      Buffer.from(
        '{"synthetic":true,"selectedCalendar":"Retained fixture","note":"Keep these exact bytes"}\n',
      ),
  };
  for (const [path, bytes] of Object.entries(protectedFiles)) {
    await mkdir(dirname(join(directory, path)), {
      recursive: true,
      mode: 0o700,
    });
    await writeFile(join(directory, path), bytes, { mode: 0o600 });
  }
  for (const path of [
    "synthetic-data",
    "support",
    "downloads",
    "archives",
    "synthetic-data/.config",
    "synthetic-data/.cache",
    "synthetic-data/.local/share",
  ])
    await mkdir(join(directory, path), { recursive: true, mode: 0o700 });
  const packages = [];
  const previous = process.env.EXTENSION_SIGN_IDENTITY;
  try {
    process.env.EXTENSION_SIGN_IDENTITY = identity;
    for (const version of ["1.0.0", "1.1.0"]) {
      const output = join(directory, `built-${version}`);
      await buildExtensionPackage({
        root,
        id: "calendar",
        output,
        development: false,
        version,
        containedHostApp: app,
      });
      const package_ = JSON.parse(
        await readFile(join(output, "calendar.json"), "utf8"),
      );
      assert.equal(package_.id, "calendar");
      assert.equal(package_.version, version);
      assert.equal(package_.architecture, "arm64");
      assert.deepEqual(package_.dependencies, []);
      const archive = await readFile(join(output, "calendar.zip"));
      assert.equal(hash(archive), package_.sha256);
      assert.equal(archive.length, package_.downloadBytes);
      await writeFile(
        join(directory, `archives/calendar-${version}.zip`),
        archive,
        { mode: 0o600 },
      );
      packages.push(package_);
    }
  } finally {
    if (previous === undefined) delete process.env.EXTENSION_SIGN_IDENTITY;
    else process.env.EXTENSION_SIGN_IDENTITY = previous;
  }
  const fixture = {
    schema: 1,
    identifier,
    directory,
    sourceCommit,
    executableSHA256,
    versions: ["1.0.0", "1.1.0"],
    appVersions: ["1.0.0", "2.0.0"],
    protectedSHA256: Object.fromEntries(
      Object.entries(protectedFiles).map(([path, bytes]) => [
        path,
        hash(bytes),
      ]),
    ),
  };
  for (const [name, value] of Object.entries({
    "journey.json": fixture,
    "packages.json": packages,
    "active-catalog.json": journeyEnvelope(packages.slice(0, 1), 1),
    "updated-catalog.json": journeyEnvelope(packages, 2),
  }))
    await writeFile(join(directory, name), JSON.stringify(value), {
      mode: 0o600,
    });
  return fixture;
}
