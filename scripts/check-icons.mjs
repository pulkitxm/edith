import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const OWN_PACKAGE = "Packages/EdithIcons/";
const FORBIDDEN_LIBRARY =
  /^(lucide|lucide-react|react-icons|heroicons|@heroicons\/.+|@phosphor-icons\/.+|phosphor-react|@tabler\/icons.*|@fortawesome\/.+|font-awesome|feather-icons|bootstrap-icons|ionicons|@mdi\/.+|remixicon)$/;

const SYSTEM_APIS = [
  /\bImage\(\s*systemName:/g,
  /\bNSImage\(\s*systemSymbolName:/g,
  /\bUIImage\(\s*systemName:/g,
  /\bsystemImage:/g,
  /\bsystemSymbolName\b/g,
  /\.symbolEffect\(/g,
  /\.symbolRenderingMode\(/g,
  /\.symbolVariant\(/g,
];
const DOTTED_LITERAL = /"([a-z0-9]+(?:\.[a-z0-9]+)+)"/g;
const WORD_LITERAL = /"([a-z]+)"/g;
const ICON_NAME_LITERAL = /\bEdithIcon\(\s*name:\s*"([^"\\]*)"/g;
const UNDOTTED_SYMBOLS = new Set([
  "archivebox",
  "checkmark",
  "cursorarrow",
  "curlybraces",
  "desktopcomputer",
  "externaldrive",
  "gearshape",
  "internaldrive",
  "laptopcomputer",
  "macwindow",
  "magnifyingglass",
  "memorychip",
  "nosign",
  "paintpalette",
  "paperplane",
  "shippingbox",
  "sparkle",
  "sparkles",
  "speedometer",
  "tablecells",
  "textformat",
  "xmark",
]);

const lineOf = (text, index) => text.slice(0, index).split("\n").length;

export function findViolations(text, symbolNames, iconNames) {
  const found = [];
  for (const pattern of SYSTEM_APIS)
    for (const match of text.matchAll(pattern))
      found.push({ line: lineOf(text, match.index), reason: match[0] });
  for (const match of text.matchAll(DOTTED_LITERAL))
    if (symbolNames.has(match[1]))
      found.push({
        line: lineOf(text, match.index),
        reason: `system symbol name ${match[1]}`,
      });
  for (const match of text.matchAll(WORD_LITERAL))
    if (UNDOTTED_SYMBOLS.has(match[1]))
      found.push({
        line: lineOf(text, match.index),
        reason: `system symbol name ${match[1]}`,
      });
  for (const match of text.matchAll(ICON_NAME_LITERAL))
    if (!iconNames.has(match[1]))
      found.push({
        line: lineOf(text, match.index),
        reason: `unknown icon name ${match[1]}`,
      });
  return found.sort((a, b) => a.line - b.line);
}

export function findForbiddenLibraries(manifest) {
  return Object.keys({
    ...manifest.dependencies,
    ...manifest.devDependencies,
  }).filter((name) => FORBIDDEN_LIBRARY.test(name));
}

function trackedFiles(pattern) {
  return execSync(`git ls-files -c -o --exclude-standard ${pattern}`, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  })
    .split("\n")
    .filter((path) => path && existsSync(path));
}

if (import.meta.main) {
  const map = JSON.parse(readFileSync(`${OWN_PACKAGE}symbol-map.json`, "utf8"));
  const symbolNames = new Set(
    Object.keys(map.symbols).filter((name) => name.includes(".")),
  );
  const { icons, aliases } = JSON.parse(
    readFileSync(`${OWN_PACKAGE}names.json`, "utf8"),
  );
  const iconNames = new Set([...icons, ...Object.keys(aliases)]);
  const failures = [];
  for (const path of trackedFiles("'*.swift'")) {
    if (path.startsWith(OWN_PACKAGE)) continue;
    for (const { line, reason } of findViolations(
      readFileSync(path, "utf8"),
      symbolNames,
      iconNames,
    ))
      failures.push(`${path}:${line}: ${reason}`);
  }
  for (const path of trackedFiles("'package.json' '**/package.json'"))
    for (const name of findForbiddenLibraries(
      JSON.parse(readFileSync(path, "utf8")),
    ))
      failures.push(`${path}: icon library ${name}`);
  if (failures.length) {
    console.error(failures.join("\n"));
    console.error(
      `check-icons: ${failures.length} violations. Draw the icon in Packages/EdithIcons, see skills/edith-icons/SKILL.md`,
    );
    process.exit(1);
  }
  console.log("check-icons: every icon comes from Packages/EdithIcons");
}
