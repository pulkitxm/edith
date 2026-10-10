import assert from "node:assert/strict";
import { lstat, readFile, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const stages = new Set([
  "argv-received",
  "argv-admission",
  "fixture-validation",
  "host-registration",
  "approval-loop",
  "carrier-requested",
  "carrier-check-in",
  "carrier-timeout",
  "browser-created",
  "browser-visible",
  "public-discovery",
  "public-identity",
  "approval-timeout",
  "terminated",
  "diagnostic-write",
]);
const names = [
  "probe-startup.json",
  "approval-failure.json",
  "approval-ready.json",
  "public-identity.json",
];

export async function collectProbeDiagnostics({
  directory,
  identifier,
  home = homedir(),
}) {
  const uuid = identifier.slice("com.pulkit.edith.tests.remote-".length);
  assert.match(
    identifier,
    /^com\.pulkit\.edith\.tests\.remote-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/,
  );
  assert.equal(
    directory,
    join(home, "Applications", `Edith Remote Fixture Hosted ${uuid}`),
  );
  assert.equal(await realpath(directory), directory);
  const records = [];
  for (const name of names) {
    const path = join(directory, name);
    try {
      const info = await lstat(path);
      assert(info.isFile() && !info.isSymbolicLink() && info.size <= 16_384);
      const data = await readFile(path);
      assert(data.byteLength <= 16_384);
      const value = JSON.parse(data.toString("utf8"));
      assert(value && typeof value === "object" && !Array.isArray(value));
      assert.equal(value.hostIdentifier, identifier);
      const allowed = new Set([
        "hostIdentifier",
        "outcome",
        "stage",
        "argumentCount",
        "extraArgumentCount",
        "publicBrowser",
        "expectedLabel",
        "workerIdentifier",
        "extensionPointIdentifier",
        "identity",
        "publicDiscovery",
        "applicationReturned",
        "carrierPathMatched",
        "errorDomain",
        "errorCode",
        "contractFailure",
      ]);
      assert(Object.keys(value).every((key) => allowed.has(key)));
      if (value.stage !== undefined) assert(stages.has(value.stage));
      if (value.outcome !== undefined)
        assert(["started", "failed", "terminated"].includes(value.outcome));
      for (const key of ["argumentCount", "extraArgumentCount"])
        if (value[key] !== undefined)
          assert(
            Number.isInteger(value[key]) &&
              value[key] >= 0 &&
              value[key] <= 128,
          );
      for (const key of [
        "publicBrowser",
        "publicDiscovery",
        "applicationReturned",
        "carrierPathMatched",
      ])
        if (value[key] !== undefined)
          assert.equal(typeof value[key], "boolean");
      if (value.expectedLabel !== undefined)
        assert.equal(value.expectedLabel, "Edith calendar");
      if (value.workerIdentifier !== undefined)
        assert.equal(
          value.workerIdentifier,
          `${identifier}.extension.calendar.worker`,
        );
      if (value.extensionPointIdentifier !== undefined)
        assert.equal(
          value.extensionPointIdentifier,
          `${identifier}.ExtensionUI`,
        );
      if (value.identity !== undefined)
        assert(
          typeof value.identity === "string" &&
            value.identity.length <= 256 &&
            !/[\0\r\n]/.test(value.identity),
        );
      if (value.errorCode !== undefined)
        assert(Number.isSafeInteger(value.errorCode));
      for (const key of ["errorDomain", "contractFailure"])
        if (value[key] !== undefined)
          assert(
            typeof value[key] === "string" &&
              /^[A-Za-z0-9.-]{1,128}$/.test(value[key]),
          );
      records.push({ name, status: "observed", value });
    } catch (error) {
      records.push({
        name,
        status: error.code === "ENOENT" ? "missing" : "invalid",
      });
    }
  }
  return { schemaVersion: 1, hostIdentifier: identifier, records };
}
