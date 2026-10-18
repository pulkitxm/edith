import { expect, test } from "bun:test";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { validateCameraCarrierDefinition } from "./build-camera-carrier.mjs";
import { requireRegularTree } from "./build-contained-host-runtime.mjs";
import { workerHostABI } from "./extension-host-abi.mjs";

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
  ])
    expect(() =>
      validateCameraCarrierDefinition({ ...definition, ...change }),
    ).toThrow();
});

test("OBS microphone carriers require no provider role or installation entitlement", () => {
  const obs = {
    role: "cameraCarrier",
    transport: "obs",
    applicationIdentifier: "com.pulkit.edith.cameraCarrier",
    minimumSystemVersion: "14.0.0",
  };
  expect(validateCameraCarrierDefinition(obs)).toEqual(obs);
  for (const change of [
    { providerRole: "cameraProvider" },
    { installEntitlement: "com.apple.developer.system-extension.install" },
    { transport: "unrecognized" },
  ])
    expect(() =>
      validateCameraCarrierDefinition({ ...obs, ...change }),
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

test("camera probe fixture ABI matches the compiled host admission contract", async () => {
  const configuration = await readFile(
    new URL(
      "../Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift",
      import.meta.url,
    ),
    "utf8",
  );
  expect(
    /public static let workerHostABI = "([^"]+)"/.exec(configuration)?.[1],
  ).toBe(workerHostABI);
  const contract = await readFile(
    new URL(
      "../Packages/EdithHost/Sources/EdithHostCore/HostContract.swift",
      import.meta.url,
    ),
    "utf8",
  );
  expect(contract).toContain(
    "public static let compatibility = MarketplaceConfiguration.workerHostABI",
  );
  const probe = await readFile(
    new URL("./test-camera-carrier.mjs", import.meta.url),
    "utf8",
  );
  expect(probe).toContain(
    'import { workerHostABI } from "./extension-host-abi.mjs";',
  );
  expect(probe).toMatch(/"hostABI": "\$\{workerHostABI\}"/);
  expect(probe).toContain("EdithHostABI: workerHostABI");
  expect(probe).toContain("hostABI: workerHostABI");
  expect(probe).not.toContain("edith-host-1");
});
