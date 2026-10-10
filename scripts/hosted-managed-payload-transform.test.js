import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  chmod,
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
import {
  copyNativeRolePayloads,
  fixturePayloadQualification,
  validateFixtureHost,
  validateTransformationInput,
} from "./hosted-managed-views/payload-transform.mjs";

function inputs(root, id = "calendar") {
  const roles =
    id === "virtualCamera"
      ? { app: [], privileged: [], cameraCarrier: [] }
      : { app: [] };
  const owner = { id, factoryOverlay: ["plugins", "studio"].includes(id) };
  return {
    owner,
    definition: { id, roles },
    original: {
      extensionID: id,
      sourceFingerprint: "a".repeat(64),
      zipSHA256: "b".repeat(64),
      expandedDirectory: join(root, "original", id),
      receipt: {
        extensionID: id,
        sourceCommit: "c".repeat(40),
        sourceFingerprint: "a".repeat(64),
        zipSHA256: "b".repeat(64),
        packageCodeExecuted: false,
        signaturesVerified: true,
        sealedHostProvenanceVerified: true,
        zipCRCVerified: true,
        roles: Object.fromEntries(
          Object.keys(roles)
            .filter((role) => role !== "cameraCarrier")
            .map((role) => [role, {}]),
        ),
      },
    },
    host: {
      app: join(root, "Fixture.app"),
      sourceCommit: "d".repeat(40),
      executableSHA256: "e".repeat(64),
      identifier: `com.pulkit.edith.tests.${id === "calendar" ? "remote" : "worker"}-12345678-1234-1234-1234-123456789abc`,
      productionExecutableUnchangedProof: false,
    },
    output: join(root, "output"),
  };
}

async function fixture(run) {
  const root = await realpath(
    await mkdtemp(join(tmpdir(), "edith-managed-payload-")),
  );
  try {
    await run(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("copy preserves exact native role files and leaves original auxiliary carriers untouched", async () => {
  await fixture(async (root) => {
    const value = inputs(root, "virtualCamera");
    const source = join(
      value.original.expandedDirectory,
      "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/virtualCamera",
    );
    const bytes = Buffer.from([0, 255, 1, 37, 89]);
    for (const role of ["app", "privileged"]) {
      await mkdir(join(source, `${role}.bundle/Contents/MacOS`), {
        recursive: true,
      });
      await writeFile(
        join(source, `${role}.bundle/Contents/MacOS/Runtime`),
        bytes,
        { mode: 0o755 },
      );
    }
    await mkdir(join(value.original.expandedDirectory, "CameraCarrier.app"));
    await writeFile(
      join(value.original.expandedDirectory, "CameraCarrier.app/original"),
      "original-host-tier",
    );
    await mkdir(value.output, { mode: 0o700 });
    const result = await copyNativeRolePayloads(value);
    expect(result.roles).toEqual(["app", "privileged"]);
    for (const role of result.roles)
      expect(
        await readFile(
          join(result.payload, `${role}.bundle/Contents/MacOS/Runtime`),
        ),
      ).toEqual(bytes);
    expect(
      await readFile(
        join(value.original.expandedDirectory, "CameraCarrier.app/original"),
        "utf8",
      ),
    ).toBe("original-host-tier");
    await expect(
      readFile(join(result.payload, "CameraCarrier.app/original")),
    ).rejects.toThrow();
    await expect(copyNativeRolePayloads(value)).rejects.toThrow();
  });
});

test("unknown native roles, stale receipts and synthetic identity lookalikes reject before copying", () => {
  for (const mutate of [
    (v) => {
      v.definition.roles.future = [];
    },
    (v) => {
      v.original.receipt.sourceFingerprint = "f".repeat(64);
    },
    (v) => {
      v.original.receipt.packageCodeExecuted = true;
    },
    (v) => {
      v.original.receipt.sealedHostProvenanceVerified = false;
    },
    (v) => {
      v.host.identifier += ".production";
    },
    (v) => {
      v.host.productionExecutableUnchangedProof = true;
    },
    (v) => {
      v.owner.factoryOverlay = true;
    },
  ]) {
    const value = inputs("/private/tmp/synthetic");
    mutate(value);
    expect(() => validateTransformationInput(value)).toThrow();
  }
});

test("symlink payload and accessible output modes fail closed", async () => {
  await fixture(async (root) => {
    const value = inputs(root);
    await mkdir(value.original.expandedDirectory, { recursive: true });
    await writeFile(join(root, "foreign"), "foreign");
    await symlink(
      join(root, "foreign"),
      join(value.original.expandedDirectory, "alias"),
    );
    await mkdir(value.output, { mode: 0o700 });
    await expect(copyNativeRolePayloads(value)).rejects.toThrow();
    await rm(join(value.original.expandedDirectory, "alias"));
    await chmod(value.output, 0o740);
    await expect(copyNativeRolePayloads(value)).rejects.toThrow();
  });
});

test("fixture Host identity and executable digest are independently checked", async () => {
  await fixture(async (root) => {
    const { host } = inputs(root);
    await mkdir(join(host.app, "Contents/MacOS"), { recursive: true });
    await writeFile(join(host.app, "Contents/MacOS/Edith"), "fixture-host");
    host.executableSHA256 = createHash("sha256")
      .update("fixture-host")
      .digest("hex");
    const metadata = {
      CFBundleIdentifier: host.identifier,
      CFBundleExecutable: "Edith",
      CFBundlePackageType: "APPL",
    };
    expect(await validateFixtureHost(host, () => metadata)).toEqual(metadata);
    await expect(
      validateFixtureHost(host, () => ({
        ...metadata,
        CFBundleIdentifier: "com.pulkit.edith",
      })),
    ).rejects.toThrow();
    await writeFile(join(host.app, "Contents/MacOS/Edith"), "changed-host");
    await expect(validateFixtureHost(host, () => metadata)).rejects.toThrow();
  });
});

test("Camera Host tier and factory exceptions never imply untouched shipping executable or rendered view", () => {
  const camera = fixturePayloadQualification({
    id: "virtualCamera",
    factoryOverlay: false,
  });
  expect(camera.nativeRoleCodeAndResourcesUnchanged).toBe(true);
  expect(camera.auxiliaryCameraCarrierTransformed).toBe(true);
  expect(camera.unchangedScope).toContain(
    "excluding signatures and all Host executable carriers",
  );
  const studio = fixturePayloadQualification({
    id: "studio",
    factoryOverlay: true,
  });
  expect(studio.nativeRoleCodeAndResourcesUnchanged).toBe(false);
  for (const value of [camera, studio]) {
    expect(value.managedNativeViewValidated).toBe(false);
    expect(value.functionalActionsValidated).toBe(false);
    expect(value.productionExecutableUnchangedProof).toBe(false);
  }
});
