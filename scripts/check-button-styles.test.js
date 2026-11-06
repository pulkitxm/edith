import { describe, expect, test } from "bun:test";
import { failuresFor, findBypasses } from "./check-button-styles.mjs";

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
    expect(findBypasses(text).map(({ line }) => line)).toEqual([
      1, 2, 3, 4, 5, 6,
    ]);
  });

  test("allows listed files up to their budget", () => {
    const allowed = new Map([["Sources/Switch.swift", 1]]);
    const one = { path: "Sources/Switch.swift", text: ".buttonStyle(.plain)" };
    const two = {
      path: "Sources/Switch.swift",
      text: ".buttonStyle(.plain)\n.buttonStyle(.plain)",
    };
    expect(failuresFor([one], allowed)).toEqual([]);
    expect(failuresFor([two], allowed)).toHaveLength(2);
  });

  test("rejects a new plain button outside the allow-list", () => {
    const failures = failuresFor([
      { path: "Extensions/x/View.swift", text: ".buttonStyle(.plain)" },
    ]);
    expect(failures).toEqual([
      "Extensions/x/View.swift:1: .buttonStyle(.plain) skips the shared hover state",
    ]);
  });

  test("ignores tests and the icon preview tool", () => {
    const text = ".buttonStyle(.plain)";
    expect(
      failuresFor([
        { path: "Packages/EdithHost/Tests/A.swift", text },
        {
          path: "Packages/EdithIcons/tools/preview/Sources/preview/main.swift",
          text,
        },
      ]),
    ).toEqual([]);
  });
});
