import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  createSparkleActions,
  validateSparkleEvents,
} from "./hosted-sparkle-update/control.mjs";
import { canonicalSparkleJSON } from "./hosted-sparkle-update/prepare-update.mjs";

function setup(recipe = "valid", attempts = 1) {
  const directory =
    "/Users/runner/Applications/Edith Remote Fixture Journey 00000000-0000-4000-8000-000000000001";
  const fixture = {
    identifier:
      "com.pulkit.edith.tests.remote-00000000-0000-4000-8000-000000000001",
    sourceCommit: "a".repeat(40),
    directory,
    session: "00000000-0000-4000-8000-000000000001",
    expectedUID: 501,
    archiveBytes: 100,
    archiveSHA256: createHash("sha256")
      .update(Buffer.alloc(100, 1))
      .digest("hex"),
    ownedRolePaths: {
      engine: `${directory}/Host.app/Contents/MacOS/Edith`,
      managedUI: `${directory}/support/Edith Tests/remote-00000000-0000-4000-8000-000000000001/Extensions/calendar/edith-host-2/arm64/1.0.0/calendar/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith`,
    },
  };
  const state = {
    hostIdentifier: fixture.identifier,
    sourceCommit: fixture.sourceCommit,
    applicationVersion: "1.0.0",
    protectedDataUnchanged: true,
    declinedPermissionRequests: 0,
    home: { tiles: ["calendar"] },
    notch: { tiles: ["calendar"] },
    active: ["calendar"],
    versions: { calendar: "1.0.0" },
  };
  fixture.protectedSHA256 = Object.fromEntries(
    [
      ["homeLayout", state.home],
      ["notchLayout", state.notch],
      [
        "installedSelection",
        { active: state.active, versions: state.versions },
      ],
    ].map(([key, value]) => [
      key,
      createHash("sha256").update(canonicalSparkleJSON(value)).digest("hex"),
    ]),
  );
  const rows = ["host", "engine", "managedUI"].map((role, index) => ({
    role,
    pid: 100 + index,
    birth: `${index + 1}.2`,
    uid: 501,
    executable:
      role === "host"
        ? `${directory}/Host.app/Contents/MacOS/Edith`
        : fixture.ownedRolePaths[role],
    running: true,
  }));
  const current = {
    rows: structuredClone(rows),
    state,
    events: [],
    absence: false,
    inventory: { applicationSHA256: "1".repeat(64) },
    requests: [],
    catalogWrites: 0,
  };
  const initial = { applicationSHA256: "1".repeat(64) };
  const installed = { applicationSHA256: "2".repeat(64) };
  const actions = createSparkleActions({
    preparation: {
      fixture,
      initial,
      installed,
      archive: Buffer.alloc(100, 1),
      signature: Buffer.alloc(64, 2).toString("base64"),
    },
    captured: {
      snapshot: async () => structuredClone(current.rows),
      observe: async (row) => ({ ...row, running: !current.absence }),
    },
    bindProtected: (value) => value,
    readState: async () => ({ state: current.state }),
    readEvents: async () => current.events,
    inventory: async () => current.inventory,
    switchCatalog: async () => {
      current.catalogWrites++;
    },
    server: {
      observations: () => current.requests,
      recipe: () => {
        const archive = Buffer.alloc(100, 1);
        const signature = Buffer.alloc(64, 2);
        if (recipe === "tampered-archive") archive[99] ^= 1;
        if (recipe === "wrong-signature") signature[0] ^= 1;
        return {
          recipe,
          baselineArchiveSHA256: fixture.archiveSHA256,
          servedArchiveSHA256: createHash("sha256")
            .update(archive)
            .digest("hex"),
          servedSignatureSHA256: createHash("sha256")
            .update(signature)
            .digest("hex"),
          actualSparkleRejectionValidated: false,
        };
      },
    },
    recipe,
    attempts,
    verifyRemoved: async () => ["1.0.0", "1.1.0"],
    pause: async () => {},
  });
  const request = (operation) => ({
    operation,
    hostIdentifier: fixture.identifier,
    sourceCommit: fixture.sourceCommit,
    previousVersion: "1.0.0",
    nextVersion: "2.0.0",
  });
  const events = (categories) =>
    categories.map((category) => ({
      schema: 1,
      sourceCommit: fixture.sourceCommit,
      session: fixture.session,
      pid: 100,
      category,
    }));
  return { actions, request, current, rows, installed, events, fixture };
}

