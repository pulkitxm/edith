import { expect, test } from "bun:test";
import {
  assembleSparkleOutcome,
  cleanupSparkleCaptured,
  observeSparkleNaturalExit,
  sparkleVariables,
} from "./hosted-sparkle-update/run-update.mjs";

function fixture(index) {
  const session = `00000000-0000-4000-8000-00000000000${index}`;
  const directory = `/Users/runner/Applications/Edith Remote Fixture Journey ${session}`;
  return {
    schema: 1,
    session,
    sourceCommit: "a".repeat(40),
    identifier: `com.pulkit.edith.tests.remote-${session}`,
    directory,
    expectedUID: 501,
    initialCodeSHA256: "c".repeat(64),
    installedCodeSHA256: "c".repeat(64),
    initialMetadataSHA256: "1".repeat(64),
    installedMetadataSHA256: "2".repeat(64),
    installedResourcesSHA256: "e".repeat(64),
    signingRequirementSHA256: "f".repeat(64),
    archiveSHA256: "a".repeat(64),
    archiveBytes: 100,
    versions: ["1.0.0", "2.0.0"],
    protectedSHA256: {
      sentinel: "b".repeat(64),
      calendarData: "b".repeat(64),
      homeLayout: "b".repeat(64),
      notchLayout: "b".repeat(64),
      installedSelection: "b".repeat(64),
    },
    ownedRolePaths: {
      engine: `${directory}/Host.app/Contents/MacOS/Edith`,
      managedUI: `${directory}/support/Edith Tests/remote-${session}/Extensions/calendar/edith-host-2/arm64/1.0.0/calendar/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith`,
    },
  };
}
function rows(value, base, updated = false) {
  return ["host", "engine", "managedUI"].map((role, index) => ({
    role,
    pid: base + index,
    birth: `${base + index}.1`,
    uid: 501,
    executable:
      role === "host"
        ? value.ownedRolePaths.engine
        : value.ownedRolePaths[role].replace(
            updated ? "/1.0.0/" : "unused",
            "/1.1.0/",
          ),
    running: true,
  }));
}
function proofs() {
  const value = fixture(1);
  const original = rows(value, 100);
  const reopened = rows(value, 200);
  const resumed = rows(value, 300).slice(0, 2);
  resumed[0] = reopened[0];
  const updated = rows(value, 400, true);
  updated[0] = reopened[0];
  const absent = (values) => values.map((row) => ({ ...row, running: false }));
  const valid = {
    fixture: value,
    original,
    installation: {
      rows: [reopened[0]],
      host: reopened[0],
      old: absent(original),
      application: { signatureVerified: true },
      events: ["downloaded", "extracted", "installing", "relaunching"].map(
        (category) => ({
          schema: 1,
          sourceCommit: value.sourceCommit,
          session: value.session,
          category,
          pid: original[0].pid,
        }),
      ),
    },
    reopened,
    disabled: absent(reopened.slice(1)),
    resumed,
    updated,
    finished: {
      absent: absent(updated.slice(1)),
      removed: ["1.0.0", "1.1.0"],
      naturalDisableValidated: true,
    },
  };
  const negatives = ["wrong-signature", "tampered-archive"].map(
    (recipe, index) => {
      const value = fixture(index + 2);
      const original = rows(value, (index + 5) * 100);
      return {
        fixture: value,
        original,
        negative: {
          recipe,
          actualSparkleRejectionValidated: true,
          events: [
            {
              schema: 1,
              sourceCommit: value.sourceCommit,
              session: value.session,
              category: "rejected",
              pid: original[0].pid,
              errors: [{ domain: "SUSparkleErrorDomain", code: 3001 }],
            },
          ],
          archive: {
            recipe,
            baselineArchiveSHA256: value.archiveSHA256,
            servedArchiveSHA256:
              recipe === "wrong-signature"
                ? value.archiveSHA256
                : "d".repeat(64),
            servedSignatureSHA256: "e".repeat(64),
            actualSparkleRejectionValidated: false,
          },
        },
      };
    },
  );
  return [valid, ...negatives];
}

