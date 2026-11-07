import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const raw = execFileSync(
  "gh",
  [
    "api",
    "repos/pulkitxm/edith/releases?per_page=100",
    "--paginate",
    "--jq",
    '.[] | select(.tag_name | test("^v[0-9]+\\\\.[0-9]+\\\\.[0-9]+$")) | {tag: .tag_name, date: .published_at, body: .body}',
  ],
  { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
);
const releases = raw
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line))
  .filter(({ date }) => date)
  .map(({ tag, date, body }) => ({
    version: tag.slice(1),
    date: date.slice(0, 10),
    changes: [
      ...(body ?? "").matchAll(
        /^\* (.+?) by @[\w-]+ in https:\/\/github\.com\/pulkitxm\/edith\/pull\/(\d+)$/gm,
      ),
    ].map(([, title, pr]) => ({ title, pr: Number(pr) })),
  }))
  .sort((a, b) =>
    b.version.localeCompare(a.version, undefined, { numeric: true }),
  );
writeFileSync(
  new URL("./changelog.json", import.meta.url),
  `${JSON.stringify(releases, null, 2)}\n`,
);
console.log(
  `${releases.length} releases, ${releases.reduce((n, r) => n + r.changes.length, 0)} changes`,
);

const latest = JSON.parse(
  execFileSync("gh", ["api", "repos/pulkitxm/edith/releases/latest"], {
    encoding: "utf8",
  }),
);
const dmg = latest.assets.find((asset) => asset.name === "Edith.dmg");
if (!dmg) throw new Error("the latest release has no Edith.dmg");
writeFileSync(
  new URL("./release.json", import.meta.url),
  `${JSON.stringify({ version: latest.tag_name.replace(/^v/, ""), date: latest.published_at.slice(0, 10), dmgBytes: dmg.size }, null, 2)}\n`,
);
console.log(`latest ${latest.tag_name} with a ${dmg.size} byte DMG`);
