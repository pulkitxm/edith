import { describe, expect, test } from "bun:test";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmod,
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  buildExtensionUICarrier,
  extensionUICarrierMetadata,
  extensionUICarrierPaths,
  extensionUIExtensionPoint,
  extensionUIWorkerEntitlements,
  readBoundedCarrierBytes,
  readFrozenUICarrier,
} from "./build-extension-ui-carrier.mjs";

const fixture = {
  hostIdentifier: "com.pulkit.edith.tests.ui",
  id: "calendar",
  version: "1.0.0",
  hostABI: "edith-host-1",
  executableSHA256: "a".repeat(64),
  carrierExecutableSHA256: "b".repeat(64),
  hostCodeRequirement:
    'identifier "com.pulkit.edith.tests.ui" and anchor apple generic',
  hostExecutablePath:
    "/tmp/edith-ui-carrier-synthetic/Edith.app/Contents/MacOS/Edith",
};

async function carrierFixtureRoot(prefix) {
  const directory = resolve("local");
  await mkdir(directory, { recursive: true });
  return mkdtemp(join(directory, prefix));
}

async function frozenCarrierTools(host, executable) {
  const root = process.cwd();
  const temporary = dirname(host);
  const products = join(temporary, "products");
  const tools = join(temporary, "tools");
  const resource = "EdithHost_EdithHostCore.bundle/index.json";
  const index = await readFile(
    "Packages/EdithHost/Sources/EdithHostCore/Resources/index.json",
  );
  await mkdir(join(host, "Contents/Resources"), { recursive: true });
  await writeFile(join(host, "Contents/Resources/index.json"), index);
  await mkdir(join(products, dirname(resource)), { recursive: true });
  await writeFile(join(products, resource), index);
  for (const name of ["HostLifecycleHarness", "MarketplaceHarness"]) {
    await writeFile(join(products, name), "synthetic lifecycle tool", {
      mode: 0o755,
    });
  }
  await copyFile(executable, join(products, "EdithExtensionCarrier"));
  await chmod(join(products, "EdithExtensionCarrier"), 0o755);
  const sourceCommit = execFileSync("git", ["rev-parse", "HEAD"], {
    encoding: "utf8",
  }).trim();
  await writeFile(
    join(temporary, "build-metadata.json"),
    JSON.stringify({
      sourceCommit,
      sourceTreeDirty: false,
      hostExecutableSHA256: createHash("sha256")
        .update(await readFile(join(host, "Contents/MacOS/Edith")))
        .digest("hex"),
    }),
  );
  execFileSync(
    "python3",
    [
      "-B",
      "scripts/package_extension_lifecycle_tools.py",
      "--root",
      root,
      "--host",
      host,
      "--host-products",
      products,
      "--marketplace-products",
      products,
      "--output",
      tools,
    ],
    { stdio: "pipe" },
  );
  return { root, frozenHostApp: host, carrierTools: tools };
}

