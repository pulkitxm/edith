import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFileSync, statSync, writeFileSync } from "node:fs";
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
      const members = execFileSync("ar", ["-t", archive], { encoding: "utf8" })
        .trim()
        .split("\n");
      expect(members.length).toBeGreaterThan(0);
      expect(new Set(members).size).toBe(members.length);
      const symbols = execFileSync("nm", ["-gUj", archive], {
        encoding: "utf8",
        maxBuffer: 32 * 1024 * 1024,
      });
      expect(symbols).toContain(support.modules.EdithExtensionSupport);
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
        expect(symbols).toContain(support.modules.ArgumentParserToolInfo);
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
