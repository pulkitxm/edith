import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import {
  journeyImageNames,
  validateJourneyImage,
} from "./hosted-original-shell/evidence.mjs";

function image() {
  const bytes = Buffer.alloc(33);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(bytes);
  bytes.writeUInt32BE(13, 8);
  bytes.write("IHDR", 12);
  bytes.writeUInt32BE(1200, 16);
  bytes.writeUInt32BE(800, 20);
  return bytes;
}

const passed = { actualJourneyValidated: true, outcome: "passed" };

describe("bounded synthetic window evidence", () => {
  test("only both known window outcomes are admitted after actual journey success", () => {
    expect(journeyImageNames).toHaveLength(2);
    for (const name of journeyImageNames) {
      expect(validateJourneyImage(name, image(), passed)).toEqual({
        name,
        bytes: 33,
        width: 1200,
        height: 800,
      });
      for (const outcome of [
        {},
        { ...passed, actualJourneyValidated: false },
        { ...passed, outcome: "failed" },
      ])
        expect(() => validateJourneyImage(name, image(), outcome)).toThrow();
    }
    expect(() =>
      validateJourneyImage("desktop.png", image(), passed),
    ).toThrow();
  });

  test("invalid signatures, frames and byte bounds fail closed", () => {
    for (const bytes of [
      Buffer.alloc(32),
      Buffer.alloc(8_388_609),
      Buffer.alloc(33),
    ])
      expect(() =>
        validateJourneyImage(journeyImageNames[0], bytes, passed),
      ).toThrow();
    for (const [width, height] of [
      [0, 800],
      [16385, 800],
      [16384, 16384],
    ]) {
      const bytes = image();
      bytes.writeUInt32BE(width, 16);
      bytes.writeUInt32BE(height, 20);
      expect(() =>
        validateJourneyImage(journeyImageNames[0], bytes, passed),
      ).toThrow();
    }
  });

  test("actual XCTest captures a window and workflow retains images only after success", async () => {
    const source = await readFile(
      "Tests/HostedOriginalShell/UITests/OriginalShellJourneyTests.swift",
      "utf8",
    );
    expect(source).toContain("window.screenshot().pngRepresentation");
    expect(source).not.toContain("XCUIScreen");
    for (const name of journeyImageNames) expect(source).toContain(name);
    const workflow = await readFile(
      ".github/workflows/hosted-original-shell.yml",
      "utf8",
    );
    expect(workflow).toContain(
      "name: Retain completed synthetic window evidence\n        if: success()",
    );
    for (const name of journeyImageNames)
      expect(workflow).toContain(`local/hosted-original-shell/${name}`);
  });
});
