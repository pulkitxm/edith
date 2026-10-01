import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const rootArg = process.argv[2] ?? ".";
const sourceRoot = "Packages/Edith/Sources/Edith";
const fontPattern =
  /\.font\(\.system\(size:\s*(?!UIScale\.pt\()(\d+(?:\.\d+)?)/;
const frameParam =
  /\b(?:width|height|minWidth|maxWidth|minHeight|maxHeight|idealWidth|idealHeight)\s*:\s*(?!UIScale\.pt\()(\d+(?:\.\d+)?)/;

export function loadAllowlist(text) {
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => {
      const [path, ...rest] = line.split("\t");
      return { path, snippet: rest.join("\t") };
    });
}

export function lineAllowed(file, line, allowlist) {
  return allowlist.some(
    (entry) => file.endsWith(entry.path) && line.includes(entry.snippet),
  );
}

export function violationsIn(file, text, allowlist) {
  const found = [];
  const lines = text.split("\n");
  lines.forEach((line, index) => {
    if (lineAllowed(file, line, allowlist)) return;
    if (fontPattern.test(line)) {
      found.push({ file, line: index + 1, text: line.trim() });
    }
  });
  let cursor = 0;
  while (cursor < text.length) {
    const start = text.indexOf(".frame(", cursor);
    if (start < 0) break;
    let depth = 0;
    let end = start;
    for (; end < text.length; end += 1) {
      const char = text[end];
      if (char === "(") depth += 1;
      else if (char === ")") {
        depth -= 1;
        if (depth === 0) {
          end += 1;
          break;
        }
      }
    }
    const span = text.slice(start, end);
    const line = text.slice(0, start).split("\n").length;
    const pieces = span.split("\n");
    pieces.forEach((piece, offset) => {
      const absolute = line + offset;
      const source = lines[absolute - 1] ?? piece;
      if (lineAllowed(file, source, allowlist)) return;
      if (frameParam.test(piece)) {
        found.push({ file, line: absolute, text: source.trim() });
      }
    });
    cursor = end;
  }
  return found;
}

function swiftFiles(dir) {
  const found = [];
  for (const name of readdirSync(dir)) {
    if (name.startsWith("._")) continue;
    const path = join(dir, name);
    const info = statSync(path);
    if (info.isDirectory()) found.push(...swiftFiles(path));
    else if (name.endsWith(".swift")) found.push(path);
  }
  return found;
}

export function violations(repo) {
  const allowlist = loadAllowlist(
    readFileSync(join(repo, "scripts/ui-scale-literal-allowlist.txt"), "utf8"),
  );
  const root = join(repo, sourceRoot);
  return swiftFiles(root).flatMap((path) =>
    violationsIn(relative(repo, path), readFileSync(path, "utf8"), allowlist),
  );
}

if (import.meta.main) {
  const found = violations(rootArg);
  if (found.length === 0) process.exit(0);
  for (const item of found) {
    process.stderr.write(`${item.file}:${item.line}: ${item.text}\n`);
  }
  process.exit(1);
}