test("final construction keeps native updated-role drain and two fresh actual rejection cases with same-code full updates", () => {
  const values = proofs();
  const outcome = assembleSparkleOutcome(...values);
  expect(outcome.naturalUpdatedDisableValidated).toBe(true);
  expect(outcome.updatedDisabledRoles.every((row) => !row.running)).toBe(true);
  expect(outcome.oldHost.executableSHA256).toBe(
    outcome.newHost.executableSHA256,
  );
  for (const change of [
    (values) => {
      values[0].finished.naturalDisableValidated = false;
    },
    (values) => {
      values[0].finished.absent[0].running = true;
    },
    (values) => {
      values[0].finished.absent[0].birth = "999.1";
    },
    (values) => {
      values[0].finished.removed = ["1.0.0"];
    },
    (values) => {
      values[0].updated[1] = values[0].resumed[1];
    },
    (values) => {
      values[0].installation.events[0].pid++;
    },
    (values) => {
      values[1].fixture.sourceCommit = "b".repeat(40);
    },
    (values) => {
      values[1].fixture.session = values[0].fixture.session;
    },
    (values) => {
      values[1].negative.events[0].errors[0].code = 3000;
    },
    (values) => {
      values[1].negative.events[0].pid++;
    },
    (values) => {
      values[1].negative.archive.actualSparkleRejectionValidated = true;
    },
    (values) => {
      values[2].negative.archive.servedArchiveSHA256 =
        values[2].fixture.archiveSHA256;
    },
  ]) {
    const changed = proofs();
    change(changed);
    expect(() => assembleSparkleOutcome(...changed)).toThrow();
  }
});

test("normal final host exit is observed without signaling and cannot be forged by zero registry rows", async () => {
  const known = rows(fixture(1), 100);
  let running = true;
  let waits = 0;
  const captured = {
    snapshot: async () => [],
    captured: () => known,
    observe: async (row) => ({ ...row, running }),
  };
  await expect(
    observeSparkleNaturalExit(captured, { attempts: 1, pause: async () => {} }),
  ).rejects.toThrow();
  const observations = await observeSparkleNaturalExit(captured, {
    attempts: 2,
    pause: async () => {
      waits++;
      running = false;
    },
  });
  expect(waits).toBe(1);
  expect(observations).toHaveLength(3);
  expect(observations.every((row) => !row.running)).toBe(true);
  await expect(
    observeSparkleNaturalExit(
      { ...captured, captured: () => [] },
      { attempts: 1, pause: async () => {} },
    ),
  ).rejects.toThrow();
  await expect(
    observeSparkleNaturalExit(
      {
        ...captured,
        observe: async (row) => ({ ...row, birth: "999.1", running: false }),
      },
      { attempts: 1, pause: async () => {} },
    ),
  ).rejects.toThrow();
});

test("a failed refresh still drains previously captured authority and remains a failed refresh", async () => {
  const value = fixture(1);
  const known = rows(value, 100);
  const alive = new Set(known.map((row) => row.pid));
  const signals = [];
  const result = await cleanupSparkleCaptured(
    {
      snapshot: async () => {
        throw Error("Unclassified process");
      },
      captured: () => known,
      observe: async (row) => ({ ...row, running: alive.has(row.pid) }),
      signal: async (row, signal) => {
        signals.push([row.pid, signal]);
        alive.delete(row.pid);
      },
    },
    value,
    { pause: async () => {} },
  );
  expect(result.refreshRejected).toBe(true);
  expect(signals).toEqual([
    [102, "TERM"],
    [101, "TERM"],
    [100, "TERM"],
  ]);
  expect(result.observations.every((row) => !row.running)).toBe(true);
});

test("the runner fixture variables contain no endpoint token or real-account application HOME", () => {
  const value = fixture(1);
  const variables = sparkleVariables(value, "/Users/runner");
  expect(variables.EDITH_GUI_FIXTURE_DIRECTORY).toBe(value.directory);
  expect(variables.EDITH_EXTENSION_FIXTURE_HOME).toBe(
    `${value.directory}/synthetic-data`,
  );
  for (const key of [
    "HOME",
    "CFFIXED_USER_HOME",
    "EDITH_JOURNEY_OPERATOR_TOKEN",
    "EDITH_JOURNEY_OPERATOR_ENDPOINT",
    "SSH_AUTH_SOCK",
  ])
    expect(variables[key]).toBeUndefined();
});
