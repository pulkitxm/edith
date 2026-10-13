import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { close, createWriteStream, read } from "node:fs";
import { Readable } from "node:stream";
import { validateCatalogPointer } from "../extension-catalog-pointer.mjs";

const exact = (value, keys) => {
  assert(value && typeof value === "object" && !Array.isArray(value));
  assert.deepEqual(Object.keys(value).sort(), keys.sort());
};
export function productionCatalogBinding(text, identity) {
  assert(typeof text === "string" && Buffer.byteLength(text) <= 65536);
  exact(identity, ["source", "previous", "candidate"]);
  const request = JSON.parse(text);
  assert.equal(identity.source, request.source);
  assert.match(identity.source, /^[a-f0-9]{40}$/);
  for (const [generation, pointer] of [
    ["previous", identity.previous],
    ["current", identity.candidate],
  ]) {
    validateCatalogPointer(pointer);
    for (const key of ["revision", "sha256", "bytes"])
      assert.equal(request.catalogs[generation][key], pointer[key]);
  }
  assert(identity.candidate.revision > identity.previous.revision);
  return Object.freeze({
    schema: 1,
    source: identity.source,
    requestSHA256: createHash("sha256").update(text).digest("hex"),
    previousSHA256: identity.previous.sha256,
    candidateSHA256: identity.candidate.sha256,
  });
}
export function productionCatalogMessage(kind, binding) {
  exact(binding, [
    "schema",
    "source",
    "requestSHA256",
    "previousSHA256",
    "candidateSHA256",
  ]);
  assert.equal(binding.schema, 1);
  assert.match(binding.source, /^[a-f0-9]{40}$/);
  for (const key of ["requestSHA256", "previousSHA256", "candidateSHA256"])
    assert.match(binding[key], /^[a-f0-9]{64}$/);
  assert.notEqual(binding.previousSHA256, binding.candidateSHA256);
  assert(["host-restored", "catalog-promoted"].includes(kind));
  return Object.freeze({ kind, ...binding });
}
export function validateProductionCatalogMessage(value, kind, binding) {
  assert.deepEqual(value, productionCatalogMessage(kind, binding));
}
export function productionCatalogChannel(input, output) {
  let buffer = Buffer.alloc(0);
  let closed = false;
  let failure;
  let pending;
  let received;
  const fail = (error) => {
    failure ??= error;
    closed = true;
    if (pending) {
      const reject = pending.reject;
      pending = undefined;
      reject(failure);
    }
  };
  input.on("error", fail);
  output.on("error", fail);
  input.on("end", () => fail(new Error("Catalog channel closed")));
  input.on("data", (chunk) => {
    try {
      assert(!closed && !received && buffer.length + chunk.length <= 2048);
      buffer = Buffer.concat([buffer, chunk]);
      const end = buffer.indexOf(10);
      if (end < 0) return;
      assert.equal(end, buffer.length - 1);
      received = true;
      const raw = buffer.subarray(0, end);
      const text = raw.toString("utf8");
      assert(raw.equals(Buffer.from(text)));
      const value = JSON.parse(text);
      if (pending) {
        const resolve = pending.resolve;
        pending = undefined;
        resolve(value);
      } else buffer = value;
    } catch (error) {
      fail(error);
    }
  });
  return Object.freeze({
    read: () => {
      assert(!pending);
      if (failure) return Promise.reject(failure);
      if (received) {
        const value = buffer;
        buffer = undefined;
        assert(value && !Buffer.isBuffer(value));
        return Promise.resolve(value);
      }
      return new Promise((resolve, reject) => {
        pending = { resolve, reject };
      });
    },
    write: (value) => {
      assert(!closed);
      const bytes = Buffer.from(`${JSON.stringify(value)}\n`);
      assert(bytes.length <= 2048);
      return new Promise((resolve, reject) =>
        output.write(bytes, (error) => (error ? reject(error) : resolve())),
      );
    },
    close: () => {
      fail(new Error("Catalog channel retired"));
      input.destroy();
      output.destroy();
    },
  });
}
export function inheritedProductionCatalogChannel() {
  let reading = false;
  let framed = false;
  let destroyCallback;
  const retire = (callback) => close(3, callback);
  const input = new Readable({
    read() {
      if (reading || framed) return;
      reading = true;
      const bytes = Buffer.alloc(2048);
      read(3, bytes, 0, bytes.length, null, (error, count) => {
        reading = false;
        if (destroyCallback) {
          retire(destroyCallback);
          return;
        }
        if (error) {
          this.destroy(error);
          return;
        }
        if (count === 0) {
          this.push(null);
          return;
        }
        const chunk = bytes.subarray(0, count);
        framed = chunk.includes(10);
        this.push(chunk);
      });
    },
    destroy(error, callback) {
      const finish = (closeError) => callback(error ?? closeError);
      if (reading) destroyCallback = finish;
      else retire(finish);
    },
  });
  return productionCatalogChannel(
    input,
    createWriteStream(null, { fd: 4, autoClose: true }),
  );
}
export function productionReadonlyEnvironment(environment) {
  const keys = [
    "HOME",
    "PATH",
    "TMPDIR",
    "DEVELOPER_DIR",
    "LANG",
    "LC_ALL",
    "GITHUB_ACTIONS",
    "RUNNER_ENVIRONMENT",
    "RUNNER_OS",
    "GITHUB_REPOSITORY",
    "GITHUB_REPOSITORY_ID",
    "GITHUB_EVENT_NAME",
    "GITHUB_REF",
    "GITHUB_SHA",
    "GITHUB_ACTOR_ID",
    "PUBLIC_RELEASE_VERIFICATION",
    "GITHUB_TOKEN",
  ];
  const result = Object.fromEntries(
    keys
      .filter((key) => environment[key] !== undefined)
      .map((key) => [key, environment[key]]),
  );
  assert.equal(result.PUBLIC_RELEASE_VERIFICATION, "1");
  return Object.freeze(result);
}
export function productionObserverEnvironment(environment, request, binding) {
  const result = productionReadonlyEnvironment(environment);
  assert.equal(result.GITHUB_SHA, binding.source);
  return Object.freeze({
    ...result,
    PUBLISH: "false",
    REBUILD: "",
    EXTENSION_SWIFT_JOBS: "1",
    PYTHONDONTWRITEBYTECODE: "1",
    PUBLIC_HOST_UPDATE_REQUEST: request,
    PUBLIC_HOST_CATALOG_BINDING: JSON.stringify(binding),
  });
}
