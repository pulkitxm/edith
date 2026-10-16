import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  access,
  chmod,
  copyFile,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  buildExtensionPackage,
  extensionPackageHostContext,
} from "./build-extension-package.mjs";

test("release rejects alternate frozen host context before reading sources or mutating output", async () => {
  const scope = await mkdtemp(join(tmpdir(), "native-policy-release-context-"));
  try {
    const root = join(scope, "absent-synthetic-source");
    const output = join(scope, "output");
    await mkdir(output);
    await writeFile(join(output, "retained"), "synthetic retained output");
    for (const development of [false, undefined, "true", 1]) {
      await expect(
        buildExtensionPackage({
          root,
          output,
          id: "mock",
          development,
          developmentHostRoot: join(scope, "real-source"),
        }),
      ).rejects.toThrow(
        "alternate frozen host source requires a development package",
      );
      await expect(access(root)).rejects.toThrow();
      expect(await readdir(output)).toEqual(["retained"]);
      expect(await readFile(join(output, "retained"), "utf8")).toBe(
        "synthetic retained output",
      );
    }
  } finally {
    await rm(scope, { recursive: true, force: true });
  }
});

test("production defaults preserve the strict source workspace and explicit signed host inputs", () => {
  const root = "/source/current";
  expect(extensionPackageHostContext({ root, development: false })).toEqual({
    root,
    hostApp: undefined,
    frozenHostApp: resolve(root, "local/minimal-host/Edith.app"),
    carrierTools: resolve(root, "local/minimal-host/carrier-tools"),
  });
  const environment = {
    EXTENSION_CONTAINING_HOST_APP: "/source/current/local/signed/Edith.app",
    EXTENSION_UI_CARRIER_TOOLS: "/source/current/local/admitted-carrier",
  };
  expect(
    extensionPackageHostContext({ root, development: false, environment }),
  ).toEqual({
    root,
    hostApp: environment.EXTENSION_CONTAINING_HOST_APP,
    frozenHostApp: resolve(root, "local/minimal-host/Edith.app"),
    carrierTools: environment.EXTENSION_UI_CARRIER_TOOLS,
  });
});

test("development binds host verifier inputs to the actual source context independently of package sources", () => {
  const root = "/synthetic/native-policy";
  const developmentHostRoot = "/source/current";
  const context = extensionPackageHostContext({
    root,
    development: true,
    developmentHostRoot,
  });
  expect(context).toEqual({
    root: developmentHostRoot,
    hostApp: resolve(developmentHostRoot, "local/minimal-host/Edith.app"),
    frozenHostApp: resolve(developmentHostRoot, "local/minimal-host/Edith.app"),
    carrierTools: resolve(
      developmentHostRoot,
      "local/minimal-host/carrier-tools",
    ),
  });
  expect(Object.isFrozen(context)).toBe(true);
  expect(context.root).not.toBe(root);
  const defaults = extensionPackageHostContext({ root, development: true });
  expect(defaults.root).toBe(root);
  expect(defaults.hostApp).toBe(resolve(root, "local/minimal-host/Edith.app"));
});

test("camera voice fixture requires the real host prerequisite and selects development-only source context", async () => {
  const recipe = await readFile(
    new URL("../Makefile", import.meta.url),
    "utf8",
  );
  expect(recipe).toMatch(/^ci-extension-camera-voice: host$/m);
  const commands = recipe.match(
    /^ci-extension-camera-voice: host\n((?:\t[^\n]*\n)+)/m,
  )[1];
  const signedContext = commands.indexOf(
    "bun test scripts/extension-development-host-context.test.js",
  );
  expect(signedContext).toBeGreaterThanOrEqual(0);
  expect(signedContext).toBeLessThan(
    commands.indexOf("bun scripts/test-extension-native-policy.mjs"),
  );
  const fixture = await readFile(
    new URL("./test-extension-native-policy.mjs", import.meta.url),
    "utf8",
  );
  expect(fixture).toContain("developmentHostRoot: process.cwd()");
  expect(fixture).toContain("development: true");
});

