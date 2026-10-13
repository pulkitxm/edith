import { expect, test } from "bun:test";
import {
  access,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
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
  const fixture = await readFile(
    new URL("./test-extension-native-policy.mjs", import.meta.url),
    "utf8",
  );
  expect(fixture).toContain("developmentHostRoot: process.cwd()");
  expect(fixture).toContain("development: true");
});
