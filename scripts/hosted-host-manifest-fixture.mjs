import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
export const reviewed = [
  ["../ExtensionMarketplace", "Packages/ExtensionMarketplace"],
  ["../ExtensionSupport", "Packages/ExtensionSupport"],
  ["../../Extensions/fixtureSupport", "Extensions/fixtureSupport"],
];
export const source = await readFile(
  "Packages/EdithHost/Package.swift",
  "utf8",
);

export async function withRepository(operation) {
  const root = await realpath(
    await mkdtemp(join(tmpdir(), "host-manifest-fixture-")),
  );
  try {
    await chmod(root, 0o700);
    for (const [, path] of reviewed) {
      const name = path.split("/").at(-1);
      const module = `${name}Fixture`;
      await mkdir(join(root, path), { recursive: true, mode: 0o700 });
      await mkdir(join(root, path, "Sources", module), {
        recursive: true,
        mode: 0o700,
      });
      await writeFile(
        join(root, path, "Sources", module, "Fixture.swift"),
        "public enum Fixture {}\n",
        { mode: 0o600 },
      );
      await writeFile(
        join(root, path, "Package.swift"),
        `// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: ${JSON.stringify(name)}, products: [.library(name: ${JSON.stringify(module)}, targets: [${JSON.stringify(module)}])], targets: [.target(name: ${JSON.stringify(module)})])\n`,
        { mode: 0o600 },
      );
    }
    await operation(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}
