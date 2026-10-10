import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, createReadStream, openSync } from "node:fs";
import { mkdir, readFile, unlink } from "node:fs/promises";
import { join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { validateManagedNativeProof } from "./extension-worker-proof.mjs";

const [directory_] = process.argv.slice(2);
assert(directory_, "Usage: test-managed-shipping-ui.mjs fixture-directory");
const directory = resolve(directory_);
const fixture = JSON.parse(
  await readFile(join(directory, "fixture.json"), "utf8"),
);
assert.equal(fixture.directory, directory);
assert.match(fixture.identifier, /^com\.pulkit\.edith\.tests\.remote-/);
assert.equal(fixture.backgroundOnly, true);
const package_ = JSON.parse(
  await readFile(join(directory, "selected-package.json"), "utf8"),
);
assert.equal(fixture.extensionID, package_.id);
assert.equal(fixture.version, package_.version);
assert.equal(fixture.hostABI, package_.hostABI);
const hash = createHash("sha256");
let bytes = 0;
for await (const chunk of createReadStream(fixture.archive)) {
  bytes += chunk.length;
  assert(bytes <= package_.downloadBytes);
  hash.update(chunk);
}
assert.equal(bytes, package_.downloadBytes);
assert.equal(hash.digest("hex"), package_.sha256);
const resultFile = join(directory, "result-managed-shipping.json");
await unlink(resultFile).catch((error) => {
  if (error.code !== "ENOENT") throw error;
});
await mkdir(join(directory, "synthetic-data"), {
  recursive: true,
  mode: 0o700,
});
const trace = openSync(join(directory, "managed-shipping-trace.log"), "w");
const child = spawn(
  fixture.executable,
  ["--extension-remote-registration-fixture", directory],
  {
    stdio: ["ignore", trace, trace],
    env: {
      ...process.env,
      EDITH_REMOTE_OFFSCREEN_FIXTURE: "0",
      EDITH_REMOTE_RETAINED_NEGATIVE: "0",
      EDITH_REMOTE_UNCONNECTED_CLEANUP: "0",
      EDITH_EXTENSION_FIXTURE_HOME: join(directory, "synthetic-data"),
    },
  },
);
closeSync(trace);
let launchError;
child.on("error", (error) => {
  launchError = error;
});
try {
  let result;
  const deadline = Date.now() + 90_000;
  while (Date.now() < deadline) {
    if (launchError) throw launchError;
    try {
      result = JSON.parse(await readFile(resultFile, "utf8"));
      break;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await sleep(50);
  }
  assert(result, "Managed original-view fixture timed out");
  const exitDeadline = Date.now() + 5000;
  while (
    child.exitCode === null &&
    child.signalCode === null &&
    Date.now() < exitDeadline
  )
    await sleep(20);
  assert.equal(
    child.exitCode,
    0,
    "The owned fixture host did not exit cleanly",
  );
  validateManagedNativeProof(result, package_);
  console.log(
    JSON.stringify({
      ...result,
      sha256: package_.sha256,
      sourceFingerprint: package_.sourceFingerprint,
    }),
  );
} finally {
  if (child.exitCode === null && child.signalCode === null)
    child.kill("SIGTERM");
}
