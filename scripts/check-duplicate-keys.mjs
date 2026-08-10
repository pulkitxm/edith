import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const FOR_KEY = /forKey:\s*"([^"\\]{3,})"/g;

export function findLiterals(text) {
  const found = [];
  for (const m of text.matchAll(FOR_KEY)) {
    const line = text.slice(0, m.index).split("\n").length;
    found.push({ literal: m[1], line });
  }
  return found;
}

export function scanFiles(files) {
  const byLiteral = new Map();
  for (const { path, text } of files) {
    for (const { literal, line } of findLiterals(text)) {
      if (!byLiteral.has(literal)) byLiteral.set(literal, []);
      byLiteral.get(literal).push({ path, line });
    }
  }
  const findings = [];
  for (const [literal, sites] of byLiteral) {
    const distinctFiles = new Set(sites.map((s) => s.path));
    if (distinctFiles.size < 2) continue;
    findings.push({ literal, sites });
  }
  findings.sort((a, b) => a.literal.localeCompare(b.literal));
  return findings;
}

function main() {
  const files = execSync("git ls-files '*.swift'", { encoding: "utf8" })
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean)
    .filter((f) => !/^Packages\/Edith\/Vendor\//.test(f))
    .filter((f) => !/(^|\/)Tests\//.test(f));

  const loaded = files.map((path) => ({
    path,
    text: readFileSync(path, "utf8"),
  }));
  const findings = scanFiles(loaded);

  if (findings.length === 0) {
    console.log(
      `check-duplicate-keys: ${files.length} files clean, no forKey literal appears in more than one file`,
    );
    return;
  }

  for (const { literal, sites } of findings) {
    console.error(
      `"${literal}" is used as a raw UserDefaults key in ${sites.length} places:`,
    );
    for (const { path, line } of sites) console.error(`  ${path}:${line}`);
  }
  console.error(
    `\n${findings.length} UserDefaults key(s) spelled out independently in more than one file.`,
  );
  console.error(
    "Add one constant to AppStorageKeys (Packages/Edith/Sources/EdithKit/Core/AppStorageKeys.swift) and reference it from every site instead.",
  );
  process.exit(1);
}

if (import.meta.main) main();
