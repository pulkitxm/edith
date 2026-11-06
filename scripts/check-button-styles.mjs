import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

export const ALLOWED = new Map([
  ["Packages/ExtensionSupport/Sources/EdithExtensionUI/EdithSwitch.swift", 1],
  [
    "Packages/ExtensionSupport/Sources/EdithExtensionUI/SurfaceCalendarContent.swift",
    1,
  ],
]);

const BYPASSES = [
  [/\.buttonStyle\(\s*\.plain\s*\)/g, ".buttonStyle(.plain)"],
  [/\.buttonStyle\(\s*\.borderless\s*\)/g, ".buttonStyle(.borderless)"],
  [/\.buttonStyle\(\s*\.link\s*\)/g, ".buttonStyle(.link)"],
  [/\.buttonStyle\(\s*\.bordered(Prominent)?\s*\)/g, ".buttonStyle(.bordered)"],
  [
    /\.buttonStyle\(\s*\.accessoryBar(Action)?\s*\)/g,
    ".buttonStyle(.accessoryBar)",
  ],
  [/\bPlainButtonStyle\(\s*\)/g, "PlainButtonStyle()"],
  [/\bBorderlessButtonStyle\(\s*\)/g, "BorderlessButtonStyle()"],
  [/\.menuStyle\(\s*\.borderlessButton\s*\)/g, ".menuStyle(.borderlessButton)"],
];

export function findBypasses(text) {
  const found = [];
  const lines = text.split("\n");
  lines.forEach((content, index) => {
    for (const [pattern, reason] of BYPASSES) {
      pattern.lastIndex = 0;
      if (pattern.test(content)) found.push({ line: index + 1, reason });
    }
  });
  return found;
}

export function excluded(path) {
  return (
    path.includes("/Tests/") ||
    path.startsWith("Packages/EdithIcons/tools/") ||
    !path.endsWith(".swift")
  );
}

export function failuresFor(files, allowed = ALLOWED) {
  const failures = [];
  for (const { path, text } of files) {
    if (excluded(path)) continue;
    const found = findBypasses(text);
    const budget = allowed.get(path) ?? 0;
    if (found.length > budget)
      for (const { line, reason } of found)
        failures.push(
          `${path}:${line}: ${reason} skips the shared hover state`,
        );
  }
  return failures;
}

if (import.meta.main) {
  const paths = execSync(
    "git ls-files --cached --others --exclude-standard -- '*.swift'",
    {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    },
  )
    .split("\n")
    .filter((path) => path && existsSync(path));
  const failures = failuresFor(
    paths.map((path) => ({ path, text: readFileSync(path, "utf8") })),
  );
  if (failures.length) {
    console.error(failures.join("\n"));
    console.error(
      `check-button-styles: ${failures.length} buttons bypass the kit. Use .edith(...), .edithLink, .pageChip, .borderlessMenu() or .edithHoverHighlight()`,
    );
    process.exit(1);
  }
  console.log("check-button-styles: every button uses a kit style");
}
