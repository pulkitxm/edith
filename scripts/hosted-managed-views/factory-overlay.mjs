import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import {
  nativePackageLinkFlags,
  nativeSwiftPackageArguments,
  presentationLinkerFlags,
} from "../build-extension-package.mjs";
import {
  buildExtensionSupport,
  rewriteSupportImports,
} from "../build-extension-support.mjs";
import { verifyFactoryOverlaySources } from "./package-preparation.mjs";
import { managedFactoryOverlay } from "./source-overlay.mjs";

const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");

export function factoryCompileArguments({
  definition,
  sources,
  support,
  root,
  contents,
  developer,
}) {
  assert(["plugins", "studio"].includes(definition.id));
  assert.deepEqual(Object.keys(definition.roles), ["app"]);
  assert(sources.length === definition.roles.app.length);
  assert(sources.every((path) => resolve(path) === path));
  return [
    "swiftc",
    "-emit-library",
    "-parse-as-library",
    "-plugin-path",
    join(
      developer,
      "Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins",
    ),
    "-Osize",
    "-whole-module-optimization",
    "-module-name",
    `EdithExtension_${definition.id}_app`,
    "-target",
    `arm64-apple-macos${definition.minimumSystemVersion}.0`,
    ...sources,
    "-swift-version",
    "5",
    "-I",
    join(support.products, "Modules"),
    "-I",
    support.products,
    "-L",
    support.products,
    `-l${support.product}`,
    ...(definition.nativePackage
      ? nativePackageLinkFlags(root, definition, contents)
      : []),
    "-Xlinker",
    "-dead_strip",
    ...presentationLinkerFlags(definition.supportProduct),
    "-Xlinker",
    "-install_name",
    "-Xlinker",
    `@rpath/EdithExtension_${definition.id}_app`,
    "-Xlinker",
    "-exported_symbol",
    "-Xlinker",
    "_edith_extension_create",
    "-o",
    join(contents, "MacOS/Runtime"),
  ];
}

export function factoryNativeArguments(root, definition, developer) {
  const args = nativeSwiftPackageArguments(root, definition, developer);
  const jobs = args.indexOf("--jobs");
  assert(jobs >= 0 && jobs + 1 < args.length);
  args[jobs + 1] = "1";
  return args;
}

export async function compileFactoryOverlay({
  root,
  definition,
  original,
  payload,
  output,
  execute = execFileSync,
}) {
  const id = definition.id;
  assert(["plugins", "studio"].includes(id));
  assert.match(original.receipt.sourceCommit, /^[a-f0-9]{40}$/);
  const developer =
    process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer";
  const support = buildExtensionSupport(
    root,
    definition.supportProduct,
    `${id}_app`,
  );
  if (definition.nativePackage)
    execute("swift", factoryNativeArguments(root, definition, developer), {
      stdio: "inherit",
      env: {
        ...process.env,
        EXTENSION_SWIFT_JOBS: "1",
        DEVELOPER_DIR: developer,
      },
    });
  const originalRoot = join(output, "original-source");
  const fixtureRoot = join(output, "fixture-source");
  const compileRoot = join(output, "compile-source");
  await mkdir(compileRoot, { mode: 0o700 });
  const compileSources = [];
  const changes = [];
  for (const [index, path] of definition.roles.app.entries()) {
    const originalBytes = execute(
      "git",
      ["show", `${original.receipt.sourceCommit}:${path}`],
      {
        cwd: root,
        maxBuffer: 8 * 1024 * 1024,
      },
    );
    const current = await readFile(join(root, path));
    assert(
      current.equals(originalBytes),
      "Factory compilation requires exact original CI source bytes",
    );
    let source = current.toString("utf8");
    if (path === `Extensions/${id}/Runtime.swift`) {
      source =
        managedFactoryOverlay(source, id) +
        "\n" +
        (await readFile(
          join(
            root,
            "Tests/HostedManagedViews/Sources/ManagedViewContract/HostedManagedFactoryAdmission.swift",
          ),
          "utf8",
        ));
      for (const directory of [originalRoot, fixtureRoot])
        await mkdir(join(directory, `Extensions/${id}`), {
          recursive: true,
          mode: 0o700,
        });
      await writeFile(join(originalRoot, path), originalBytes, { mode: 0o600 });
      await writeFile(join(fixtureRoot, path), source, { mode: 0o600 });
      changes.push({
        path,
        originalSHA256: digest(originalBytes),
        fixtureSHA256: digest(source),
      });
    }
    const destination = join(compileRoot, `${index}-${basename(path)}`);
    await writeFile(
      destination,
      rewriteSupportImports(source, support.modules),
      { mode: 0o600 },
    );
    compileSources.push(destination);
  }
  assert.equal(changes.length, 1);
  const contents = join(payload, "app.bundle/Contents");
  execute(
    "xcrun",
    factoryCompileArguments({
      definition,
      sources: compileSources,
      support,
      root,
      contents,
      developer,
    }),
    {
      stdio: "inherit",
      env: { ...process.env, DEVELOPER_DIR: developer },
    },
  );
  const overlay = await verifyFactoryOverlaySources(
    {
      extensionID: id,
      reviewedSource: original.receipt.sourceCommit,
      functionalActionsValidated: false,
      sources: changes,
    },
    { originalRoot, fixtureRoot },
  );
  return {
    ...overlay,
    codeChanges: [],
    compileSourcesChanged: changes.map(({ path }) => path),
  };
}
