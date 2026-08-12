import { readFileSync, writeFileSync } from "node:fs";

export const START = "<!-- contributors:start -->";
export const END = "<!-- contributors:end -->";

const ENDPOINT =
  "https://api.github.com/repos/pulkitxm/edith/contributors?per_page=100";
const AVATAR_SIZE = 64;
const PER_ROW = 8;

export function people(payload) {
  return payload
    .filter((person) => !person.login.endsWith("[bot]"))
    .sort((a, b) => b.contributions - a.contributions);
}

export function render(payload) {
  const everyone = people(payload);
  if (everyone.length === 0) return "";
  const cells = everyone.map(
    (person) =>
      `<td align="center"><a href="${person.html_url}"><img src="${person.avatar_url}&s=${AVATAR_SIZE}" width="${AVATAR_SIZE}" height="${AVATAR_SIZE}" alt="${person.login}" /><br /><sub>${person.login}</sub></a></td>`,
  );
  const rows = [];
  for (let index = 0; index < cells.length; index += PER_ROW) {
    rows.push(
      `  <tr>\n${cells
        .slice(index, index + PER_ROW)
        .map((cell) => `    ${cell}`)
        .join("\n")}\n  </tr>`,
    );
  }
  return `<table>\n${rows.join("\n")}\n</table>`;
}

export function replaceSection(readme, table) {
  const start = readme.indexOf(START);
  const end = readme.indexOf(END);
  if (start === -1 || end === -1 || end < start) {
    throw new Error("README is missing the contributors markers");
  }
  const before = readme.slice(0, start + START.length);
  const after = readme.slice(end);
  return `${before}\n\n${table}\n\n${after}`;
}

async function fetchContributors() {
  const headers = { accept: "application/vnd.github+json" };
  if (process.env.GITHUB_TOKEN) {
    headers.authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  }
  const response = await fetch(ENDPOINT, { headers });
  if (!response.ok) {
    throw new Error(`GitHub answered ${response.status}`);
  }
  return response.json();
}

if (import.meta.main) {
  const payload = await fetchContributors();
  const table = render(payload);
  if (!table) {
    console.error("refusing to write an empty contributor list");
    process.exit(1);
  }
  const path = "README.md";
  const updated = replaceSection(readFileSync(path, "utf8"), table);
  writeFileSync(path, updated);
  console.log(`wrote ${people(payload).length} contributors to ${path}`);
}