test("full install requires old exits, real delegate sequence, exact installed tree and native new generations before catalog switch", async () => {
  const value = setup();
  await expect(
    value.actions.action(value.request("awaitSparkleInstall")),
  ).rejects.toThrow();
  await value.actions.action(value.request("armSparkle"));
  await expect(
    value.actions.action(value.request("armSparkle")),
  ).rejects.toThrow();
  value.current.absence = true;
  value.current.rows = value.rows.map((row) => ({
    ...row,
    pid: row.pid + 10,
    birth: `${Number(row.birth.split(".")[0]) + 10}.2`,
  }));
  value.current.state.applicationVersion = "2.0.0";
  value.current.events = value.events([
    "downloaded",
    "extracted",
    "installing",
    "relaunching",
  ]);
  value.current.inventory = value.installed;
  value.current.requests = [
    { category: "archive", complete: true, bytes: 100 },
  ];
  value.current.inventory = { ...value.installed, applicationSHA256: "wrong" };
  await expect(
    value.actions.action(value.request("awaitSparkleInstall")),
  ).rejects.toThrow();
  expect(value.current.catalogWrites).toBe(0);
  value.current.inventory = value.installed;
  await value.actions.action(value.request("awaitSparkleInstall"));
  expect(value.current.catalogWrites).toBe(1);
  await value.actions.action(value.request("captureSparkleReopened"));
  value.current.rows = [value.current.rows[0]];
  await value.actions.action(value.request("captureSparkleDisabled"));
  const proof = value.actions.proof();
  expect(proof.installation.old.every((row) => !row.running)).toBe(true);
  expect(proof.reopened).toHaveLength(3);
  expect(proof.disabled.every((row) => !row.running)).toBe(true);
  value.current.rows.push({ ...proof.reopened[1], pid: 121, birth: "21.2" });
  await value.actions.action(value.request("captureSparkleResumed"));
  value.current.state.versions.calendar = "1.1.0";
  value.current.rows.push({
    ...proof.reopened[2],
    pid: 122,
    birth: "22.2",
    executable: value.fixture.ownedRolePaths.managedUI.replace(
      "/1.0.0/",
      "/1.1.0/",
    ),
  });
  await expect(
    value.actions.action(value.request("captureSparkleUpdated")),
  ).rejects.toThrow();
  value.current.rows[1] = { ...value.current.rows[1], pid: 131, birth: "31.2" };
  await value.actions.action(value.request("captureSparkleUpdated"));
  expect(value.actions.proof().updated).toHaveLength(3);
  value.current.rows = [value.current.rows[0]];
  value.current.state.downloaded = [];
  value.current.state.workers = {};
  value.current.state.presentationCounts = {};
  await value.actions.action(value.request("verifySparkleFinished"));
  expect(value.actions.proof().finished.naturalDisableValidated).toBe(true);
});

test("served wrong signature requires actual signature rejection and unchanged app generation and full inventory", async () => {
  const value = setup("wrong-signature");
  await value.actions.action(value.request("armSparkle"));
  value.current.requests = [
    { category: "archive", complete: true, bytes: 100 },
  ];
  value.current.events = value.events(["rejected"]);
  value.current.events[0].errors = [
    { domain: "SUSparkleErrorDomain", code: 2001 },
  ];
  await expect(
    value.actions.action(value.request("verifySparkleRejection")),
  ).rejects.toThrow();
  value.current.events[0].errors[0].code = 3001;
  value.current.rows[0].birth = "99.9";
  await expect(
    value.actions.action(value.request("verifySparkleRejection")),
  ).rejects.toThrow();
  value.current.rows = structuredClone(value.rows);
  await value.actions.action(value.request("verifySparkleRejection"));
  expect(value.actions.proof().negative.actualSparkleRejectionValidated).toBe(
    true,
  );
  expect(value.current.catalogWrites).toBe(0);
});

test("closed event and action schemas reject wrong source, actor generation, arbitrary operations and vacuous downloads", async () => {
  const value = setup("tampered-archive");
  expect(() =>
    validateSparkleEvents(
      [{ ...value.events(["downloaded"])[0], sourceCommit: "b".repeat(40) }],
      value.fixture,
    ),
  ).toThrow();
  await expect(
    value.actions.action({
      ...value.request("armSparkle"),
      operation: "replaceApplication",
    }),
  ).rejects.toThrow();
  await value.actions.action(value.request("armSparkle"));
  value.current.events = value.events(["rejected"]);
  value.current.events[0].errors = [
    { domain: "SUSparkleErrorDomain", code: 3002 },
  ];
  await expect(
    value.actions.action(value.request("verifySparkleRejection")),
  ).rejects.toThrow();
  value.current.requests = [
    { category: "archive", complete: true, bytes: 100 },
  ];
  value.current.events[0].pid = 999;
  await expect(
    value.actions.action(value.request("verifySparkleRejection")),
  ).rejects.toThrow();
  value.current.events[0].pid = 100;
  await value.actions.action(value.request("verifySparkleRejection"));
  expect(value.actions.proof().negative.recipe).toBe("tampered-archive");
});
