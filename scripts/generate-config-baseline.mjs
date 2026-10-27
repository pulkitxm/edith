import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const [ed, output] = process.argv.slice(2);
if (!ed || !output) {
  console.error("usage: bun scripts/generate-config-baseline.mjs <v0.0.350 ed> <output.json>");
  process.exit(2);
}

const rows = JSON.parse(
  execFileSync(ed, ["config", "ls", "--json"], { encoding: "utf8", maxBuffer: 1 << 24 }),
);
const fields = [
  "key",
  "type",
  "group",
  "summary",
  "scope",
  "allowed",
  "minimum",
  "maximum",
  "default",
  "readOnly",
];
const baseline = rows
  .map((row) => Object.fromEntries(fields.filter((f) => row[f] !== undefined).map((f) => [f, row[f]])))
  .sort((a, b) => (a.key < b.key ? -1 : 1));
writeFileSync(output, `${JSON.stringify(baseline, null, 2)}\n`);
console.log(`wrote ${baseline.length} settings to ${output}`);
