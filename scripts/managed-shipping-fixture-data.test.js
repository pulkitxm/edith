import { test } from "bun:test";
import assert from "node:assert/strict";
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { prepareManagedShippingData } from "./managed-shipping-fixture-data.mjs";

async function fixture(run) {
  const directory = await realpath(
    await mkdtemp(join(tmpdir(), "managed-shipping-data-")),
  );
  const options = {
    directory,
    identifier:
      "com.pulkit.edith.tests.remote-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    package_: {
      id: "calendar",
      hostABI: "edith-host-2",
      architecture: "arm64",
      version: "1.0.0",
    },
  };
  await mkdir(
    join(
      directory,
      "support/Edith Tests/remote-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/Extensions/calendar/edith-host-2/arm64/1.0.0/calendar",
    ),
    { recursive: true },
  );
  try {
    await run(options);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

test("private data preparation admits exact owned paths and safely retries", async () => {
  await fixture(async (options) => {
    const first = await prepareManagedShippingData(options);
    const next = await prepareManagedShippingData(options);
    assert.deepEqual(next, first);
    assert.equal((await lstat(first.fixtureHome)).mode & 0o777, 0o700);
    const path = join(first.fixtureHome, "calendar-fixture.json");
    assert.equal((await lstat(path)).mode & 0o777, 0o600);
    assert.deepEqual(JSON.parse(await readFile(path)), first.marker);
  });
});

for (const [name, change] of [
  [
    "foreign marker",
    async (path) => writeFile(path, '{"schema":1,"hostIdentifier":"foreign"}'),
  ],
  ["oversize marker", async (path) => writeFile(path, " ".repeat(16_385))],
  ["public marker permissions", async (path) => chmod(path, 0o644)],
  [
    "symbolic marker alias",
    async (path) => {
      await rm(path);
      await symlink("missing", path);
    },
  ],
]) {
  test(`private data preparation rejects ${name} without replacing it`, async () => {
    await fixture(async (options) => {
      const { fixtureHome } = await prepareManagedShippingData(options);
      const path = join(fixtureHome, "calendar-fixture.json");
      await change(path);
      await assert.rejects(() => prepareManagedShippingData(options));
    });
  });
}

test("private data preparation rejects an unverified provider before its engine starts", async () => {
  await fixture(async (options) => {
    await assert.rejects(() =>
      prepareManagedShippingData({
        ...options,
        package_: { ...options.package_, id: "systemStats" },
      }),
    );
  });
});

test("private data preparation rejects an aliased package root", async () => {
  await fixture(async (options) => {
    const path = join(
      options.directory,
      "support/Edith Tests/remote-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/Extensions/calendar/edith-host-2/arm64/1.0.0/calendar",
    );
    await rm(path, { recursive: true });
    await symlink(options.directory, path);
    await assert.rejects(() => prepareManagedShippingData(options));
  });
});

for (const identifier of [
  "com.pulkit.edith.tests.remote-owned-20261010",
  "com.pulkit.edith.tests.remote-unit",
  "com.pulkit.edith.tests.remote-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee",
]) {
  test(`private data preparation rejects an identifier outside provider admission: ${identifier}`, async () => {
    await fixture(async (options) => {
      await assert.rejects(() =>
        prepareManagedShippingData({ ...options, identifier }),
      );
      await assert.rejects(() =>
        lstat(join(options.directory, "synthetic-data")),
      );
    });
  });
}
