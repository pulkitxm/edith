import { expect, test } from "bun:test";
import {
  lstat,
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
  copyNativeFrameworks,
  copyNativeResources,
  copySupportLicenses,
  nativeClangModuleFlags,
  nativePackageLinkFlags,
  nativeRolePolicy,
} from "./build-extension-package.mjs";

test("native Swift resources and explicit licenses retain their bundle structure", async () => {
  const root = await mkdtemp(join(tmpdir(), "extension-native-resources-"));
  try {
    const nativePackage = "Extensions/mock/Native";
    const bundle = "MockParser_MockParser.bundle";
    await mkdir(join(root, nativePackage, ".build/release", bundle, "assets"), {
      recursive: true,
    });
    await writeFile(
      join(root, nativePackage, ".build/release", bundle, "assets/theme.css"),
      "synthetic theme",
    );
    await writeFile(join(root, nativePackage, "LICENSE"), "synthetic license");
    const contents = join(root, "mock.bundle/Contents");
    await copyNativeResources(
      root,
      {
        nativePackage,
        nativeResources: [bundle],
        nativeLicenses: [
          {
            source: join(nativePackage, "LICENSE"),
            destination: "Parser-LICENSE",
          },
        ],
      },
      contents,
    );
    expect(
      await readFile(
        join(contents, "Resources", bundle, "assets/theme.css"),
        "utf8",
      ),
    ).toBe("synthetic theme");
    expect(
      await readFile(join(contents, "Resources/Parser-LICENSE"), "utf8"),
    ).toBe("synthetic license");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("native resources reject collisions and destination paths outside Resources", async () => {
  const root = await mkdtemp(
    join(tmpdir(), "extension-native-resource-names-"),
  );
  try {
    for (const name of [
      "../Runtime",
      "/absolute",
      "",
      ".",
      "..",
      "existing.bundle",
    ]) {
      await expect(
        copyNativeResources(
          root,
          {
            nativePackage: "Extensions/mock/Native",
            nativeResources: [name],
          },
          join(root, "mock.bundle/Contents"),
          new Set(["existing.bundle"]),
        ),
      ).rejects.toThrow("invalid native resource");
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("native frameworks flatten versioned links before signing and reject unowned paths", async () => {
  const root = await mkdtemp(join(tmpdir(), "extension-native-frameworks-"));
  try {
    const nativePackage = "Extensions/mock/Native";
    const source = ".build/artifacts/Parser.framework";
    await mkdir(join(root, nativePackage, source, "Versions/A"), {
      recursive: true,
    });
    await writeFile(
      join(root, nativePackage, source, "Versions/A/Parser"),
      "synthetic binary",
    );
    await symlink("A", join(root, nativePackage, source, "Versions/Current"));
    await symlink(
      "Versions/Current/Parser",
      join(root, nativePackage, source, "Parser"),
    );
    const contents = join(root, "mock.bundle/Contents");
    const copied = await copyNativeFrameworks(
      root,
      { nativePackage, nativeFrameworks: [source] },
      contents,
    );
    expect(
      (
        await lstat(join(contents, "Frameworks/Parser.framework/Parser"))
      ).isSymbolicLink(),
    ).toBe(false);
    expect(
      await lstat(join(contents, "Frameworks/Parser.framework/Versions")).catch(
        () => undefined,
      ),
    ).toBeUndefined();
    expect(copied).toEqual([
      {
        binary: await realpath(
          join(contents, "Frameworks/Parser.framework/Parser"),
        ),
        framework: join(contents, "Frameworks/Parser.framework"),
        installName: "@rpath/Parser.framework/Parser",
      },
    ]);
    expect(
      await readFile(
        join(contents, "Frameworks/Parser.framework/Parser"),
        "utf8",
      ),
    ).toBe("synthetic binary");
    for (const nativeFrameworks of [
      ["../Outside.framework"],
      [source, source],
      ["invalid.dylib"],
    ]) {
      await expect(
        copyNativeFrameworks(
          root,
          { nativePackage, nativeFrameworks },
          contents,
        ),
      ).rejects.toThrow("invalid native framework");
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("native Clang modules admit only owned target names", () => {
  const nativePackage = "Extensions/mock/Native";
  expect(
    nativeClangModuleFlags("/synthetic", {
      nativePackage,
      nativeClangTargets: ["CPDFium"],
    }),
  ).toEqual([
    "-I",
    "/synthetic/Extensions/mock/Native/.build/release/CPDFium.build",
  ]);
  for (const nativeClangTargets of [
    ["../Outside"],
    ["CPDFium", "CPDFium"],
    ["/absolute"],
    [""],
    ["-flag"],
  ])
    expect(() =>
      nativeClangModuleFlags("/synthetic", {
        nativePackage,
        nativeClangTargets,
      }),
    ).toThrow("Invalid native Clang target");
});

test("native payloads can be limited to selected roles without eager dynamic linking", () => {
  const definition = {
    roles: {
      app: ["app.swift"],
      helper: ["helper.swift"],
      cameraCarrier: ["carrier.swift"],
    },
    nativePackage: "Extensions/mock/Native",
    nativeProduct: "MeetingVoice",
    nativeRoles: ["app"],
    nativeLink: false,
  };
  expect(nativeRolePolicy(definition)).toEqual({
    roles: ["app"],
    link: false,
    presentations: [],
  });
  expect(
    nativePackageLinkFlags(
      "/workspace",
      definition,
      "/payload/app.bundle/Contents",
    ),
  ).toEqual([]);
  const existing = {
    ...definition,
    nativeRoles: undefined,
    nativeLink: undefined,
  };
  expect(nativeRolePolicy(existing)).toEqual({
    roles: ["app", "helper", "cameraCarrier"],
    link: true,
    presentations: [],
  });
  expect(
    nativePackageLinkFlags(
      "/workspace",
      existing,
      "/payload/app.bundle/Contents",
    ),
  ).toContain("-lMeetingVoice");
  expect(nativeRolePolicy({ roles: { app: [] } })).toEqual({
    roles: [],
    link: true,
    presentations: [],
  });
});

test("native presentation factories require an owned dynamically linked role", () => {
  const definition = {
    roles: { app: [], helper: [] },
    nativePackage: "Extensions/mock/Native",
    nativeRoles: ["app"],
    nativePresentationRoles: ["app"],
  };
  expect(nativeRolePolicy(definition).presentations).toEqual(["app"]);
  for (const nativePresentationRoles of [
    null,
    "app",
    ["helper"],
    [1],
    ["app", "app"],
  ])
    expect(() =>
      nativeRolePolicy({ ...definition, nativePresentationRoles }),
    ).toThrow();
  for (const overrides of [{ nativeLink: false }, { nativePackage: undefined }])
    expect(() => nativeRolePolicy({ ...definition, ...overrides })).toThrow();
});

test("native role policy rejects empty, duplicated, unknown and mistyped declarations", () => {
  const definition = {
    roles: { app: [], helper: [] },
    nativePackage: "Extensions/mock/Native",
    nativeProduct: "MeetingVoice",
  };
  for (const nativeRoles of [
    [],
    ["app", "app"],
    ["provider"],
    "app",
    null,
    [1],
  ])
    expect(() => nativeRolePolicy({ ...definition, nativeRoles })).toThrow(
      "Invalid native role",
    );
  for (const nativeLink of [null, "false", 0, []])
    expect(() => nativeRolePolicy({ ...definition, nativeLink })).toThrow(
      "Invalid native role",
    );
  expect(() =>
    nativeRolePolicy({ roles: { app: [] }, nativeRoles: ["app"] }),
  ).toThrow("Invalid native role");
  expect(() =>
    nativeRolePolicy({ roles: { app: [] }, nativeLink: false }),
  ).toThrow("Invalid native role");
  expect(
    nativeRolePolicy({
      roles: { app: [], helper: [] },
      nativeCargo: { library: "libMusic.dylib" },
      nativeRoles: ["helper"],
    }).roles,
  ).toEqual(["helper"]);
});

test("native system module directories remain inside their owned package", () => {
  const nativePackage = "Extensions/mock/Native";
  expect(
    nativeClangModuleFlags("/synthetic", {
      nativePackage,
      nativeClangDirectories: [".build/checkouts/mock/Sources/SQLite"],
    }),
  ).toEqual([
    "-I",
    "/synthetic/Extensions/mock/Native/.build/checkouts/mock/Sources/SQLite",
  ]);
  for (const nativeClangDirectories of [
    ["../Outside"],
    ["/absolute"],
    [""],
    ["a", "a"],
    ["bad\0path"],
  ]) {
    expect(() =>
      nativeClangModuleFlags("/synthetic", {
        nativePackage,
        nativeClangDirectories,
      }),
    ).toThrow("Invalid native Clang directory");
  }
});

const parserLicense = "swift-argument-parser-license.txt";

async function licenseFixture() {
  const root = await mkdtemp(join(tmpdir(), "extension-sdk-license-"));
  const source = join(root, "Packages/ExtensionSupport/Licenses");
  await mkdir(source, { recursive: true });
  await writeFile(join(source, parserLicense), "synthetic parser notice\n");
  return root;
}

test.each([
  ["EdithExtensionCommands"],
  [["EdithExtensionDocuments", "EdithExtensionCommands"]],
  [null, "EdithExtensionCommands"],
])(
  "every linked Commands closure carries its parser notice %j",
  async (...selections) => {
    const root = await licenseFixture();
    try {
      const contents = join(root, "role.bundle/Contents");
      const names = new Set();
      await copySupportLicenses(root, selections, contents, names);
      expect(
        await readFile(join(contents, "Resources", parserLicense), "utf8"),
      ).toBe("synthetic parser notice\n");
      expect([...names]).toEqual([parserLicense]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  },
);

test("an explicit identical SDK notice remains valid while conflicting bytes fail", async () => {
  const root = await licenseFixture();
  try {
    const contents = join(root, "role.bundle/Contents");
    const resources = join(contents, "Resources");
    await mkdir(resources, { recursive: true });
    const destination = join(resources, parserLicense);
    const names = new Set([parserLicense]);
    await writeFile(destination, "synthetic parser notice\n");
    await copySupportLicenses(
      root,
      ["EdithExtensionCommands"],
      contents,
      names,
    );
    expect(names.size).toBe(1);
    await writeFile(destination, "conflicting notice");
    await expect(
      copySupportLicenses(root, ["EdithExtensionCommands"], contents, names),
    ).rejects.toThrow("Conflicting private SDK license resource");
    expect(await readFile(destination, "utf8")).toBe("conflicting notice");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("UI-only and absent SDK selections need no parser notice", async () => {
  const root = await mkdtemp(join(tmpdir(), "extension-sdk-no-license-"));
  try {
    const contents = join(root, "role.bundle/Contents");
    const names = new Set();
    await copySupportLicenses(
      root,
      ["EdithExtensionUI", null],
      contents,
      names,
    );
    expect(names.size).toBe(0);
    await expect(
      readFile(join(contents, "Resources", parserLicense)),
    ).rejects.toThrow();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
