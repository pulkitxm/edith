import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import {
  cp,
  lstat,
  mkdir,
  readFile,
  realpath,
  writeFile,
} from "node:fs/promises";
import { join, resolve } from "node:path";
import { requireRegularTree } from "../build-contained-host-runtime.mjs";
import { prepareManagedShippingData } from "../managed-shipping-fixture-data.mjs";

const component = /^[A-Za-z0-9][A-Za-z0-9.-]{0,99}$/;

export function managedStorePaths({ directory, identifier, package_ }) {
  assert.equal(resolve(directory), directory);
  const prefix = `com.pulkit.edith.tests.${package_.id === "calendar" ? "remote" : "worker"}-`;
  assert(identifier.startsWith(prefix));
  assert.match(
    identifier.slice(prefix.length),
    /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/,
  );
  for (const field of ["id", "hostABI", "architecture", "version"])
    assert.match(package_[field], component);
  assert.equal(package_.architecture, "arm64");
  assert.match(package_.version, /^\d{1,8}\.\d{1,8}\.\d{1,8}$/);
  const support =
    package_.id === "calendar" ? join(directory, "support") : directory;
  const identityRoot = join(
    support,
    "Edith Tests",
    identifier.slice("com.pulkit.edith.tests.".length),
  );
  return {
    identityRoot,
    versionDirectory: join(
      identityRoot,
      "Extensions",
      package_.id,
      package_.hostABI,
      package_.architecture,
      package_.version,
    ),
    fixtureHome: join(
      directory,
      package_.id === "calendar" ? "synthetic-data" : `${package_.id}-home`,
    ),
  };
}

export async function installManagedFixture({
  preparation,
  owner,
  execute = execFileSync,
}) {
  const { directory, host, package: originalPackage, payload } = preparation;
  assert.equal(originalPackage.id, owner.id);
  assert.equal(await realpath(directory), directory);
  const status = await lstat(directory);
  assert(
    status.isDirectory() &&
      !status.isSymbolicLink() &&
      status.uid === process.getuid() &&
      (status.mode & 0o7777) === 0o700,
  );
  const paths = managedStorePaths({
    directory,
    identifier: host.identifier,
    package_: originalPackage,
  });
  assert.equal(await realpath(payload), payload);
  assert.equal(payload, join(directory, "transformed", owner.id));
  await requireRegularTree(payload);
  const archive = join(directory, `${owner.id}.fixture.zip`);
  const summary = JSON.parse(
    execute(
      "python3",
      [
        "-c",
        "import json,pathlib,sys,zipfile; root=pathlib.Path(sys.argv[1]); files=sorted(p for p in root.rglob('*') if p.is_file()); z=zipfile.ZipFile(sys.argv[2],'x',zipfile.ZIP_DEFLATED,compresslevel=9); [(z.write(p,p.relative_to(root.parent))) for p in files]; z.close(); z=zipfile.ZipFile(sys.argv[2]); assert z.testzip() is None; print(json.dumps({'installedBytes':sum(p.stat().st_size for p in files),'entries':len(files)}))",
        payload,
        archive,
      ],
      { maxBuffer: 16384, timeout: 120000, stdio: "pipe" },
    ),
  );
  assert(
    Number.isSafeInteger(summary.installedBytes) &&
      summary.installedBytes > 0 &&
      summary.installedBytes <= 8 * 1024 ** 3,
  );
  assert(
    Number.isSafeInteger(summary.entries) &&
      summary.entries > 0 &&
      summary.entries <= 100000,
  );
  const zipStatus = await lstat(archive);
  assert(
    zipStatus.isFile() &&
      !zipStatus.isSymbolicLink() &&
      zipStatus.size > 0 &&
      zipStatus.size <= 8 * 1024 ** 3,
  );
  const hash = createHash("sha256");
  let downloadBytes = 0;
  for await (const chunk of createReadStream(archive)) {
    downloadBytes += chunk.length;
    assert(downloadBytes <= zipStatus.size);
    hash.update(chunk);
  }
  assert.equal(downloadBytes, zipStatus.size);
  const package_ = {
    ...originalPackage,
    sha256: hash.digest("hex"),
    downloadBytes,
    installedBytes: summary.installedBytes,
  };
  await mkdir(paths.versionDirectory, { recursive: true, mode: 0o700 });
  assert.equal(await realpath(paths.versionDirectory), paths.versionDirectory);
  await cp(payload, join(paths.versionDirectory, owner.id), {
    recursive: true,
    dereference: false,
    errorOnExist: true,
    force: false,
  });
  await requireRegularTree(join(paths.versionDirectory, owner.id));
  const entries = JSON.parse(
    await readFile(join(host.app, "Contents/Resources/index.json")),
  );
  const entry = entries.find(({ id }) => id === owner.id);
  assert(entry && entries.filter(({ id }) => id === owner.id).length === 1);
  const route = {
    schema: 1,
    extensionID: owner.id,
    location: owner.location,
    section: owner.section,
    version: package_.version,
    hostABI: package_.hostABI,
    sourceFingerprint: package_.sourceFingerprint,
    packageSHA256: package_.sha256,
    sourceCommit: host.sourceCommit,
    hostIdentifier: host.identifier,
    directory,
    factoryOverlay: owner.factoryOverlay,
  };
  for (const [name, value] of [
    ["selected-package.json", package_],
    ["managed-shipping-fixture.json", [entry]],
    ["managed-route.json", route],
  ])
    await writeFile(join(directory, name), JSON.stringify(value), {
      flag: "wx",
      mode: 0o600,
    });
  if (owner.id === "calendar")
    await prepareManagedShippingData({
      directory,
      identifier: host.identifier,
      package_,
    });
  else await mkdir(paths.fixtureHome, { mode: 0o700 });
  for (const path of [paths.fixtureHome, join(directory, "xdg")]) {
    if (path.endsWith("/xdg")) await mkdir(path, { mode: 0o700 });
    assert.equal(await realpath(path), path);
    assert.equal((await lstat(path)).mode & 0o7777, 0o700);
  }
  const result = {
    schema: 1,
    directory,
    identifier: host.identifier,
    extensionID: owner.id,
    app: host.app,
    executable: join(host.app, "Contents/MacOS/Edith"),
    archive,
    package: package_,
    fixtureHome: paths.fixtureHome,
    identityRoot: paths.identityRoot,
    route,
    sourceCommit: host.sourceCommit,
    originalSourceCommit: preparation.originalSourceCommit,
    originalZipSHA256: preparation.originalZipSHA256,
    fixtureZipCRCVerified: true,
    signedCatalogPayload: false,
    productionExecutableUnchangedProof: false,
    managedNativeViewValidated: false,
    functionalActionsValidated: false,
  };
  await writeFile(join(directory, "fixture.json"), JSON.stringify(result), {
    flag: "wx",
    mode: 0o600,
  });
  return result;
}