describe("extension UI carriers", () => {
  test.each(["exact", "short", "growing"])(
    "bounded carrier reads reject incomplete or growing input: %s",
    async (kind) => {
      const expected = Buffer.from([1, 2, 3, 4]);
      let consumed = 0;
      const descriptor = {
        async read(buffer, offset, length) {
          const available =
            kind === "growing" ? Infinity : kind === "short" ? 3 : 4;
          const bytesRead = Math.min(length, 2, available - consumed);
          for (let index = 0; index < bytesRead; index++)
            buffer[offset + index] =
              expected[(consumed + index) % expected.length];
          consumed += bytesRead;
          return { bytesRead };
        },
      };
      if (kind === "exact")
        expect(
          await readBoundedCarrierBytes(descriptor, expected.length),
        ).toEqual(expected);
      else
        await expect(
          readBoundedCarrierBytes(descriptor, expected.length),
        ).rejects.toThrow("bound");
      expect(consumed).toBeLessThanOrEqual(expected.length + 1);
    },
  );

  test("frozen carrier bytes are independently source bound and reject receipt tampering", async () => {
    const root = await carrierFixtureRoot("carrier-input-");
    try {
      const host = join(root, "Edith.app");
      await mkdir(join(host, "Contents/MacOS"), { recursive: true });
      const executable = join(host, "Contents/MacOS/Edith");
      await writeFile(executable, "synthetic inner executable", {
        mode: 0o755,
      });
      const carrier = join(root, "carrier");
      await writeFile(carrier, "synthetic independent outer executable", {
        mode: 0o755,
      });
      const frozen = await frozenCarrierTools(host, carrier);
      const input = await readFrozenUICarrier(frozen);
      expect(input.bytes.toString()).toBe(
        "synthetic independent outer executable",
      );
      expect(input.sha256).not.toBe(input.hostExecutableSHA256);
      const receiptPath = join(frozen.carrierTools, "lifecycle-tools.json");
      const original = await readFile(receiptPath);
      for (const field of ["sourceCommit", "hostExecutableSHA256"]) {
        const receipt = JSON.parse(original);
        receipt[field] = "0".repeat(field === "sourceCommit" ? 40 : 64);
        await writeFile(receiptPath, JSON.stringify(receipt));
        await expect(readFrozenUICarrier(frozen)).rejects.toThrow();
      }
      await writeFile(receiptPath, original);
      const selected = join(frozen.carrierTools, "EdithExtensionCarrier");
      await writeFile(selected, "tampered executable");
      await expect(readFrozenUICarrier(frozen)).rejects.toThrow();
      await rm(selected);
      await symlink(carrier, selected);
      await expect(readFrozenUICarrier(frozen)).rejects.toThrow();
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("outer target retains the original check-in loop without host linkage or payload", async () => {
    const entry = await readFile(
      "Packages/EdithHost/Sources/EdithExtensionCarrier/Entry.swift",
      "utf8",
    );
    const original = await readFile(
      "Packages/EdithHost/Sources/EdithHost/HostEntry.swift",
      "utf8",
    );
    for (const retained of [
      "application.setActivationPolicy(.prohibited)",
      "application.delegate = delegate",
      "withExtendedLifetime(delegate) { application.run() }",
      "DispatchQueue.main.asyncAfter(deadline: .now() + 0.25)",
      "NSApplication.shared.terminate(nil)",
    ]) {
      expect(entry).toContain(retained);
      expect(original).toContain(retained);
    }
    expect(entry).toContain(
      'Array(CommandLine.arguments.dropFirst()) == ["--extension-ui-carrier"]',
    );
    expect(entry.match(/^import .+$/gm)).toEqual([
      "import AppKit",
      "import Foundation",
    ]);
    const manifest = await readFile("Packages/EdithHost/Package.swift", "utf8");
    const target = manifest.slice(
      manifest.indexOf('name: "EdithExtensionCarrier",\n'),
      manifest.indexOf('name: "EdithHostCore",'),
    );
    expect(target).not.toContain("dependencies:");
    expect(target).not.toContain("resources:");
    const builder = await readFile("scripts/build-minimal-host.mjs", "utf8");
    expect(builder).toContain("extensionPayloadBytes: 0");
    expect(builder).toContain('join(destination, "..", "carrier-tools")');
    expect(builder).toContain(
      'carrierBuild[carrierBuild.indexOf("EdithHost")] = "EdithExtensionCarrier"',
    );
    expect(builder).toMatch(/"--carrier-only",\s*"--carrier-products"/);
  });

  test.skipIf(process.platform !== "darwin")(
    "signed sandboxed Music and Notch workers alone can connect to synthetic loopback",
    async () => {
      const root = await carrierFixtureRoot("edith-ui-network-test-");
      const server = createServer((socket) => socket.end("S"));
      try {
        await new Promise((resolve, reject) => {
          server.once("error", reject);
          server.listen(0, "127.0.0.1", resolve);
        });
        const port = server.address().port;
        const host = join(root, "Edith.app");
        const contents = join(host, "Contents");
        await mkdir(join(contents, "MacOS"), { recursive: true });
        await mkdir(join(contents, "Resources/EdithHost_EdithHost.bundle"), {
          recursive: true,
        });
        await copyFile(
          "Packages/EdithHost/Sources/EdithHost/Resources/MarketplaceArtwork.lzma",
          join(
            contents,
            "Resources/EdithHost_EdithHost.bundle/MarketplaceArtwork.lzma",
          ),
        );
        const source = join(root, "network.c");
        await writeFile(
          source,
          `#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/time.h>
#include <stdio.h>
int main(int argc, char **argv) {
  if (argc != 2) return 65;
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return 64;
  struct timeval timeout = {2, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
  struct sockaddr_in address = {0};
  address.sin_family = AF_INET;
  address.sin_port = htons(atoi(argv[1]));
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { close(fd); return 64; }
  char received = 0;
  ssize_t bytes = read(fd, &received, 1);
  close(fd);
  if (bytes != 1 || received != 'S') return 66;
  puts("synthetic-network-ok");
  return 0;
}
`,
        );
        execFileSync(
          "xcrun",
          ["clang", source, "-o", join(contents, "MacOS/Edith")],
          { stdio: "pipe" },
        );
        execFileSync(
          "python3",
          [
            "-c",
            "import plistlib,sys; plistlib.dump({'CFBundleIdentifier':'com.pulkit.edith.tests.network','CFBundleExecutable':'Edith','CFBundleName':'Synthetic Network Host','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0.0','CFBundleVersion':'1','LSMinimumSystemVersion':'14.0'},open(sys.argv[1],'wb'))",
            join(contents, "Info.plist"),
          ],
          { stdio: "pipe" },
        );
        execFileSync("codesign", ["--force", "--sign", "-", host], {
          stdio: "pipe",
        });
        const frozen = await frozenCarrierTools(
          host,
          join(contents, "MacOS/Edith"),
        );
        for (const id of ["music", "notchShelf", "calendar"]) {
          const payload = join(root, id);
          await mkdir(payload);
          await buildExtensionUICarrier({
            ...frozen,
            minimumSystemVersion: "14.0.0",
            hostApp: host,
            payloadDirectory: payload,
            id,
            version: "1.0.0",
            hostABI: "edith-host-2",
            development: true,
          });
          const executable = join(
            payload,
            "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith",
          );
          const result = await new Promise((resolve, reject) => {
            const child = spawn(executable, [String(port)], {
              cwd: "/",
              stdio: ["ignore", "pipe", "ignore"],
            });
            let output = "";
            const deadline = setTimeout(() => {
              child.kill("SIGKILL");
              reject(
                new Error("Synthetic network worker exceeded its deadline"),
              );
            }, 5000);
            child.stdout.on("data", (chunk) => {
              output += chunk;
            });
            child.once("error", (error) => {
              clearTimeout(deadline);
              reject(error);
            });
            child.once("close", (code) => {
              clearTimeout(deadline);
              resolve({ code, output });
            });
          });
          expect(result).toEqual(
            id === "calendar"
              ? { code: 64, output: "" }
              : { code: 0, output: "synthetic-network-ok\n" },
          );
        }
      } finally {
        await new Promise((resolve) => server.close(resolve));
        await rm(root, { recursive: true, force: true });
      }
    },
    30000,
  );
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
  test("only Music and Notch receive the fixed outbound network capability", () => {
    const sandbox = { "com.apple.security.app-sandbox": true };
    for (const id of [
      "calendar",
      "camera",
      "micMute",
      "Music",
      "notchshelf",
      "other",
    ]) {
      expect(extensionUIWorkerEntitlements(id)).toEqual(sandbox);
    }
    for (const id of ["music", "notchShelf"]) {
      expect(extensionUIWorkerEntitlements(id)).toEqual({
        ...sandbox,
        "com.apple.security.network.client": true,
      });
    }
    expect(() => extensionUIWorkerEntitlements("../music")).toThrow();
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
    expect(first.attributes.EdithCarrierExecutableProvenance).toBe(
      fixture.carrierExecutableSHA256,
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
    ["carrierExecutableSHA256", "a".repeat(63)],
    ["carrierExecutableSHA256", "g".repeat(64)],
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
        minimumSystemVersion: "14.0.0",
        hostApp: "/tmp/synthetic-host.app",
        payloadDirectory: "/tmp/synthetic-payload",
        identity: "",
      }),
    ).rejects.toThrow("incomplete");
  });

  test("malformed system minimums fail before any native carrier operation", async () => {
    for (const minimumSystemVersion of [
      undefined,
      14,
      "14.4",
      "14.04.0",
      "14.4.0-beta",
    ])
      await expect(
        buildExtensionUICarrier({
          hostApp: "/tmp/synthetic-host.app",
          payloadDirectory: "/tmp/synthetic-payload",
          minimumSystemVersion,
          development: true,
        }),
      ).rejects.toThrow("Invalid system version");
  });

  for (const id of ["calendar", "music", "notchShelf"]) {
    test.skipIf(
      process.platform !== "darwin" || !process.env.EDITH_UI_CARRIER_TEMPLATE,
    )(
      `real signed ${id} carrier restricts its sandboxed worker capabilities`,
      async () => {
        const root = await carrierFixtureRoot("edith-ui-carrier-signed-test-");
        try {
          const host = join(root, "Edith.app");
          const contents = join(host, "Contents");
          await mkdir(join(contents, "MacOS"), { recursive: true });
          const artwork = join(
            contents,
            "Resources/EdithHost_EdithHost.bundle",
          );
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
          const frozen = await frozenCarrierTools(host, executable);
          const carrierDigest = createHash("sha256")
            .update(
              await readFile(
                join(frozen.carrierTools, "EdithExtensionCarrier"),
              ),
            )
            .digest("hex");
          const digest = createHash("sha256")
            .update(await readFile(executable))
            .digest("hex");
          const payload = join(root, id);
          await mkdir(payload);
          const role = join(payload, "app.bundle");
          await mkdir(join(role, "Contents/MacOS"), { recursive: true });
          await copyFile("/usr/bin/true", join(role, "Contents/MacOS/Runtime"));
          writePlist(join(role, "Contents/Info.plist"), {
            CFBundleIdentifier: `com.pulkit.edith.extensions.${id}.app`,
            CFBundleExecutable: "Runtime",
            CFBundlePackageType: "BNDL",
            CFBundleShortVersionString: "1.0.0",
            CFBundleVersion: "1",
            EdithHostABI: "edith-host-1",
          });
          execFileSync("codesign", ["--force", "--sign", "-", role], {
            stdio: "pipe",
          });
          const roleBytes = await readFile(
            join(role, "Contents/MacOS/Runtime"),
          );
          const built = await buildExtensionUICarrier({
            ...frozen,
            minimumSystemVersion: "14.0.0",
            hostApp: host,
            payloadDirectory: payload,
            id: id,
            version: "1.0.0",
            hostABI: "edith-host-1",
            development: true,
          });
          expect(built.executableSHA256).toBe(digest);
          expect(built.carrierExecutableSHA256).toBe(carrierDigest);
          expect(
            await readFile(
              join(
                payload,
                "ExtensionCarrier.app/Contents/Resources/EdithHost_EdithHost.bundle/MarketplaceArtwork.lzma",
              ),
            ),
          ).toEqual(await readFile(join(artwork, "MarketplaceArtwork.lzma")));
          expect(
            await readFile(
              join(
                payload,
                "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/EdithHost_EdithHost.bundle/MarketplaceArtwork.lzma",
              ),
            ),
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
            `Contents/Resources/Payload/${id}`,
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
            id: id,
            version: "1.0.0",
            hostABI: "edith-host-1",
            architecture: "arm64",
            minimumSystemVersion: "14.0.0",
            dependencies: [],
          });
          expect(carrierInfo.CFBundleIdentifier).toBe(
            `${fixture.hostIdentifier}.extension.${id}`,
          );
          expect(workerInfo.CFBundleIdentifier).toBe(
            `${carrierInfo.CFBundleIdentifier}.worker`,
          );
          expect(workerInfo.EdithExecutableProvenance).toBe(digest);
          expect(workerInfo.EdithCarrierExecutableProvenance).toBe(
            carrierDigest,
          );
          expect(carrierInfo.EdithCarrierExecutableProvenance).toBe(
            carrierDigest,
          );
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
          expect(sandbox).toEqual(extensionUIWorkerEntitlements(id));
          execFileSync(
            "codesign",
            ["--verify", "--deep", "--strict", carrier],
            {
              stdio: "pipe",
            },
          );
          if (process.env.EDITH_UI_CARRIER_VERIFIER) {
            await writeFile(
              join(payload, "package.json"),
              JSON.stringify({
                id: id,
                version: "1.0.0",
                hostABI: "edith-host-1",
                architecture: "arm64",
                minimumSystemVersion: "14.0.0",
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
              ...frozen,
              minimumSystemVersion: "14.0.0",
              hostApp: host,
              payloadDirectory: payload,
              id: id,
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
  }
});
