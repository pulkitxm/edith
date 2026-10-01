import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  lineAllowed,
  loadAllowlist,
  violations,
  violationsIn,
} from "./check-ui-scale-literals.mjs";

const repo = join(import.meta.dir, "..");

test("app views keep numeric font and frame sizes on the scale", () => {
  expect(violations(repo)).toEqual([]);
});

test("a raw font size and frame are rejected", () => {
  const found = violationsIn(
    "Example.swift",
    'Text("A").font(.system(size: 12))\n.frame(width: 40, height: UIScale.pt(8))\n',
    [],
  );
  expect(found.map((item) => item.line)).toEqual([1, 2]);
});

test("scaled sizes and the fixed-size allowlist pass", () => {
  const allow = loadAllowlist(
    "Fixtures.swift\t.frame(width: 0, height: 0)\n",
  );
  const text = [
    "Text(title).font(.system(size: UIScale.pt(13)))",
    ".frame(width: UIScale.pt(20), minHeight: UIScale.pt(4))",
    ".frame(width: 0, height: 0)",
  ].join("\n");
  expect(lineAllowed("Fixtures.swift", ".frame(width: 0, height: 0)", allow)).toBe(
    true,
  );
  expect(violationsIn("Fixtures.swift", text, allow)).toEqual([]);
});

test("appkit hosts outside window zoom record a reason", () => {
  const lines = readFileSync(
    join(repo, "scripts/ui-scale-appkit-exclusions.txt"),
    "utf8",
  )
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  expect(lines.length).toBeGreaterThan(3);
  for (const line of lines) {
    const [type, reason] = line.split("\t");
    expect(type.length).toBeGreaterThan(0);
    expect(reason.length).toBeGreaterThan(8);
  }
  expect(lines.some((line) => line.startsWith("GhosttyTerminalView\t"))).toBe(
    true,
  );
});
