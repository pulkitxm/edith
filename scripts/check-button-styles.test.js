import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  ALLOWLIST_PATH,
  failuresFor,
  findBypasses,
  findMenus,
  findShapedPlates,
  findTogglePlates,
  loadAllowlist,
  staleEntries,
} from "./check-button-styles.mjs";

const rules = (text) =>
  findBypasses(text).map(({ line, rule }) => [line, rule]);

describe("check-button-styles", () => {
  test("flags every native style that skips the shared hover", () => {
    const text = [
      "Button {} label: {}.buttonStyle(.plain)",
      ".buttonStyle(.borderless)",
      ".buttonStyle(.borderedProminent)",
      ".buttonStyle(PlainButtonStyle())",
      ".menuStyle(.borderlessButton)",
      ".buttonStyle(.link)",
      ".buttonStyle(.edith(.borderless))",
      ".textFieldStyle(.plain)",
    ].join("\n");
    expect(rules(text)).toEqual([
      [1, "plain"],
      [2, "borderless"],
      [3, "bordered"],
      [4, "plain"],
      [5, "borderless-menu"],
      [6, "link-style"],
    ]);
  });

  test("flags tap gestures, raw links, AppKit buttons and the control style", () => {
    const text = [
      "Text(title).onTapGesture { open() }",
      "row.gesture(TapGesture(count: 2).onEnded { open() })",
      'Link("Docs", destination: url)',
      "EdithLink(destination: url) { Text(title) }",
      "let button = NSButton()",
      ".buttonStyle(.edithControl)",
    ].join("\n");
    expect(rules(text)).toEqual([
      [1, "tap-gesture"],
      [2, "tap-gesture"],
      [3, "link"],
      [5, "appkit-button"],
      [6, "control-style"],
    ]);
  });

  test("ignores matches inside comments and strings", () => {
    expect(
      rules('let note = ".buttonStyle(.plain)"\n/* .onTapGesture */'),
    ).toEqual([]);
  });

  test("flags presented menus without a kit style and skips submenus", () => {
    const text = [
      "Menu {",
      '    Menu("Nested") { Button("A") {} }',
      "} label: {",
      "    Text(title)",
      "}",
      ".fixedSize()",
      "Menu {",
      '    Button("B") {}',
      "} label: { Text(title) }",
      ".borderlessMenu()",
      'Menu("Item submenu") { Button("C") {} }',
      ".contextMenu {",
      '    Menu("Inside context") { Button("D") {} }.help("x")',
      "}",
    ].join("\n");
    expect(findMenus(text).map(({ line }) => line)).toEqual([1]);
  });

  test("forbids hover plates inside toggle styles", () => {
    const text = [
      "struct Switch: ToggleStyle {",
      "    func makeBody(configuration: Configuration) -> some View {",
      "        SwitchBody(configuration: configuration)",
      "    }",
      "}",
      "private struct SwitchBody: View {",
      "    var body: some View {",
      "        Button {} label: { Track().edithHoverHighlight() }",
      "            .buttonStyle(.edith(.borderless))",
      "    }",
      "}",
      "struct Other: View {",
      "    var body: some View { Text(x).edithHoverHighlight() }",
      "}",
    ].join("\n");
    expect(findTogglePlates(text).map(({ line }) => line)).toEqual([8, 9]);
  });

  test("flags kit styles on controls that paint a circle or capsule", () => {
    const text = [
      "Button(action: play) {",
      "    Icon().background(theme, in: Circle())",
      "}",
      ".buttonStyle(.edith(.borderless))",
      "Button(action: pick) {",
      "    Circle().fill(color)",
      "}",
      ".buttonStyle(.edith(.iconOnly))",
      "Button(action: open) {",
      "    HStack {",
      "        Circle().fill(status)",
      '        Text("Dot in a row")',
      "    }",
      "}",
      ".buttonStyle(.edith(.borderless))",
      "Button(action: play) {",
      "    Icon().background(theme, in: Circle())",
      "}",
      ".buttonStyle(.edithShaped(Circle(), filled: true))",
    ].join("\n");
    expect(findShapedPlates(text).map(({ line }) => line)).toEqual([1, 5]);
  });

  test("allows listed files up to their budget", () => {
    const allowed = loadAllowlist([
      { path: "Sources/Switch.swift", rule: "plain", count: 1, reason: "test" },
    ]);
    const one = { path: "Sources/Switch.swift", text: ".buttonStyle(.plain)" };
    const two = {
      path: "Sources/Switch.swift",
      text: ".buttonStyle(.plain)\n.buttonStyle(.plain)",
    };
    expect(failuresFor([one], allowed)).toEqual([]);
    expect(failuresFor([two], allowed)).toHaveLength(2);
    expect(
      staleEntries([{ path: "Sources/Switch.swift", text: "" }], allowed),
    ).toEqual(["Sources/Switch.swift#plain allows 1 but finds 0"]);
  });

  test("rejects allowlist entries without a reason", () => {
    expect(() => loadAllowlist([{ path: "a.swift", rule: "plain" }])).toThrow();
  });

  test("rejects a new plain button outside the allow-list", () => {
    const failures = failuresFor([
      { path: "Extensions/x/View.swift", text: ".buttonStyle(.plain)" },
    ]);
    expect(failures).toEqual([
      "Extensions/x/View.swift:1: plain skips the shared hover plate",
    ]);
  });

  test("ignores tests, vendored code and the icon preview tool", () => {
    const text = ".buttonStyle(.plain)";
    expect(
      failuresFor([
        { path: "Packages/EdithHost/Tests/A.swift", text },
        { path: "Extensions/terminal/Native/vendor/x/A.swift", text },
        {
          path: "Packages/EdithIcons/tools/preview/Sources/preview/main.swift",
          text,
        },
      ]),
    ).toEqual([]);
  });

  test("every allowlist entry carries a reason", () => {
    const raw = JSON.parse(readFileSync(ALLOWLIST_PATH, "utf8"));
    expect(raw.length).toBeLessThan(40);
    expect(() => loadAllowlist(raw)).not.toThrow();
  });
});
