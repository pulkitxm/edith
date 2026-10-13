import { test } from "bun:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { PassThrough } from "node:stream";
import {
  productionCatalogBinding,
  productionCatalogChannel,
  productionCatalogMessage,
  productionObserverEnvironment,
  validateProductionCatalogMessage,
} from "./production-catalog-channel.mjs";

const previous = {
  schemaVersion: 1,
  revision: 1,
  assetName: "catalog-1.json",
  bytes: 100,
  sha256: "a".repeat(64),
};
const candidate = {
  schemaVersion: 1,
  revision: 2,
  assetName: "catalog-2.json",
  bytes: 200,
  sha256: "b".repeat(64),
};
const text = JSON.stringify({
  source: "c".repeat(40),
  catalogs: { previous, current: candidate },
});
const identity = { source: "c".repeat(40), previous, candidate };
const binding = productionCatalogBinding(text, identity);

function pair() {
  const left = new PassThrough();
  const right = new PassThrough();
  const parent = productionCatalogChannel(left, right);
  const child = productionCatalogChannel(right, left);
  return {
    parent,
    child,
    left,
    right,
    close: () => {
      parent.close();
      child.close();
    },
  };
}

test("restoration and promotion use opposite anonymous channels with exact source and generation bindings", async () => {
  const channels = pair();
  try {
    const milestone = channels.parent.read();
    await channels.child.write(
      productionCatalogMessage("host-restored", binding),
    );
    validateProductionCatalogMessage(await milestone, "host-restored", binding);
    const promoted = channels.child.read();
    await channels.parent.write(
      productionCatalogMessage("catalog-promoted", binding),
    );
    validateProductionCatalogMessage(
      await promoted,
      "catalog-promoted",
      binding,
    );
  } finally {
    channels.close();
  }
});

test("changed source, request, previous pointer, candidate pointer and extra fields cannot grant promotion", () => {
  const message = productionCatalogMessage("host-restored", binding);
  for (const key of [
    "source",
    "requestSHA256",
    "previousSHA256",
    "candidateSHA256",
  ])
    assert.throws(() =>
      validateProductionCatalogMessage(
        { ...message, [key]: "d".repeat(key === "source" ? 40 : 64) },
        "host-restored",
        binding,
      ),
    );
  assert.throws(() =>
    validateProductionCatalogMessage(
      { ...message, success: true },
      "host-restored",
      binding,
    ),
  );
  assert.throws(() =>
    validateProductionCatalogMessage(message, "catalog-promoted", binding),
  );
  assert.throws(() =>
    productionCatalogBinding(text, { ...identity, source: "d".repeat(40) }),
  );
  assert.throws(() =>
    productionCatalogBinding(text, {
      ...identity,
      candidate: { ...candidate, bytes: 201 },
    }),
  );
});

test("fragmented closed messages are accepted without accepting duplicate frames or trailing data", async () => {
  const channels = pair();
  try {
    const pending = channels.parent.read();
    const encoded = JSON.stringify(
      productionCatalogMessage("host-restored", binding),
    );
    channels.left.write(encoded.slice(0, 10));
    channels.left.write(`${encoded.slice(10)}\n`);
    validateProductionCatalogMessage(await pending, "host-restored", binding);
    channels.left.write("{}\n");
    await assert.rejects(channels.parent.read());
  } finally {
    channels.close();
  }
});

test("closed, oversized, invalid UTF8 and multi-frame messages fail without a success fallback", async () => {
  for (const payload of [
    Buffer.alloc(2049, 32),
    Buffer.from("{}\n{}\n"),
    Buffer.from([0xff, 10]),
  ]) {
    const channels = pair();
    try {
      const pending = channels.parent.read();
      channels.left.write(payload);
      await assert.rejects(pending);
    } finally {
      channels.close();
    }
  }
  const channels = pair();
  const pending = channels.parent.read();
  channels.left.end();
  await assert.rejects(pending);
  channels.close();
});

test("native observer child drops write, signing, interpreter, keychain, fixture and inherited authority", () => {
  const environment = productionObserverEnvironment(
    {
      HOME: "/synthetic/private",
      PATH: "/synthetic/bin",
      GITHUB_SHA: identity.source,
      PUBLIC_RELEASE_VERIFICATION: "1",
      GITHUB_TOKEN: "synthetic-read-only",
      GH_TOKEN: "synthetic-write",
      EXTENSION_CATALOG_PRIVATE_KEY: "synthetic-signing",
      MACOS_CERT_PASSWORD: "synthetic-password",
      NODE_OPTIONS: "synthetic-options",
      PYTHONPATH: "/synthetic/authority",
      EDITH_EXTENSION_DATA_ROOT: "/synthetic/data",
      SSH_AUTH_SOCK: "/synthetic/socket",
      PUBLISH: "true",
      EXTENSION_SWIFT_JOBS: "99",
    },
    text,
    binding,
  );
  assert.equal(environment.GITHUB_TOKEN, "synthetic-read-only");
  for (const key of [
    "GH_TOKEN",
    "EXTENSION_CATALOG_PRIVATE_KEY",
    "MACOS_CERT_PASSWORD",
    "NODE_OPTIONS",
    "PYTHONPATH",
    "EDITH_EXTENSION_DATA_ROOT",
    "SSH_AUTH_SOCK",
  ])
    assert.equal(environment[key], undefined);
  assert.equal(environment.PUBLISH, "false");
  assert.equal(environment.EXTENSION_SWIFT_JOBS, "1");
  assert.equal(environment.PUBLIC_HOST_UPDATE_REQUEST, text);
  assert(Object.isFrozen(environment));
});

test("actual inherited anonymous file descriptors round-trip the closed milestone without filesystem rendezvous", async () => {
  const module = new URL("./production-catalog-channel.mjs", import.meta.url)
    .href;
  const code = `import { inheritedProductionCatalogChannel, productionCatalogMessage, validateProductionCatalogMessage } from ${JSON.stringify(module)};
const binding = ${JSON.stringify(binding)};
const channel = inheritedProductionCatalogChannel();
try { await channel.write(productionCatalogMessage("host-restored", binding)); validateProductionCatalogMessage(await channel.read(), "catalog-promoted", binding); } finally { channel.close(); }`;
  const child = spawn(process.execPath, ["--eval", code], {
    env: { PATH: process.env.PATH },
    stdio: ["ignore", "pipe", "pipe", "pipe", "pipe"],
  });
  const parent = productionCatalogChannel(child.stdio[4], child.stdio[3]);
  const stderr = [];
  child.stderr.on("data", (chunk) => stderr.push(chunk));
  const joined = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => resolve({ code, signal }));
  });
  let retired = false;
  const timer = setTimeout(() => {
    retired = true;
    child.kill("SIGKILL");
  }, 3000);
  try {
    validateProductionCatalogMessage(
      await parent.read(),
      "host-restored",
      binding,
    );
    await parent.write(productionCatalogMessage("catalog-promoted", binding));
    assert.deepEqual(
      await joined,
      { code: 0, signal: null },
      Buffer.concat(stderr).toString(),
    );
    assert.equal(retired, false);
  } finally {
    parent.close();
    if (child.exitCode === null && child.signalCode === null)
      child.kill("SIGKILL");
    await joined;
    clearTimeout(timer);
  }
});
