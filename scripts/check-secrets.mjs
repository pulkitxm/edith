import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const SELF = "scripts/check-secrets.mjs";

const RULES = [
  {
    name: "license key",
    re: /EDITH-[A-Z0-9]{4}(?:-[A-Z0-9]{4}){3}/g,
    allowed: (match, file) =>
      match.includes("XXXX") || /(^|\/)[Tt]ests\//.test(file),
  },
  {
    name: "refresh credential",
    re: /edithrc_[A-Za-z0-9_-]{16,}/g,
    allowed: (match) => match.includes("XXXX"),
  },
  {
    name: "private key block",
    re: /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/g,
    allowed: () => false,
  },
  {
    name: "ed25519 seed assignment",
    re: /(?:seed|private[_-]?key)["']?\s*[:=]\s*["'][A-Za-z0-9+/]{40,}={0,2}["']/gi,
    allowed: (match) => match.includes("XXXX"),
  },
];

const files = execSync("git ls-files -z", { encoding: "utf8" })
  .split("\0")
  .filter((f) => f && f !== SELF);

const findings = [];
for (const file of files) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    continue;
  }
  if (text.includes("\u0000")) continue;
  for (const rule of RULES) {
    for (const match of text.matchAll(rule.re)) {
      if (rule.allowed(match[0], file)) continue;
      const line = text.slice(0, match.index).split("\n").length;
      findings.push(`${file}:${line}: ${rule.name}`);
    }
  }
}

if (findings.length > 0) {
  for (const finding of findings) console.error(finding);
  console.error(`${findings.length} potential secret(s) found`);
  process.exit(1);
}
console.log(`check-secrets: ${files.length} tracked files clean`);
