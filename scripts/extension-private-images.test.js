import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  bundleNativeLibrary,
  inspectPrivateImages,
  nativePackageLinkFlags,
  privateImageName,
  privateImageToken,
  verifyPrivateImageLinkage,
} from "./build-extension-package.mjs";

const run = (file, args, options = {}) =>
  execFileSync(file, args, { stdio: "pipe", ...options });

test("private image tokens separate extensions, roles, versions and builds", () => {
  const scope = { id: "herdr", role: "app", version: "1.0.3" };
  const token = privateImageToken(scope, "engine build");
  expect(token).toMatch(/^herdr-[0-9a-f]{16}$/);
  expect(privateImageToken({ ...scope }, "engine build")).toBe(token);
  const variants = [
    privateImageToken({ ...scope, id: "terminal" }, "engine build"),
    privateImageToken({ ...scope, role: "helper" }, "engine build"),
    privateImageToken({ ...scope, version: "1.0.2" }, "engine build"),
    privateImageToken(scope, "another engine build"),
  ];
  expect(new Set([token, ...variants]).size).toBe(variants.length + 1);
  expect(privateImageName("libGhosttyTerminal.dylib", token)).toBe(
    `libGhosttyTerminal.${token}.dylib`,
  );
  expect(privateImageName("PDFium.framework", token)).toBe(
    `PDFium.${token}.framework`,
  );
  for (const name of ["../libX.dylib", "libX.so", "lib.X.dylib", ""])
    expect(() => privateImageName(name, token)).toThrow("private native");
  expect(() => privateImageName("libX.dylib", "herdr")).toThrow(
    "private native",
  );
  for (const invalid of [
    { ...scope, id: "../herdr" },
    { ...scope, role: "" },
    { ...scope, version: undefined },
  ])
    expect(() => privateImageToken(invalid, "engine build")).toThrow(
      "private native image scope",
    );
});

test("package linkage admits only its own private images and the host kit", () => {
  const scope = { id: "herdr" };
  const engine = "@rpath/libGhosttyTerminal.herdr-0123456789abcdef.dylib";
  const runtime = {
    path: "MacOS/Runtime",
    installName: "@rpath/EdithExtension_herdr_app",
    dependencies: [
      "@rpath/EdithExtension_herdr_app",
      engine,
      "@rpath/libEdithExtensionKit.dylib",
      "/usr/lib/libSystem.B.dylib",
    ],
  };
  const library = {
    path: "Frameworks/libGhosttyTerminal.herdr-0123456789abcdef.dylib",
    installName: engine,
    dependencies: [engine, "/usr/lib/libc++.1.dylib"],
  };
  expect(() =>
    verifyPrivateImageLinkage(scope, [runtime, library]),
  ).not.toThrow();
  for (const installName of [
    "@rpath/libGhosttyTerminal.dylib",
    "@rpath/libGhosttyTerminal.terminal-0123456789abcdef.dylib",
    "@rpath/libGhosttyTerminal.herdr-0123.dylib",
  ])
    expect(() =>
      verifyPrivateImageLinkage(scope, [{ ...library, installName }]),
    ).toThrow("private install name");
  expect(() =>
    verifyPrivateImageLinkage(scope, [
      library,
      { ...library, path: "Frameworks/copy.dylib" },
    ]),
  ).toThrow("private install name");
  for (const dependency of [
    "@rpath/libGhosttyTerminal.dylib",
    "@rpath/libGhosttyTerminal.terminal-0123456789abcdef.dylib",
    "@loader_path/../Frameworks/libGhosttyTerminal.dylib",
  ])
    expect(() =>
      verifyPrivateImageLinkage(scope, [
        { ...runtime, dependencies: [...runtime.dependencies, dependency] },
        library,
      ]),
    ).toThrow("outside its own package");
  expect(() =>
    verifyPrivateImageLinkage(scope, [
      runtime,
      {
        ...library,
        path: "Frameworks/libGhosttyTerminal.dylib",
      },
    ]),
  ).toThrow("outside its own package");
});

test.skipIf(process.platform !== "darwin")(
  "two packages bundling the same engine name each bind their own build in one process",
  async () => {
    const root = await mkdtemp(join(tmpdir(), "extension-private-images-"));
    try {
      const runtimes = [];
      for (const [id, version] of [
        ["alpha", "1.0.3"],
        ["beta", "1.0.3"],
        ["alpha", "1.0.2"],
      ]) {
        const build = join(root, "build", `${id}-${version}`);
        await mkdir(build, { recursive: true });
        const engineSource = join(build, "engine.c");
        await writeFile(
          engineSource,
          `const char *fixture_engine(void) { return "${id}-${version}"; }\n`,
        );
        const engine = join(build, "libFixtureEngine.dylib");
        run("clang", [
          "-dynamiclib",
          engineSource,
          "-install_name",
          "@rpath/libFixtureEngine.dylib",
          "-o",
          engine,
        ]);
        const contents = join(root, id, version, "app.bundle/Contents");
        await mkdir(join(contents, "MacOS"), { recursive: true });
        const bundled = await bundleNativeLibrary({
          source: engine,
          frameworks: join(contents, "Frameworks"),
          scope: { id, role: "app", version },
          run,
        });
        const runtimeSource = join(build, "runtime.c");
        await writeFile(
          runtimeSource,
          "const char *fixture_engine(void);\nconst char *fixture_runtime(void) { return fixture_engine(); }\n",
        );
        const runtime = join(contents, "MacOS/Runtime");
        run("clang", [
          "-dynamiclib",
          runtimeSource,
          ...nativePackageLinkFlags(
            root,
            { nativePackage: "Native", nativeProduct: "FixtureEngine" },
            contents,
            bundled.image,
          ),
          "-install_name",
          `@rpath/EdithExtension_${id}_app`,
          "-o",
          runtime,
        ]);
        const images = await inspectPrivateImages(contents, run);
        verifyPrivateImageLinkage({ id }, images);
        expect(images[0].dependencies).toContain(bundled.installName);
        expect(images[0].dependencies).not.toContain(
          "@rpath/libFixtureEngine.dylib",
        );
        runtimes.push({ name: `${id}-${version}`, runtime, ...bundled });
      }
      expect(new Set(runtimes.map(({ installName }) => installName)).size).toBe(
        runtimes.length,
      );
      const hostSource = join(root, "host.c");
      await writeFile(
        hostSource,
        `#include <dlfcn.h>
#include <stdio.h>
int main(int count, char **paths) {
  for (int index = 1; index < count; index++) {
    void *image = dlopen(paths[index], RTLD_NOW | RTLD_LOCAL);
    if (!image) return 2;
    const char *(*value)(void) = (const char *(*)(void))dlsym(image, "fixture_runtime");
    if (!value) return 3;
    printf("%s\\n", value());
  }
  return 0;
}
`,
      );
      const host = join(root, "host");
      run("clang", [hostSource, "-o", host]);
      const output = run(
        host,
        runtimes.map(({ runtime }) => runtime),
        { encoding: "utf8" },
      );
      expect(output.trim().split("\n")).toEqual(
        runtimes.map(({ name }) => name),
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  },
  120_000,
);
