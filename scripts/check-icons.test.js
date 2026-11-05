import { describe, expect, test } from "bun:test";
import { findForbiddenLibraries, findViolations } from "./check-icons.mjs";

const symbols = new Set(["gearshape.fill"]);

describe("check-icons", () => {
  test("flags every system symbol API", () => {
    const text = [
      'Image(systemName: "gear")',
      'Label("Rename", systemImage: "pencil")',
      'NSImage(systemSymbolName: "gear", accessibilityDescription: nil)',
      "view.symbolEffect(.pulse)",
    ].join("\n");
    expect(findViolations(text, symbols).map(({ line }) => line)).toEqual([
      1, 2, 3, 3, 4,
    ]);
  });

  test("flags a symbol name kept in a string", () => {
    expect(findViolations('let icon = "gearshape.fill"', symbols)).toEqual([
      { line: 1, reason: "system symbol name gearshape.fill" },
    ]);
  });

  test("allows Edith icons and unrelated dotted strings", () => {
    const text = [
      "EdithIconView(.settings)",
      'Label("Rename", edith: .edit)',
      'let host = "api.example.com"',
    ].join("\n");
    expect(findViolations(text, symbols)).toEqual([]);
  });

  test("flags icon libraries in a manifest", () => {
    expect(
      findForbiddenLibraries({
        dependencies: { "lucide-react": "1.0.0", react: "19.0.0" },
        devDependencies: { "@heroicons/react": "2.0.0" },
      }),
    ).toEqual(["lucide-react", "@heroicons/react"]);
  });
});
