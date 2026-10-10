import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import {
  buildExtensionSupport,
  rewriteSupportImports,
  supportProducts,
} from "./build-extension-support.mjs";

const root = resolve(
  process.env.EXTENSION_SUPPORT_FIXTURE_ROOT ?? resolve(import.meta.dir, ".."),
);
const native = process.env.EXTENSION_SUPPORT_NATIVE_TESTS === "1";
const architecture = process.arch === "arm64" ? "arm64" : "x86_64";

function inspectArchive(archive, directory) {
  const bytes = readFileSync(archive);
  const digest = createHash("sha256").update(bytes).digest("hex");
  const magic = bytes.readUInt32BE(0);
  const fat = [0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca].includes(magic);
  if (!fat) expect(bytes.subarray(0, 8).toString()).toBe("!<arch>\n");
  const architectures = execFileSync("xcrun", ["lipo", "-archs", archive], {
    encoding: "utf8",
  })
    .trim()
    .split(/\s+/);
  expect(architectures).toContain(architecture);
  expect(new Set(architectures).size).toBe(architectures.length);
  expect(
    architectures.every((value) => ["arm64", "x86_64"].includes(value)),
  ).toBe(true);
  const inspections = architectures.map((value) => {
    const inspected = fat
      ? resolve(directory, `ArchiveInspection-${value}.a`)
      : archive;
    if (fat)
      execFileSync("xcrun", [
        "lipo",
        archive,
        "-thin",
        value,
        "-output",
        inspected,
      ]);
    expect(
      execFileSync("xcrun", ["lipo", "-archs", inspected], {
        encoding: "utf8",
      }).trim(),
    ).toBe(value);
    const members = execFileSync("xcrun", ["ar", "-t", inspected], {
      encoding: "utf8",
    })
      .trim()
      .split("\n");
    expect(members.length).toBeGreaterThan(0);
    expect(new Set(members).size).toBe(members.length);
    const symbols = execFileSync("xcrun", ["nm", "-gUj", inspected], {
      encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024,
    });
    return { architecture: value, members, symbols };
  });
  expect(createHash("sha256").update(readFileSync(archive)).digest("hex")).toBe(
    digest,
  );
  return inspections;
}

test.skipIf(!native)(
  "private SDK archive inspection verifies every universal slice without changing the archive",
  () => {
    const directory = mkdtempSync(resolve(tmpdir(), "private-sdk-archive-"));
    try {
      const source = resolve(directory, "Fixture.c");
      writeFileSync(source, "void private_sdk_fixture(void) {}\n");
      const archives = ["arm64", "x86_64"].map((value) => {
        const object = resolve(directory, `Fixture-${value}.o`);
        const archive = resolve(directory, `Fixture-${value}.a`);
        execFileSync("xcrun", [
          "clang",
          "-target",
          `${value}-apple-macos14.0`,
          "-c",
          source,
          "-o",
          object,
        ]);
        execFileSync("xcrun", ["ar", "rcs", archive, object]);
        return archive;
      });
      const universal = resolve(directory, "Fixture-universal.a");
      execFileSync("xcrun", [
        "lipo",
        "-create",
        ...archives,
        "-output",
        universal,
      ]);
      expect(() =>
        execFileSync("xcrun", ["ar", "-t", universal], { stdio: "pipe" }),
      ).toThrow();
      const inspected = inspectArchive(universal, directory);
      expect(inspected.map((item) => item.architecture).sort()).toEqual([
        "arm64",
        "x86_64",
      ]);
      for (const item of inspected)
        expect(item.symbols).toContain("_private_sdk_fixture");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  },
);

for (const [scope, selection] of [
  [
    "fixture_documents_commands",
    ["EdithExtensionDocuments", "EdithExtensionCommands"],
  ],
  [
    "fixture_archive_commands",
    ["EdithExtensionArchive", "EdithExtensionCommands"],
  ],
  ["fixture_single_commands", "EdithExtensionCommands"],
  ["fixture_single_support", "EdithExtensionSupport"],
]) {
  test.skipIf(!native)(
    `actual private SDK archive links and executes ${scope}`,
    () => {
      const support = buildExtensionSupport(root, selection, scope);
      const directory = resolve(root, "local/extension-support", scope);
      const manifest = readFileSync(
        resolve(directory, "Package.swift"),
        "utf8",
      );
      const selected = supportProducts(selection);
      for (const name of selected) {
        expect(manifest).toContain(`.target(name: "${support.modules[name]}"`);
      }
      const archive = resolve(support.products, `lib${support.product}.a`);
      const inspected = inspectArchive(archive, directory);
      for (const item of inspected)
        expect(item.symbols).toContain(support.modules.EdithExtensionSupport);
      const hasCommands = selected.includes("EdithExtensionCommands");
      const hasDocuments = selected.includes("EdithExtensionDocuments");
      const hasArchive = selected.includes("EdithExtensionArchive");
      if (hasCommands) {
        expect(manifest).toContain(
          `.target(name: "${support.modules.ArgumentParser}"`,
        );
        expect(manifest).toContain(
          `.target(name: "${support.modules.ArgumentParserToolInfo}"`,
        );
        expect(manifest).not.toContain('"ArgumentParser":');
        for (const item of inspected)
          expect(item.symbols).toContain(
            support.modules.ArgumentParserToolInfo,
          );
      }
      const source = `import Foundation
import EdithExtensionSupport
${hasCommands ? "import EdithExtensionCommands\nimport ArgumentParser" : ""}
${hasDocuments ? "import EdithExtensionDocuments" : ""}
${hasArchive ? "import EdithExtensionArchive" : ""}
${hasCommands ? 'struct Echo: AsyncParsableCommand { mutating func run() async throws { CLIOut.out("scoped") } }' : ""}
@main struct Probe {
    @MainActor static func main() async throws {
        let request = try ExtensionCLIRequest(arguments: [])
        try request.validate()
        ${hasCommands ? 'let reply = try await ExtensionCLIExecution.run(Echo.self, arguments: request.arguments)\n        precondition(reply.stdout == "scoped\\n" && reply.exitCode == 0)' : ""}
        ${hasDocuments ? `precondition(String(reflecting: Highlighter.self).contains("${scope}"))` : ""}
        ${hasArchive ? 'do { _ = try ArchiveFileReader.read(named: "missing", from: Data(), maximumBytes: 8); preconditionFailure() } catch {}' : ""}
        print("scoped SDK probe passed")
    }
}
`;
      const path = resolve(directory, "Probe.swift");
      writeFileSync(path, rewriteSupportImports(source, support.modules));
      const executable = resolve(directory, "Probe");
      execFileSync(
        "xcrun",
        [
          "swiftc",
          "-parse-as-library",
          "-swift-version",
          "5",
          "-I",
          resolve(support.products, "Modules"),
          "-I",
          support.products,
          "-L",
          support.products,
          `-l${support.product}`,
          path,
          "-o",
          executable,
        ],
        { stdio: "inherit" },
      );
      expect(execFileSync(executable, [], { encoding: "utf8" }).trim()).toBe(
        "scoped SDK probe passed",
      );
      const before = [
        statSync(archive).mtimeMs,
        statSync(resolve(directory, "Package.swift")).mtimeMs,
        readFileSync(resolve(directory, "build.json"), "utf8"),
      ];
      expect(buildExtensionSupport(root, selection, scope)).toEqual(support);
      expect([
        statSync(archive).mtimeMs,
        statSync(resolve(directory, "Package.swift")).mtimeMs,
        readFileSync(resolve(directory, "build.json"), "utf8"),
      ]).toEqual(before);
    },
    1_800_000,
  );
}
