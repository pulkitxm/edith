import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { END, people, render, replaceSection, START } from "./contributors.mjs";

const payload = [
  {
    login: "someone",
    html_url: "https://github.com/someone",
    avatar_url: "https://avatars.githubusercontent.com/u/2?v=4",
    contributions: 3,
  },
  {
    login: "github-actions[bot]",
    html_url: "https://github.com/apps/github-actions",
    avatar_url: "https://avatars.githubusercontent.com/u/1?v=4",
    contributions: 900,
  },
  {
    login: "builder",
    html_url: "https://github.com/builder",
    avatar_url: "https://avatars.githubusercontent.com/u/3?v=4",
    contributions: 40,
  },
];

test("bots are dropped and people are ordered by contributions", () => {
  expect(people(payload).map((person) => person.login)).toEqual([
    "builder",
    "someone",
  ]);
});

test("every person becomes a linked avatar cell", () => {
  const table = render(payload);
  expect(table).toContain('<a href="https://github.com/builder">');
  expect(table).toContain("u/3?v=4&s=64");
  expect(table).toContain('width="64"');
  expect(table).toContain("<sub>someone</sub>");
  expect(table).not.toContain("github-actions");
});

test("an empty roster renders nothing rather than an empty table", () => {
  expect(render([])).toBe("");
});

test("only the marked section is replaced", () => {
  const readme = `# Edith\n\n${START}\nold\n${END}\n\n## Licence\n`;
  const updated = replaceSection(readme, "<table></table>");
  expect(updated).toContain("# Edith");
  expect(updated).toContain("## Licence");
  expect(updated).toContain("<table></table>");
  expect(updated).not.toContain("old");
});

test("a README without markers is an error, not a silent no-op", () => {
  expect(() => replaceSection("# Edith\n", "<table></table>")).toThrow(
    "missing the contributors markers",
  );
});

test("the README carries the generated section and the app mirrors it", () => {
  const readme = readFileSync("README.md", "utf8");
  expect(readme).toContain(START);
  expect(readme).toContain(END);
  expect(readme).toContain("avatars.githubusercontent.com");

  const workflow = readFileSync(".github/workflows/contributors.yml", "utf8");
  expect(workflow).toContain("cron:");
  expect(workflow).toContain("bun scripts/contributors.mjs");
  expect(workflow).toContain('git commit -m "Refresh the contributor list"');

  const ci = readFileSync(".github/workflows/ci.yml", "utf8");
  expect(ci).toContain("'Refresh the contributor list'");
});
