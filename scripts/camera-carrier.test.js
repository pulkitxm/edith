import { expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { validateCameraCarrierDefinition } from "./build-camera-carrier.mjs";
import { requireRegularTree } from "./build-contained-host-runtime.mjs";

const definition = {
  role: "cameraCarrier",
  providerRole: "cameraProvider",
  applicationIdentifier: "com.pulkit.edith.cameraCarrier",
  extensionIdentifier: "com.pulkit.edith.camera",
  minimumSystemVersion: "14.0.0",
  installEntitlement: "com.apple.developer.system-extension.install",
};

test("camera carrier metadata permits only the matching sealed roles and identities", () => {
  expect(validateCameraCarrierDefinition(definition)).toEqual(definition);
  for (const change of [
    { role: "app" },
    { providerRole: "agent" },
    { extensionIdentifier: "org.other.camera" },
    { minimumSystemVersion: "13.0.0" },
    { applicationIdentifier: "../arbitrary" },
    { providerEntitlement: "com.apple.developer.cmio.extension" },
    { providerRole: undefined },
    { installEntitlement: undefined },
    { transport: "obs" },
  ])
    expect(() =>
      validateCameraCarrierDefinition({ ...definition, ...change }),
    ).toThrow();
});

test("contained camera archive rejects nested links rather than following them", async () => {
  const root = await mkdtemp(join(tmpdir(), "camera-regular-tree-"));
  try {
    await mkdir(join(root, "nested"));
    await writeFile(join(root, "nested/data"), "synthetic");
    await requireRegularTree(root);
    await symlink("data", join(root, "nested/link"));
    await expect(requireRegularTree(root)).rejects.toThrow();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
