import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  buildCameraCarrier,
  requireRegularTree,
} from "./build-camera-carrier.mjs";

const root = await realpath(
  await mkdtemp(join(tmpdir(), "edith-camera-fixture-")),
);
const roles = ["cameraCarrier", "cameraProvider"];
const hostApp = resolve("local/minimal-host/Edith.app");
try {
  const payloads = join(root, "payloads");
  for (const role of roles) {
    const contents = join(payloads, `${role}.bundle/Contents`);
    await mkdir(join(contents, "MacOS"), { recursive: true });
    const source = join(root, `${role}.swift`);
    await writeFile(
      source,
      `import Foundation
import AppKit
import Sparkle
@MainActor @objc final class FixtureRuntime: NSObject {
    @objc func execute(_ input: NSDictionary) -> NSObject {
        if input["operation"] as? String == "describe" {
            return ["id": "virtualCamera", "role": "${role}", "version": "1.0.0", "hostABI": "edith-host-1"] as NSDictionary
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let framework = Bundle(for: SPUStandardUpdaterController.self)
        let resourcesLoaded = NSNib(nibNamed: "SUUpdateAlert", bundle: framework) != nil
        return ["ok": resourcesLoaded, "payloadLoaded": true, "role": "${role}", "sparkleGUIControllerInitialized": controller.userDriver.isKind(of: SPUStandardUserDriver.self), "sparkleGUIResourcesLoaded": resourcesLoaded, "exposedWindows": application.windows.filter { $0.isVisible }.count] as NSDictionary
    }
}
@_cdecl("edith_extension_create") public func create() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: MainActor.assumeIsolated { UInt(bitPattern: Unmanaged.passRetained(FixtureRuntime()).toOpaque()) })
}
`,
    );
    if (role === "cameraProvider" && process.env.CAMERA_PROVIDER_LIBRARY) {
      await copyFile(
        resolve(process.env.CAMERA_PROVIDER_LIBRARY),
        join(contents, "MacOS/Runtime"),
      );
    } else {
      execFileSync("swiftc", [
        "-emit-library",
        "-module-name",
        "CameraFixture",
        "-F",
        join(hostApp, "Contents/Frameworks"),
        "-framework",
        "Sparkle",
        source,
        "-o",
        join(contents, "MacOS/Runtime"),
      ]);
    }
    const info = {
      CFBundleIdentifier: `com.pulkit.edith.extensions.virtualCamera.${role}`,
      CFBundleExecutable: "Runtime",
      CFBundlePackageType: "BNDL",
      CFBundleShortVersionString: "1.0.0",
      EdithHostABI: "edith-host-1",
    };
    const json = join(root, `${role}.json`);
    await writeFile(json, JSON.stringify(info));
    execFileSync("python3", [
      "-c",
      "import json,plistlib,sys;plistlib.dump(json.load(open(sys.argv[1])),open(sys.argv[2],'wb'))",
      json,
      join(contents, "Info.plist"),
    ]);
    execFileSync("codesign", [
      "--force",
      "--sign",
      "-",
      join(payloads, `${role}.bundle`),
    ]);
  }
  const inputHash = createHash("sha256")
    .update(await readFile(join(hostApp, "Contents/MacOS/Edith")))
    .digest("hex");
  const output = await buildCameraCarrier({
    hostApp,
    payloadDirectory: payloads,
    output: join(root, "output"),
    version: "1.0.0",
    hostABI: "edith-host-1",
    development: true,
    definition: {
      role: "cameraCarrier",
      providerRole: "cameraProvider",
      applicationIdentifier:
        "com.pulkit.edith.tests.camera-fixture.cameraCarrier",
      extensionIdentifier: "com.pulkit.edith.tests.camera-fixture.camera",
      minimumSystemVersion: 14,
      installEntitlement: "com.apple.developer.system-extension.install",
    },
  });
  await requireRegularTree(output.directory);
  for (const [role, bundle] of [
    ["cameraCarrier", output.directory],
    ["cameraProvider", output.provider],
  ]) {
    const executable = join(bundle, "Contents/MacOS/Edith");
    const result = JSON.parse(
      execFileSync(executable, ["--contained-extension-probe"], {
        env: { ...process.env, EDITH_EXTENSION_FIXTURE_HOME: root },
        encoding: "utf8",
        timeout: 15000,
      }),
    );
    assert.equal(result.ok, true);
    assert.equal(result.payloadLoaded, true);
    assert.equal(result.role, role);
    if (role === "cameraProvider" && process.env.CAMERA_PROVIDER_LIBRARY) {
      assert.equal(result.providerServiceStarted, false);
    } else {
      assert.equal(result.sparkleGUIControllerInitialized, true);
      assert.equal(result.sparkleGUIResourcesLoaded, true);
      assert.equal(result.exposedWindows, 0);
    }
    assert.equal(
      output.provenance.roles.find((item) => item.role === role)
        .executableBeforeSigningSHA256,
      inputHash,
    );
    assert.throws(() =>
      execFileSync(executable, ["--contained-extension-probe"], {
        env: {
          ...process.env,
          EDITH_EXTENSION_FIXTURE_HOME: "/private/tmp/unrelated-camera-fixture",
        },
        stdio: "pipe",
        timeout: 15000,
      }),
    );
    assert.throws(() =>
      execFileSync(
        executable,
        ["--contained-extension-role", "/tmp/arbitrary"],
        {
          env: { ...process.env, EDITH_EXTENSION_FIXTURE_HOME: root },
          stdio: "pipe",
          timeout: 15000,
        },
      ),
    );
  }
  const tamper = join(root, "tampered.app");
  execFileSync("/bin/cp", ["-R", output.directory, tamper]);
  await writeFile(
    join(
      tamper,
      "Contents/PlugIns/cameraCarrier.bundle/Contents/MacOS/Runtime",
    ),
    "invalid",
  );
  assert.throws(() =>
    execFileSync(
      join(tamper, "Contents/MacOS/Edith"),
      ["--contained-extension-probe"],
      {
        env: { ...process.env, EDITH_EXTENSION_FIXTURE_HOME: root },
        stdio: "pipe",
        timeout: 15000,
      },
    ),
  );
  console.log(
    JSON.stringify({
      containedRolesLaunched: roles,
      hostExecutableProvenanceValidated: true,
      linkedRuntimeFrameworksValidated: true,
      sparkleGUIControllerAndResourcesValidated: true,
      actualProviderPayloadValidated: Boolean(
        process.env.CAMERA_PROVIDER_LIBRARY,
      ),
      archiveSymlinks: 0,
      signatureTamperRejected: true,
      fixtureScopeRejected: true,
    }),
  );
} finally {
  await rm(root, { recursive: true, force: true });
}
