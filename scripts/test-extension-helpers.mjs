import { execFileSync } from "node:child_process";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { buildExtensionPackage } from "./build-extension-package.mjs";

const root = await mkdtemp(join(tmpdir(), "extension-helpers-"));
const suite = `com.pulkit.edith.dev.extension-fixture-${crypto.randomUUID()}.shared`;
try {
  const app = resolve(process.argv[2] ?? "dist/Edith.app");
  if (process.argv.includes("--host-fixture")) {
    const products = resolve("build/extension-host/.build/release");
    const frameworks = join(app, "Contents/Frameworks");
    const shared = join(frameworks, "EdithShared.framework/Versions/A");
    await mkdir(shared, { recursive: true });
    await copyFile(
      join(products, "libEdithShared.dylib"),
      join(shared, "EdithShared"),
    );
    await copyFile(
      join(products, "libExtensionMarketplace.dylib"),
      join(frameworks, "libExtensionMarketplace.dylib"),
    );
    await writeFile(
      join(app, "Contents/Info.plist"),
      JSON.stringify({
        CFBundleIdentifier: "com.pulkit.edith.dev.extension-fixture",
      }),
    );
    execFileSync("plutil", [
      "-convert",
      "binary1",
      join(app, "Contents/Info.plist"),
    ]);
  }
  const runner = join(root, "helper-smoke");
  execFileSync("xcrun", [
    "swiftc",
    "scripts/extension-runtime-smoke.swift",
    "-o",
    runner,
  ]);
  const environment = {
    ...process.env,
    EDITH_SHARED_DEFAULTS_SUITE: suite,
    EDITH_APPLICATION_IDENTIFIER: "com.pulkit.edith.dev.extension-fixture",
    EDITH_DATABASE_HOME: root,
    DYLD_FRAMEWORK_PATH: join(app, "Contents/Frameworks"),
    DYLD_LIBRARY_PATH: join(app, "Contents/Frameworks"),
  };
  const definitions = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
  );
  for (const definition of definitions.filter(
    ({ usesHostFramework, roles }) => usesHostFramework && roles.helper,
  )) {
    const output = join(root, definition.id);
    const record = await buildExtensionPackage({
      id: definition.id,
      output,
      development: true,
    });
    const extraction = join(output, "extracted");
    await mkdir(extraction);
    execFileSync("ditto", [
      "-xk",
      join(output, `${definition.id}.zip`),
      extraction,
    ]);
    const result = execFileSync(
      runner,
      [app, join(extraction, definition.id), record.hostABI],
      { encoding: "utf8", env: environment },
    );
    process.stdout.write(result);
  }
} finally {
  try {
    execFileSync("defaults", ["delete", suite], { stdio: "ignore" });
  } catch {}
  await rm(root, { recursive: true, force: true });
}
