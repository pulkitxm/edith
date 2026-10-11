import assert from "node:assert/strict";
import test from "node:test";
import { definition } from "./cases/keepAwake.mjs";
import { functionalDigest } from "./contract.mjs";
import {
  admitFunctionalBuildArtifact,
  FunctionalJourneyOrder,
  functionalPresentationID,
  runFunctionalPool,
} from "./controller.mjs";

const session = "12345678-1234-4123-8123-123456789abc";
const root = `/private/synthetic/functional-fixture-${session}`;
const birth = (pid, generation) => ({
  pid,
  birthSeconds: 1000 + generation,
  birthMicroseconds: pid,
  uid: 501,
  executableSHA256: "a".repeat(64),
});
const capability = (phase, generation) => ({
  schema: 1,
  sourceCommit: "a".repeat(40),
  session,
  owner: "keepAwake",
  uid: 501,
  fixtureRoot: root,
  hostIdentifier: `com.pulkit.edith.tests.worker-${session}`,
  home: `${root}/keepAwake-home`,
  dataDirectory: `${root}/Edith Tests/worker-${session}/Data/keepAwake`,
  hostABI: "edith-host-2",
  caseSHA256: functionalDigest(definition),
  activationOperation: definition.activation.operation,
  phase,
  pairScope: "synthetic-development",
  previousVersion: "1.0.0",
  currentVersion: "1.1.0",
  version: phase === "initial" ? "1.0.0" : "1.1.0",
  packageSHA256: (phase === "initial" ? "b" : "c").repeat(64),
  engine: birth(12 + generation * 2, generation),
  ui: birth(13 + generation * 2, generation),
  operations: definition.operations,
  ownedPaths: [
    {
      name: "data",
      path: `${root}/Edith Tests/worker-${session}/Data/keepAwake`,
      kind: "directory",
    },
  ],
});
const drain = (cap) => ({
  births: [cap.engine, cap.ui],
  allTasksJoined: true,
  birthsAbsent: true,
  leasesReleased: true,
  signalsSent: 0,
});
const removal = () => ({
  physicallyAbsentVersions: ["1.0.0", "1.1.0"],
  pendingRemoval: false,
  leasesReleased: true,
  sentinelBytesPreserved: true,
  semanticDataPreserved: true,
});

test("portable lifecycle model holds each phase until actual drain and retained baseline", () => {
  const order = new FunctionalJourneyOrder();
  const saved = Buffer.from('{"preventSleep":true}');
  for (const [index, phase] of [
    "initial",
    "updated",
    "reinstalled",
  ].entries()) {
    if (index === 2) order.remove(removal());
    order.captureBaseline(
      index === 0 ? Buffer.from('{"preventSleep":false}') : saved,
    );
    const cap = capability(phase, index);
    const binding = order.hold(cap, definition);
    assert.equal(binding.presentationID, functionalPresentationID(cap));
    assert.match(
      binding.presentationID,
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    order.completeSaved(saved);
    order.drain(drain(cap));
  }
  order.finish();
});

test("construction cannot precede baseline and transitions cannot skip natural join or physical removal", () => {
  const order = new FunctionalJourneyOrder();
  assert.throws(() => order.hold(capability("initial", 0), definition));
  order.captureBaseline(null);
  const cap = capability("initial", 0);
  order.hold(cap, definition);
  assert.throws(() => order.captureBaseline(null));
  assert.throws(() => order.drain(drain(cap)));
  order.completeSaved(null);
  for (const field of ["allTasksJoined", "birthsAbsent", "leasesReleased"])
    assert.throws(() => order.drain({ ...drain(cap), [field]: false }));
  assert.throws(() => order.drain({ ...drain(cap), signalsSent: 1 }));
  order.drain(drain(cap));
  assert.throws(() => order.remove(removal()));
  assert.throws(() => order.finish());
});

test("retained saved state must exist before any updated mutation and final restore must match initial saved bytes", () => {
  const order = new FunctionalJourneyOrder();
  const cap = capability("initial", 0);
  order.captureBaseline(Buffer.from("before"));
  order.hold(cap, definition);
  order.completeSaved(Buffer.from("saved"));
  order.drain(drain(cap));
  assert.throws(() => order.captureBaseline(Buffer.from("seeded")));
  order.captureBaseline(Buffer.from("saved"));
  order.hold(capability("updated", 1), definition);
  assert.throws(() => order.completeSaved(Buffer.from("repair")));
});

test("bounded pool aborts all owned work and awaits retirement before reporting failure", async () => {
  let active = 0,
    maximum = 0,
    retired = 0,
    cleanup = 0,
    started = 0;
  let release;
  const bothStarted = new Promise((resolve) => {
    release = resolve;
  });
  await assert.rejects(
    runFunctionalPool(
      [1, 2, 3, 4],
      2,
      async (item, signal) => {
        active++;
        maximum = Math.max(maximum, active);
        try {
          if (++started === 2) release();
          await bothStarted;
          if (item === 1) throw new Error("synthetic failure");
          await new Promise((resolve) =>
            signal.addEventListener("abort", resolve, { once: true }),
          );
        } finally {
          active--;
          retired++;
        }
      },
      async () => {
        assert.equal(active, 0);
        cleanup++;
      },
    ),
    AggregateError,
  );
  assert.equal(maximum, 2);
  assert.equal(retired, 2);
  assert.equal(cleanup, 1);
  await assert.rejects(
    runFunctionalPool(
      [],
      4,
      async () => {},
      async () => {},
    ),
  );
});

test("artifact admission rejects a wrong source, job, actor, expired payload or unfinished build", () => {
  const sourceCommit = "a".repeat(40);
  const values = {
    sourceCommit,
    artifactSHA256: "b".repeat(64),
    metadata: {
      id: 3,
      name: "functional-fixture-trust",
      expired: false,
      workflow_run: { head_sha: sourceCommit, id: 1 },
    },
    run: {
      id: 1,
      status: "completed",
      conclusion: "success",
      path: ".github/workflows/ci.yml",
      head_sha: sourceCommit,
      event: "workflow_dispatch",
      repository: { full_name: "pulkitxm/edith" },
      actor: { id: 65671483 },
    },
    job: {
      id: 2,
      run_id: 1,
      status: "completed",
      name: "functional-build",
      conclusion: "success",
      labels: ["macos-26"],
    },
  };
  assert.equal(admitFunctionalBuildArtifact(values).artifactID, 3);
  for (const change of [
    (v) => {
      v.metadata.expired = true;
    },
    (v) => {
      v.run.head_sha = "c".repeat(40);
    },
    (v) => {
      v.run.actor.id = 99;
    },
    (v) => {
      v.job.conclusion = null;
    },
    (v) => {
      v.job.name = "counterfeit";
    },
    (v) => {
      v.job.labels = ["self-hosted"];
    },
  ]) {
    const value = structuredClone(values);
    change(value);
    assert.throws(() => admitFunctionalBuildArtifact(value));
  }
});
