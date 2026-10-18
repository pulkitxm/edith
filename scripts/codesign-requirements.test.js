import { afterAll, beforeAll, describe, test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmod,
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  inventorySparkleApp,
  sparkleLoopbackTransport,
} from "./hosted-sparkle-update/prepare-update.mjs";

describe.skipIf(process.platform !== "darwin")(
  "native signing requirements",
  () => {
    let fixture;
    let app;
    let executable;
    let identity;
    const run = (program, arguments_) =>
      execFileSync(program, arguments_, { stdio: "pipe", timeout: 10000 });

    beforeAll(async () => {
      fixture = await realpath(
        await mkdtemp(join(tmpdir(), "edith-signing-requirement-")),
      );
      await chmod(fixture, 0o700);
      app = join(fixture, "Synthetic.app");
      const contents = join(app, "Contents");
      const resources = join(contents, "Resources");
      await mkdir(join(contents, "MacOS"), { recursive: true, mode: 0o700 });
      await mkdir(resources, { mode: 0o700 });
      executable = join(contents, "MacOS/Edith");
      await copyFile("/usr/bin/true", executable);
      await chmod(executable, 0o700);
      await writeFile(
        join(resources, "fixture.txt"),
        "synthetic signing fixture\n",
        { mode: 0o600 },
      );
      identity = `com.pulkit.edith.tests.signing.${crypto.randomUUID()}`;
      const info = join(contents, "Info.plist");
      await writeFile(
        info,
        JSON.stringify({
          CFBundleIdentifier: identity,
          CFBundleExecutable: "Edith",
          CFBundlePackageType: "APPL",
          CFBundleShortVersionString: "1.0.0",
          CFBundleVersion: "1",
          NSAppTransportSecurity: sparkleLoopbackTransport,
          SUVerifyUpdateBeforeExtraction: true,
        }),
        { mode: 0o600 },
      );
      run("plutil", ["-convert", "xml1", info]);
      run("codesign", [
        "--force",
        "--sign",
        "-",
        "--identifier",
        identity,
        app,
      ]);
    }, 30000);

    afterAll(async () => {
      if (fixture) await rm(fixture, { recursive: true, force: true });
    });

    const inventory = (requirement) =>
      inventorySparkleApp(app, {
        identifier: identity,
        version: "1.0.0",
        requirement,
      });

    test("the real signed fixture passes the intended inline identity", async () => {
      const result = await inventory(`identifier "${identity}"`);
      assert.equal(result.signatureVerified, true);
      assert(
        result.application.some((entry) => entry[0] === "Contents/MacOS/Edith"),
      );
    });

    test("a different inline identity cannot pass a valid signature", async () => {
      await assert.rejects(
        inventory('identifier "com.pulkit.edith.tests.foreign"'),
      );
    });

    test("the old file argument cannot interpret an inline requirement", () => {
      assert.throws(() =>
        run("codesign", [
          "--verify",
          "--strict",
          "-R",
          `identifier "${identity}"`,
          app,
        ]),
      );
    });

    test("the same identity cannot admit modified signed code", async () => {
      const bytes = await readFile(executable);
      const changed = Buffer.from(bytes);
      changed[Math.min(4096, changed.length - 1)] ^= 1;
      try {
        await writeFile(executable, changed);
        await assert.rejects(inventory(`identifier "${identity}"`));
      } finally {
        await writeFile(executable, bytes);
      }
    });
  },
);
