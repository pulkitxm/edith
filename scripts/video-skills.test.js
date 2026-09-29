import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const root = "Packages/Edith/skills";
const catalog = readFileSync(
  "Packages/Edith/Sources/EdithKit/Features/Skills/Models/SkillCatalog.swift",
  "utf8",
);
const ids = [...catalog.matchAll(/id: "(edith-[a-z-]+)"/g)].map(
  (match) => match[1],
);
const rawPrefix =
  "https://raw.githubusercontent.com/pulkitxm/edith/main/Packages/Edith/skills/";
const videoIDs = ids.filter((id) => id.startsWith("edith-video-"));

test("Plugins catalog discovers every bundled skill with matching metadata", () => {
  const folders = readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();
  expect([...ids].sort()).toEqual(folders);
  expect(new Set(ids).size).toBe(ids.length);
  expect(videoIDs.length).toBeGreaterThan(0);
  for (const id of ids) {
    const text = readFileSync(join(root, id, "SKILL.md"), "utf8");
    const metadata = text.match(/^---\n([\s\S]+?)\n---\n/);
    expect(metadata).not.toBeNull();
    expect(metadata[1].split("\n")).toContain(`name: ${id}`);
    const description = metadata[1].match(/^description: (.+)$/m)?.[1];
    expect(description?.length).toBeGreaterThan(20);
    expect(description?.length).toBeLessThanOrEqual(1024);
    expect(text.split("\n").length).toBeLessThan(500);
  }
});

test("every video blueprint is reachable even from a Markdown-only attachment", () => {
  for (const id of videoIDs) {
    const text = readFileSync(join(root, id, "SKILL.md"), "utf8");
    const links = [...text.matchAll(/\]\((https:\/\/[^)]+)\)/g)].map(
      (match) => match[1],
    );
    const references = readdirSync(join(root, id, "references"));
    expect(references.length).toBeGreaterThan(0);
    for (const file of references) {
      expect(links).toContain(`${rawPrefix}${id}/references/${file}`);
    }
    for (const url of links) {
      expect(url.startsWith(rawPrefix)).toBe(true);
      const path = url.slice(rawPrefix.length);
      expect(path.split("/")).not.toContain("..");
      expect(readFileSync(join(root, path), "utf8").startsWith("# ")).toBe(
        true,
      );
    }
  }
});

test("video examples use public plans rather than serialized projects", () => {
  let examples = 0;
  for (const id of videoIDs) {
    for (const file of readdirSync(join(root, id, "references"))) {
      const text = readFileSync(join(root, id, "references", file), "utf8");
      for (const match of text.matchAll(/```json\n([\s\S]*?)\n```/g)) {
        const plan = JSON.parse(match[1]);
        expect(Object.keys(plan).sort()).toEqual(["operations", "version"]);
        expect(plan.version).toBe(1);
        expect(plan.operations.length).toBeGreaterThan(0);
        for (const operation of plan.operations) {
          expect(Object.keys(operation)).toHaveLength(1);
        }
        examples += 1;
      }
    }
  }
  expect(examples).toBeGreaterThan(0);
});
