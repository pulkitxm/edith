import { expect, test } from "bun:test";
import { generateKeyPairSync, verify } from "node:crypto";
import {
  chmod,
  mkdir,
  mkdtemp,
  readlink,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { copyJourneyApplication } from "./hosted-original-shell/prepare-journey.mjs";
import {
  canonicalSparkleJSON,
  createSparkleDescriptor,
  sparkleLoopbackTransport,
  sparkleResourceInventory,
} from "./hosted-sparkle-update/prepare-update.mjs";

test("a canonical signed bootstrap carries producer authority without circular app inventory hashes", () => {
  const keys = generateKeyPairSync("ed25519");
  const value = {
    session: "00000000-0000-4000-8000-000000000001",
    sourceCommit: "a".repeat(40),
    identifier:
      "com.pulkit.edith.tests.remote-00000000-0000-4000-8000-000000000001",
    directory:
      "/Users/runner/Applications/Edith Remote Fixture Journey 00000000-0000-4000-8000-000000000001",
    port: 4321,
    updatePublicKey: Buffer.alloc(32, 7).toString("base64"),
    producer: {
      pid: 123,
      uid: 501,
      birth: "123.4",
      executable: "/owned/node",
      executableSHA256: "b".repeat(64),
    },
  };
  const bytes = createSparkleDescriptor(value, keys.privateKey);
  const envelope = JSON.parse(bytes);
  const payload = Buffer.from(envelope.payload, "base64");
  expect(bytes).toEqual(canonicalSparkleJSON(envelope));
  expect(
    verify(
      null,
      payload,
      keys.publicKey,
      Buffer.from(envelope.signature, "base64"),
    ),
  ).toBe(true);
  expect(JSON.parse(payload)).toEqual({ schema: 1, ...value });
  expect(JSON.parse(payload).installedCodeSHA256).toBeUndefined();
  expect(sparkleLoopbackTransport).toEqual({
    NSExceptionDomains: {
      "127.0.0.1": { NSExceptionAllowsInsecureHTTPLoads: true },
    },
  });
});

test("whole-app inventories bind nested framework code, metadata and exact contained symlinks", async () => {
  const root = await realpath(
    await mkdtemp(join(tmpdir(), "sparkle-inventory-")),
  );
  try {
    await mkdir(join(root, "Framework"), { mode: 0o700 });
    await writeFile(join(root, "Framework/code"), "synthetic code", {
      mode: 0o600,
    });
    await writeFile(join(root, "Info.plist"), "synthetic metadata", {
      mode: 0o600,
    });
    await symlink("code", join(root, "Framework/Current"));
    const first = await sparkleResourceInventory(root);
    expect(first.entries.map(([name]) => name)).toEqual([
      "Framework/Current",
      "Framework/code",
      "Info.plist",
    ]);
    await writeFile(join(root, "Framework/code"), "changed code", {
      mode: 0o600,
    });
    expect((await sparkleResourceInventory(root)).sha256).not.toBe(
      first.sha256,
    );
    await symlink("/etc/passwd", join(root, "escape"));
    await expect(sparkleResourceInventory(root)).rejects.toThrow();
    await rm(join(root, "escape"));
    await chmod(join(root, "Info.plist"), 0o666);
    await expect(sparkleResourceInventory(root)).rejects.toThrow();
  } finally {
    await rm(root, { recursive: true });
  }
});

test("initial replacement and archive copies preserve actual relative framework links inside their own app", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "sparkle-copy-")));
  try {
    const source = join(root, "source");
    await mkdir(join(source, "Framework/Versions/A"), {
      recursive: true,
      mode: 0o700,
    });
    await writeFile(
      join(source, "Framework/Versions/A/binary"),
      "synthetic binary",
      { mode: 0o600 },
    );
    await symlink("A", join(source, "Framework/Versions/Current"));
    await symlink("Versions/Current/binary", join(source, "Framework/binary"));
    const original = await sparkleResourceInventory(source);
    let previous = source;
    for (const name of ["initial", "replacement", "archive"]) {
      const destination = join(root, name);
      await copyJourneyApplication(previous, destination);
      expect(await readlink(join(destination, "Framework/binary"))).toBe(
        "Versions/Current/binary",
      );
      expect(await realpath(join(destination, "Framework/binary"))).toBe(
        join(destination, "Framework/Versions/A/binary"),
      );
      expect((await sparkleResourceInventory(destination)).sha256).toBe(
        original.sha256,
      );
      previous = destination;
    }
    await expect(copyJourneyApplication(source, previous)).rejects.toThrow();
  } finally {
    await rm(root, { recursive: true });
  }
});
