import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFile,
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
  buildExtensionUICarrier,
  extensionUICarrierMetadata,
  extensionUICarrierPaths,
  extensionUIExtensionPoint,
} from "./build-extension-ui-carrier.mjs";

const fixture = {
  hostIdentifier: "com.pulkit.edith.tests.ui",
  id: "calendar",
  version: "1.0.0",
  hostABI: "edith-host-1",
  executableSHA256: "a".repeat(64),
  hostCodeRequirement:
    'identifier "com.pulkit.edith.tests.ui" and anchor apple generic',
  hostExecutablePath:
    "/tmp/edith-ui-carrier-synthetic/Edith.app/Contents/MacOS/Edith",
};

describe("extension UI carriers", () => {
  test("external extension point declares public sandboxed UI with the legacy supported format", () => {
    const point = extensionUIExtensionPoint(fixture.hostIdentifier);
    expect(point.EXVersion).toBe(1);
    expect(point[`${fixture.hostIdentifier}.ExtensionUI`]).toEqual({
      EXExtensionPointIsPublic: true,
      EXExtensionPointName: "ExtensionUI",
      EXPresentsUserInterface: true,
      EXRequiredEntitlements: { "com.apple.security.app-sandbox": true },
      EXRequiresEnhancedSecurity: false,
      EXSupportedPlatforms: ["macOS"],
      _EXScopeRestriction: "none",
    });
    expect(() => extensionUIExtensionPoint("../host")).toThrow();
  });
  test("compatible updates keep approval identity and record exact payload version", () => {
    const first = extensionUICarrierMetadata(fixture);
    const second = extensionUICarrierMetadata({ ...fixture, version: "2.0.0" });
    expect(first.applicationIdentifier).toBe(
      "com.pulkit.edith.tests.ui.extension.calendar",
    );
    expect(first.workerIdentifier).toBe(
      `${first.applicationIdentifier}.worker`,
    );
    expect(second.applicationIdentifier).toBe(first.applicationIdentifier);
    expect(second.workerIdentifier).toBe(first.workerIdentifier);
    expect(first.attributes.EdithExtensionVersion).toBe("1.0.0");
    expect(second.attributes.EdithExtensionVersion).toBe("2.0.0");
    expect(first.attributes.EdithHostCodeRequirement).toBe(
      fixture.hostCodeRequirement,
    );
    expect(first.attributes.EdithHostExecutablePath).toBe(
      fixture.hostExecutablePath,
    );
    expect(first.attributes.EdithExecutableProvenance).toBe(
      fixture.executableSHA256,
    );
    expect(first.attributes.EdithPayloadRelativePath).toBe(
      "Contents/Resources/Payload",
    );
    expect(first.extensionPointIdentifier).toBe(
      "com.pulkit.edith.tests.ui.ExtensionUI",
    );
  });

  test("individual extensions and development slots have separate approved identities", () => {
    const calendar = extensionUICarrierMetadata(fixture);
    const music = extensionUICarrierMetadata({ ...fixture, id: "music" });
    const otherHost = extensionUICarrierMetadata({
      ...fixture,
      hostIdentifier: "com.pulkit.edith.tests.other",
    });
    expect(calendar.workerIdentifier).not.toBe(music.workerIdentifier);
    expect(calendar.workerIdentifier).not.toBe(otherHost.workerIdentifier);
    expect(calendar.extensionPointIdentifier).not.toBe(
      otherHost.extensionPointIdentifier,
    );
  });

  test.each([
    ["id", "../calendar"],
    ["id", "calendar.worker"],
    ["id", ""],
    ["hostIdentifier", "../../host"],
    ["hostIdentifier", "host"],
    ["version", "1.0.0/../2"],
    ["version", "1.0"],
    ["hostABI", "bad\nvalue"],
    ["hostABI", ""],
    ["executableSHA256", "a".repeat(63)],
    ["executableSHA256", "g".repeat(64)],
    ["hostCodeRequirement", ""],
    ["hostCodeRequirement", "true\nfalse"],
    ["hostCodeRequirement", "x".repeat(4097)],
    ["hostExecutablePath", "relative/Edith"],
    ["hostExecutablePath", "/tmp/../Edith"],
    ["hostExecutablePath", "/tmp/Edith\n"],
  ])("invalid %s metadata fails before packaging", (field, value) => {
    expect(() =>
      extensionUICarrierMetadata({ ...fixture, [field]: value }),
    ).toThrow();
  });

  test("published production carriers seal the installed host path", () => {
    expect(() =>
      extensionUICarrierMetadata({
        ...fixture,
        hostIdentifier: "com.pulkit.edith",
      }),
    ).toThrow();
    const metadata = extensionUICarrierMetadata({
      ...fixture,
      hostIdentifier: "com.pulkit.edith",
      hostExecutablePath: "/Applications/Edith.app/Contents/MacOS/Edith",
    });
    expect(metadata.attributes.EdithHostExecutablePath).toBe(
      "/Applications/Edith.app/Contents/MacOS/Edith",
    );
  });

  test("a second build cannot overwrite an already assembled carrier", async () => {
    const root = await mkdtemp(join(tmpdir(), "edith-ui-carrier-test-"));
    try {
      const paths = await extensionUICarrierPaths(root);
      expect(paths.worker).toBe(
        join(
          root,
          "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex",
        ),
      );
      await mkdir(paths.carrier);
      await writeFile(
        join(paths.carrier, "synthetic.txt"),
        "Synthetic carrier",
      );
      await expect(extensionUICarrierPaths(root)).rejects.toThrow(
        "already exists",
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("package symlinks fail before any contained executable is copied", async () => {
    const root = await mkdtemp(join(tmpdir(), "edith-ui-carrier-test-"));
    try {
      const payload = join(root, "payload");
      await mkdir(payload);
      await symlink(root, join(payload, "outside"));
      await expect(extensionUICarrierPaths(payload)).rejects.toThrow(
        "regular files",
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("missing frozen host and production signing identity fail before copying", async () => {
    await expect(buildExtensionUICarrier({})).rejects.toThrow("incomplete");
    await expect(
      buildExtensionUICarrier({
        hostApp: "/tmp/synthetic-host.app",
        payloadDirectory: "/tmp/synthetic-payload",
        identity: "",
      }),
    ).rejects.toThrow("incomplete");
  });

  test.skipIf(
    process.platform !== "darwin" || !process.env.EDITH_UI_CARRIER_TEMPLATE,
  )(
    "real signed carrier copies the frozen executable into its sandboxed worker",
    async () => {
      const root = await mkdtemp(
        join(tmpdir(), "edith-ui-carrier-signed-test-"),
      );
      try {
        const host = join(root, "Edith.app");
        const contents = join(host, "Contents");
        await mkdir(join(contents, "MacOS"), { recursive: true });
        const artwork = join(contents, "Resources/EdithHost_EdithHost.bundle");
        await mkdir(artwork, { recursive: true });
        await copyFile(
          "Packages/EdithHost/Sources/EdithHost/Resources/MarketplaceArtwork.lzma",
          join(artwork, "MarketplaceArtwork.lzma"),
        );
        const executable = join(contents, "MacOS/Edith");
        await copyFile(process.env.EDITH_UI_CARRIER_TEMPLATE, executable);
        const writePlist = (path, value) =>
          execFileSync(
            "python3",
            [
              "-c",
              "import json,plistlib,sys; plistlib.dump(json.loads(sys.argv[1]),open(sys.argv[2],'wb'))",
              JSON.stringify(value),
              path,
            ],
            { stdio: "pipe" },
          );
        const readPlist = (path) =>
          JSON.parse(
            execFileSync(
              "python3",
              [
                "-c",
                "import json,plistlib,sys; print(json.dumps(plistlib.load(open(sys.argv[1],'rb'))))",
                path,
              ],
              { encoding: "utf8", stdio: "pipe" },
            ),
          );
        writePlist(join(contents, "Info.plist"), {
          CFBundleIdentifier: fixture.hostIdentifier,
          CFBundleExecutable: "Edith",
          CFBundleName: "Synthetic UI Carrier Host",
          CFBundlePackageType: "APPL",
          CFBundleShortVersionString: "1.0.0",
          CFBundleVersion: "1",
          LSMinimumSystemVersion: "14.0",
        });
        execFileSync("codesign", ["--force", "--sign", "-", host], {
          stdio: "pipe",
        });
        const digest = createHash("sha256")
          .update(await readFile(executable))
          .digest("hex");
        const payload = join(root, "calendar");
        await mkdir(payload);
        const role = join(payload, "app.bundle");
        await mkdir(join(role, "Contents/MacOS"), { recursive: true });
        await copyFile("/usr/bin/true", join(role, "Contents/MacOS/Runtime"));
        writePlist(join(role, "Contents/Info.plist"), {
          CFBundleIdentifier: "com.pulkit.edith.extensions.calendar.app",
          CFBundleExecutable: "Runtime",
          CFBundlePackageType: "BNDL",
          CFBundleShortVersionString: "1.0.0",
          CFBundleVersion: "1",
          EdithHostABI: "edith-host-1",
        });
        execFileSync("codesign", ["--force", "--sign", "-", role], {
          stdio: "pipe",
        });
        const roleBytes = await readFile(join(role, "Contents/MacOS/Runtime"));
        const built = await buildExtensionUICarrier({
          hostApp: host,
          payloadDirectory: payload,
          id: "calendar",
          version: "1.0.0",
          hostABI: "edith-host-1",
          development: true,
        });
        expect(built.executableSHA256).toBe(digest);
        expect(
          await readFile(join(payload, "ExtensionCarrier.app/Contents/Resources/EdithHost_EdithHost.bundle/MarketplaceArtwork.lzma")),
        ).toEqual(await readFile(join(artwork, "MarketplaceArtwork.lzma")));
        expect(
          await readFile(join(payload, "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/EdithHost_EdithHost.bundle/MarketplaceArtwork.lzma")),
        ).toEqual(await readFile(join(artwork, "MarketplaceArtwork.lzma")));


        expect(
          createHash("sha256")
            .update(await readFile(executable))
            .digest("hex"),
        ).toBe(digest);
        const carrier = join(payload, "ExtensionCarrier.app");
        const worker = join(
          carrier,
          "Contents/Extensions/ExtensionWorker.appex",
        );
        const carrierInfo = readPlist(join(carrier, "Contents/Info.plist"));
        const workerInfo = readPlist(join(worker, "Contents/Info.plist"));
        const selectedPayload = join(
          worker,
          "Contents/Resources/Payload/calendar",
        );
        expect(
          await readFile(
            join(selectedPayload, "app.bundle/Contents/MacOS/Runtime"),
          ),
        ).toEqual(roleBytes);
        await expect(
          readFile(join(role, "Contents/MacOS/Runtime")),
        ).rejects.toThrow();
        expect(workerInfo.EdithPayloadRelativePath).toBe(
          "Contents/Resources/Payload",
        );
        expect(
          JSON.parse(
            await readFile(join(selectedPayload, "package.json"), "utf8"),
          ),
        ).toEqual({
          id: "calendar",
          version: "1.0.0",
          hostABI: "edith-host-1",
          architecture: "arm64",
          dependencies: [],
        });
        expect(carrierInfo.CFBundleIdentifier).toBe(
          `${fixture.hostIdentifier}.extension.calendar`,
        );
        expect(workerInfo.CFBundleIdentifier).toBe(
          `${carrierInfo.CFBundleIdentifier}.worker`,
        );
        expect(workerInfo.EdithExecutableProvenance).toBe(digest);
        expect(workerInfo.EdithHostExecutablePath).toBe(
          await realpath(executable),
        );
        expect(workerInfo.EdithExtensionVersion).toBe("1.0.0");
        expect(workerInfo.EdithHostCodeRequirement.length).toBeGreaterThan(0);
        expect(
          workerInfo.EXAppExtensionAttributes.EXExtensionPointIdentifier,
        ).toBe(`${fixture.hostIdentifier}.ExtensionUI`);
        const entitlementsFile = join(root, "worker-entitlements.plist");
        execFileSync(
          "codesign",
          ["-d", "--entitlements", entitlementsFile, "--xml", worker],
          {
            stdio: "pipe",
          },
        );
        const entitlements = await readFile(entitlementsFile);
        const sandbox = JSON.parse(
          execFileSync(
            "python3",
            [
              "-c",
              "import json,plistlib,sys; print(json.dumps(plistlib.loads(sys.stdin.buffer.read())))",
            ],
            { input: entitlements, encoding: "utf8", stdio: "pipe" },
          ),
        );
        expect(sandbox["com.apple.security.app-sandbox"]).toBe(true);
        expect(Object.keys(sandbox)).toEqual([
          "com.apple.security.app-sandbox",
        ]);
        execFileSync("codesign", ["--verify", "--deep", "--strict", carrier], {
          stdio: "pipe",
        });
        if (process.env.EDITH_UI_CARRIER_VERIFIER) {
          await writeFile(
            join(payload, "package.json"),
            JSON.stringify({
              id: "calendar",
              version: "1.0.0",
              hostABI: "edith-host-1",
              architecture: "arm64",
              dependencies: [],
            }),
          );
          const verified = JSON.parse(
            execFileSync(
              process.env.EDITH_UI_CARRIER_VERIFIER,
              ["verify-ui-carrier", payload, fixture.hostIdentifier],
              { encoding: "utf8", stdio: "pipe" },
            ),
          );
          expect(verified).toEqual({
            identityValidated: true,
            signatureVerified: true,
            sandboxVerified: true,
          });
        }
        await expect(
          buildExtensionUICarrier({
            hostApp: host,
            payloadDirectory: payload,
            id: "calendar",
            version: "1.0.0",
            hostABI: "edith-host-1",
            development: true,
          }),
        ).rejects.toThrow("already exists");
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    },
  );
});
