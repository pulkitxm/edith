import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  installManagedFixture,
  managedStorePaths,
} from "./hosted-managed-views/store-fixture.mjs";

const uuid = "00000000-0000-4000-8000-000000000001";
const package_ = {
  id: "music",
  version: "1.2.3",
  hostABI: "edith-host-2",
  architecture: "arm64",
  sha256: "a".repeat(64),
  sourceFingerprint: "b".repeat(64),
};

test("per-owner store paths preserve strict current HostIdentity namespaces", () => {
  for (const id of ["music", "calendar"]) {
    const identifier = `com.pulkit.edith.tests.${id === "calendar" ? "remote" : "worker"}-${uuid}`;
    const result = managedStorePaths({
      directory: "/synthetic/fixture",
      identifier,
      package_: { ...package_, id },
    });
    const support =
      id === "calendar" ? "/synthetic/fixture/support" : "/synthetic/fixture";
    expect(result.identityRoot).toBe(
      `${support}/Edith Tests/${identifier.slice("com.pulkit.edith.tests.".length)}`,
    );
    expect(result.versionDirectory).toBe(
      `${result.identityRoot}/Extensions/${id}/edith-host-2/arm64/1.2.3`,
    );
  }
  for (const key of ["id", "version", "hostABI", "architecture"])
    expect(() =>
      managedStorePaths({
        directory: "/synthetic/fixture",
        identifier: `com.pulkit.edith.tests.worker-${uuid}`,
        package_: { ...package_, [key]: "../escape" },
      }),
    ).toThrow();
});

test("actual synthetic ZIP has verified CRC and new digest, selected store and no fabricated view result", async () => {
  const directory = await realpath(
    await mkdtemp(join(tmpdir(), "edith-managed-store-")),
  );
  try {
    const app = join(directory, "Fixture.app");
    const payload = join(directory, "transformed/music");
    await mkdir(join(app, "Contents/Resources"), { recursive: true });
    await writeFile(
      join(app, "Contents/Resources/index.json"),
      JSON.stringify([{ id: "music", title: "Synthetic Music" }]),
    );
    await mkdir(join(payload, "app.bundle/Contents/MacOS"), {
      recursive: true,
    });
    await writeFile(
      join(payload, "app.bundle/Contents/MacOS/Runtime"),
      "synthetic-code-bytes",
    );
    const preparation = {
      directory,
      host: {
        app,
        identifier: `com.pulkit.edith.tests.worker-${uuid}`,
        sourceCommit: "c".repeat(40),
      },
      package: package_,
      payload,
      originalSourceCommit: "d".repeat(40),
      originalZipSHA256: "e".repeat(64),
    };
    const owner = {
      id: "music",
      location: "main",
      section: "music",
      factoryOverlay: false,
    };
    const result = await installManagedFixture({ preparation, owner });
    expect(result.package.sha256).not.toBe(package_.sha256);
    expect(result.package.downloadBytes).toBe(
      (await stat(result.archive)).size,
    );
    expect(result.package.installedBytes).toBe("synthetic-code-bytes".length);
    expect(result.route.packageSHA256).toBe(result.package.sha256);
    expect(result.route.sourceCommit).toBe("c".repeat(40));
    expect(result.originalSourceCommit).toBe("d".repeat(40));
    expect(result.managedNativeViewValidated).toBe(false);
    expect(result.signedCatalogPayload).toBe(false);
    expect(
      (await stat(join(directory, "managed-route.json"))).mode & 0o7777,
    ).toBe(0o600);
    expect((await stat(result.fixtureHome)).mode & 0o7777).toBe(0o700);
    const location = managedStorePaths({
      directory,
      identifier: preparation.host.identifier,
      package_: result.package,
    }).versionDirectory;
    expect(
      await readFile(
        join(location, "music/app.bundle/Contents/MacOS/Runtime"),
        "utf8",
      ),
    ).toBe("synthetic-code-bytes");
    const contents = JSON.parse(
      execFileSync("python3", [
        "-c",
        "import json,sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; print(json.dumps(z.namelist()))",
        result.archive,
      ]),
    );
    expect(contents).toEqual(["music/app.bundle/Contents/MacOS/Runtime"]);
    await expect(
      installManagedFixture({ preparation, owner }),
    ).rejects.toThrow();
    expect(
      await readFile(
        join(location, "music/app.bundle/Contents/MacOS/Runtime"),
        "utf8",
      ),
    ).toBe("synthetic-code-bytes");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
