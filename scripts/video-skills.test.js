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
    const links = [...text.matchAll(/\]\((references\/[^)]+)\)/g)].map(
      (match) => match[1],
    );
    expect(text).toContain("`pulkitxm/edith`");
    expect(text).toContain("`main`");
    expect(text).toContain(`\`${root}/${id}/\``);
    const references = readdirSync(join(root, id, "references"));
    expect(references.length).toBeGreaterThan(0);
    for (const file of references) {
      expect(links).toContain(`references/${file}`);
    }
    for (const path of links) {
      expect(path.split("/")).not.toContain("..");
      expect(readFileSync(join(root, id, path), "utf8").startsWith("# ")).toBe(
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

test("video skills ship synthetic evaluation prompts with verifiable expectations", () => {
  const evalIDs = [];
  for (const id of videoIDs) {
    const suite = JSON.parse(
      readFileSync(join(root, id, "evals/evals.json"), "utf8"),
    );
    expect(suite.skill_name).toBe(id);
    expect(suite.evals.length).toBeGreaterThan(0);
    for (const evaluation of suite.evals) {
      evalIDs.push(evaluation.id);
      expect(evaluation.prompt).toContain("synthetic-");
      expect(evaluation.expected_output.length).toBeGreaterThan(40);
      expect(evaluation.files).toEqual([]);
      expect(evaluation.expectations.length).toBeGreaterThanOrEqual(3);
    }
  }
  expect(new Set(evalIDs).size).toBe(evalIDs.length);
  expect(evalIDs).toHaveLength(3);
});
