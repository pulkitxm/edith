import { describe, expect, test } from "bun:test";
import { findForbiddenLibraries, findViolations } from "./check-icons.mjs";

const symbols = new Set(["gearshape.fill"]);
const icons = new Set(["plus", "gear"]);
const violations = (text) => findViolations(text, symbols, icons);

describe("check-icons", () => {
  test("flags every system symbol API", () => {
    const text = [
      'Image(systemName: "gear")',
      'Label("Rename", systemImage: "pencil")',
      'NSImage(systemSymbolName: "gear", accessibilityDescription: nil)',
      "view.symbolEffect(.pulse)",
    ].join("\n");
    expect(violations(text).map(({ line }) => line)).toEqual([1, 2, 3, 3, 4]);
  });

  test("flags a symbol name kept in a string", () => {
    expect(violations('let icon = "gearshape.fill"')).toEqual([
      { line: 1, reason: "system symbol name gearshape.fill" },
    ]);
  });

  test.each([
    "laptopcomputer",
    "desktopcomputer",
    "gearshape",
    "magnifyingglass",
    "xmark",
    "macwindow",
    "internaldrive",
    "externaldrive",
    "memorychip",
    "shippingbox",
    "paintpalette",
    "paperplane",
    "tablecells",
    "textformat",
    "curlybraces",
    "cursorarrow",
    "archivebox",
    "sparkle",
    "sparkles",
    "checkmark",
    "nosign",
    "speedometer",
  ])("flags the undotted symbol name %s in any literal", (name) => {
    expect(violations(`foo(["${name}"])`)).toEqual([
      { line: 1, reason: `system symbol name ${name}` },
    ]);
  });

  test("allows text that only contains an undotted symbol name", () => {
    const text = [
      'Text("Sparkle updates")',
      'let name = "sparkle.framework"',
      'let label = "my-xmark"',
    ].join("\n");
    expect(violations(text)).toEqual([]);
  });

  test("flags an unknown literal passed to EdithIcon(name:)", () => {
    const text = [
      'EdithIcon(name: "plus")',
      'EdithIcon(name: "gear")',
      'EdithIcon(name: "cog")',
      'EdithIcon(\n    name: "nope")',
    ].join("\n");
    expect(violations(text)).toEqual([
      { line: 3, reason: "unknown icon name cog" },
      { line: 4, reason: "unknown icon name nope" },
    ]);
  });

  test("leaves a dynamic EdithIcon(name:) alone", () => {
    expect(violations("EdithIcon(name: step.icon)")).toEqual([]);
  });

  test("allows Edith icons and unrelated dotted strings", () => {
    const text = [
      "EdithIconView(.settings)",
      'Label("Rename", edith: .edit)',
      'let host = "api.example.com"',
    ].join("\n");
    expect(violations(text)).toEqual([]);
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
