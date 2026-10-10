import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const documents = [
  "docs/cli/invoke/README.md",
  "docs/companion.md",
  "docs/homebrew-manager.md",
  "docs/latex.md",
  "docs/lid-awake.md",
  "docs/remote-machines.md",
];
const sources = {
  usage: "Extensions/usage/Services/UsageStatusLineCommands.swift",
  companion: "Extensions/companion/Services/CompanionWorker.swift",
  latex: "Extensions/latex/LaTeXWorker.swift",
  lidAwake: "Extensions/lidAwake/Surface.swift",
  machines: "Extensions/machines/Services/MachinePeerService.swift",
};

test("feature workflows use shipped public routes and existing worker operations", () => {
  for (const path of documents) {
    const text = readFileSync(path, "utf8");
    for (const match of text.matchAll(/\bed ([a-zA-Z-]+)/g))
      expect(["invoke", "extensions"]).toContain(match[1]);
    for (const match of text.matchAll(/\bed invoke (\w+) ([\w.]+)/g)) {
      const source = match[2].startsWith("surface.")
        ? "Packages/ExtensionSupport/Sources/EdithExtensionSupport/SurfaceCommandService.swift"
        : sources[match[1]];
      expect(source).toBeDefined();
      expect(readFileSync(source, "utf8")).toContain(`"${match[2]}"`);
    }
  }
});