describe.skipIf(process.platform !== "darwin")(
  "signed synthetic host context",
  () => {
    let scope;
    let packageRoot;
    let hostRoot;
    let context;
    let resource;
    let environment;
    const verify = (path) =>
      execFileSync(
        "/usr/bin/codesign",
        ["--verify", "--deep", "--strict", path],
        { env: environment, stdio: "pipe", timeout: 10000, maxBuffer: 65536 },
      );

    beforeAll(async () => {
      scope = await realpath(
        await mkdtemp(join(tmpdir(), "camera-host-signature-")),
      );
      await chmod(scope, 0o700);
      packageRoot = join(scope, "synthetic-package");
      hostRoot = join(scope, "source-host");
      for (const directory of [
        packageRoot,
        hostRoot,
        join(scope, "home"),
        join(scope, "tmp"),
      ])
        await mkdir(directory, { mode: 0o700 });
      environment = {
        PATH: "/usr/bin:/bin",
        HOME: join(scope, "home"),
        TMPDIR: join(scope, "tmp"),
      };
      context = extensionPackageHostContext({
        root: packageRoot,
        development: true,
        developmentHostRoot: hostRoot,
        environment,
      });
      const contents = join(context.hostApp, "Contents");
      await mkdir(join(contents, "MacOS"), { recursive: true, mode: 0o700 });
      await mkdir(join(contents, "Resources"), { mode: 0o700 });
      const executable = join(contents, "MacOS/Edith");
      await copyFile("/usr/bin/true", executable);
      await chmod(executable, 0o700);
      const identifier = `com.pulkit.edith.tests.synthetic-host.${crypto.randomUUID()}`;
      const info = join(contents, "Info.plist");
      await writeFile(
        info,
        JSON.stringify({
          CFBundleIdentifier: identifier,
          CFBundleExecutable: "Edith",
          CFBundlePackageType: "APPL",
          CFBundleShortVersionString: "1.0.0",
          CFBundleVersion: "1",
        }),
        { mode: 0o600 },
      );
      resource = join(contents, "Resources/synthetic.txt");
      await writeFile(resource, "synthetic sealed host", { mode: 0o600 });
      execFileSync("/usr/bin/plutil", ["-convert", "xml1", info], {
        env: environment,
        stdio: "pipe",
        timeout: 10000,
      });
      execFileSync(
        "/usr/bin/codesign",
        [
          "--force",
          "--sign",
          "-",
          "--timestamp=none",
          "--identifier",
          identifier,
          context.hostApp,
        ],
        { env: environment, stdio: "pipe", timeout: 10000 },
      );
    }, 30000);

    afterAll(async () => {
      if (scope) await rm(scope, { recursive: true, force: true });
    });

    test("the development source context resolves one actual signed host rather than the absent package-local host", async () => {
      expect(context.hostApp).toBe(
        join(hostRoot, "local/minimal-host/Edith.app"),
      );
      expect(context.frozenHostApp).toBe(context.hostApp);
      expect(context.carrierTools).toBe(
        join(hostRoot, "local/minimal-host/carrier-tools"),
      );
      expect(() => verify(context.hostApp)).not.toThrow();
      const previous = extensionPackageHostContext({
        root: packageRoot,
        development: true,
        environment,
      });
      await expect(access(previous.hostApp)).rejects.toThrow();
      expect(() => verify(previous.hostApp)).toThrow();
    });

    test("the selected source cannot verify changed bytes even when its context and executable identity are unchanged", async () => {
      const bytes = await readFile(resource);
      try {
        await writeFile(resource, "changed sealed host", { mode: 0o600 });
        expect(() => verify(context.hostApp)).toThrow();
      } finally {
        await writeFile(resource, bytes, { mode: 0o600 });
      }
      expect(() => verify(context.hostApp)).not.toThrow();
    });

    test("an actual valid signed alternate host still cannot become a production source override", () => {
      expect(() => verify(context.hostApp)).not.toThrow();
      expect(() =>
        extensionPackageHostContext({
          root: packageRoot,
          development: false,
          developmentHostRoot: hostRoot,
          environment,
        }),
      ).toThrow("requires a development package");
    });
  },
);
