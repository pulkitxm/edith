import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const source = readFileSync(
  "Packages/Edith/Sources/EdithKit/Features/Companion/Models/CompanionRuntimeFiles.swift",
  "utf8",
);

const files = [
  ["composeBase", "compose.yaml"],
  ["composeCpu", "compose.cpu.yaml"],
  ["composeGpu", "compose.gpu.yaml"],
  ["composeMac", "compose.mac.yaml"],
  ["dockerfile", "Dockerfile"],
];

const embedded = (property) => {
  const opening = `public static let ${property} = #"""\n`;
  const start = source.indexOf(opening);
  expect(start).toBeGreaterThan(-1);
  const contentStart = start + opening.length;
  const end = source.indexOf('\n        """#', contentStart);
  expect(end).toBeGreaterThan(contentStart);
  return source
    .slice(contentStart, end)
    .split("\n")
    .map((line) => line.slice(8))
    .join("\n");
};

for (const [property, name] of files) {
  test(`${name} matches its embedded Swift runtime file`, () => {
    const runtime = readFileSync(`apps/companion/${name}`, "utf8");
    expect(embedded(property)).toBe(runtime);
  });
}

test("every Companion service comes back after a reboot", () => {
  const compose = readFileSync("apps/companion/compose.yaml", "utf8");
  expect(compose.match(/^ {4}restart: unless-stopped$/gm)?.length).toBe(5);
});

test("Companion images are pinned by digest", () => {
  const dockerfile = readFileSync("apps/companion/Dockerfile", "utf8");
  expect(dockerfile.match(/^FROM .+@sha256:[a-f0-9]{64}/gm)?.length).toBe(2);
});
