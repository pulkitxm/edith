import assert from "node:assert/strict";
import { lstat, mkdir, open, realpath } from "node:fs/promises";
import { join } from "node:path";

export async function prepareManagedShippingData({
  directory,
  identifier,
  package_,
}) {
  assert.equal(
    package_.id,
    "calendar",
    "No admitted synthetic backend is configured for this provider",
  );
  assert.match(
    identifier,
    /^com\.pulkit\.edith\.tests\.remote-[a-z0-9-]{1,60}$/,
  );
  assert.equal(await realpath(directory), directory);
  assert.match(package_.hostABI, /^[a-zA-Z0-9.-]{1,100}$/);
  assert.equal(package_.architecture, "arm64");
  assert.match(package_.version, /^\d{1,8}\.\d{1,8}\.\d{1,8}$/);
  const root = join(
    directory,
    "support/Edith Tests",
    identifier.slice("com.pulkit.edith.tests.".length),
  );
  const dataDirectory = join(root, "Data/calendar");
  const packageDirectory = join(
    root,
    "Extensions/calendar",
    package_.hostABI,
    package_.architecture,
    package_.version,
    "calendar",
  );
  assert.equal(await realpath(packageDirectory), packageDirectory);
  const fixtureHome = join(directory, "synthetic-data");
  for (const path of [fixtureHome, dataDirectory]) {
    await mkdir(path, { recursive: true, mode: 0o700 });
    const status = await lstat(path);
    assert(status.isDirectory() && !status.isSymbolicLink());
    assert.equal(status.uid, process.getuid());
    assert.equal(await realpath(path), path);
  }
  assert.equal((await lstat(fixtureHome)).mode & 0o777, 0o700);
  const marker = {
    schema: 1,
    hostIdentifier: identifier,
    dataDirectory,
    packageDirectory,
  };
  const markerPath = join(fixtureHome, "calendar-fixture.json");
  try {
    const handle = await open(markerPath, "wx", 0o600);
    try {
      await handle.writeFile(JSON.stringify(marker));
    } finally {
      await handle.close();
    }
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    const status = await lstat(markerPath);
    assert(status.isFile() && !status.isSymbolicLink());
    assert.equal(status.uid, process.getuid());
    assert.equal(status.mode & 0o777, 0o600);
    assert(status.size <= 16_384);
    const handle = await open(markerPath, "r");
    try {
      const buffer = Buffer.alloc(16_385);
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      assert(bytesRead <= 16_384);
      assert.deepEqual(JSON.parse(buffer.subarray(0, bytesRead)), marker);
    } finally {
      await handle.close();
    }
  }
  return { fixtureHome, marker };
}
