import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

export const ALLOWLIST_PATH = "scripts/button-hover-allowlist.json";

const LINE_RULES = [
  ["plain", /\.buttonStyle\(\s*\.plain\s*\)/g, ".buttonStyle(.plain)"],
  [
    "borderless",
    /\.buttonStyle\(\s*\.borderless\s*\)/g,
    ".buttonStyle(.borderless)",
  ],
  ["link-style", /\.buttonStyle\(\s*\.link\s*\)/g, ".buttonStyle(.link)"],
  [
    "bordered",
    /\.buttonStyle\(\s*\.bordered(Prominent)?\s*\)/g,
    ".buttonStyle(.bordered)",
  ],
  [
    "accessory-bar",
    /\.buttonStyle\(\s*\.accessoryBar(Action)?\s*\)/g,
    ".buttonStyle(.accessoryBar)",
  ],
  ["plain", /\bPlainButtonStyle\(\s*\)/g, "PlainButtonStyle()"],
  ["borderless", /\bBorderlessButtonStyle\(\s*\)/g, "BorderlessButtonStyle()"],
  [
    "borderless-menu",
    /\.menuStyle\(\s*\.borderlessButton\s*\)/g,
    ".menuStyle(.borderlessButton)",
  ],
  ["tap-gesture", /\.onTapGesture\b/g, ".onTapGesture"],
  [
    "tap-gesture",
    /\b(simultaneousGesture|highPriorityGesture|gesture)\(\s*TapGesture\b/g,
    "TapGesture",
  ],
  [
    "link",
    /(?<![\w.])Link\(\s*(destination:|"|\w+\s*,\s*destination:)/g,
    "Link",
  ],
  ["appkit-button", /\bNSButton\(/g, "NSButton"],
  ["control-style", /\.buttonStyle\(\s*\.edithControl\s*\)/g, ".edithControl"],
];

const MESSAGES = {
  plain: "skips the shared hover plate",
  borderless: "skips the shared hover plate",
  "link-style": "skips the shared hover plate",
  bordered: "skips the shared hover plate",
  "accessory-bar": "skips the shared hover plate",
  "borderless-menu": "skips the shared hover plate",
  "tap-gesture":
    "is a tap target without a hover plate, use a Button with a kit style",
  link: "skips the hover plate, use EdithLink",
  "appkit-button": "is an AppKit button without the kit hover plate",
  "control-style":
    "is reserved for toggles, checkboxes and segmented pickers, which never show a plate",
  menu: "has no kit style, add .borderlessMenu() or .menuStyle(.button) with a kit button style",
  "shaped-plate":
    "paints its own circle or capsule, use .edithShaped(shape) so no rectangular plate shows behind it",
  "toggle-plate":
    "draws a hover plate inside a toggle style, toggles never show a plate",
};

function maskCode(text) {
  let out = "";
  let i = 0;
  const n = text.length;
  while (i < n) {
    const c = text[i];
    const next = text[i + 1];
    if (c === "/" && next === "/") {
      while (i < n && text[i] !== "\n") {
        out += " ";
        i++;
      }
    } else if (c === "/" && next === "*") {
      while (i < n && !(text[i] === "*" && text[i + 1] === "/")) {
        out += text[i] === "\n" ? "\n" : " ";
        i++;
      }
      out += "  ";
      i += 2;
    } else if (c === '"' && text.startsWith('"""', i)) {
      out += '"""';
      i += 3;
      while (i < n && !text.startsWith('"""', i)) {
        out += text[i] === "\n" ? "\n" : " ";
        i++;
      }
      out += '"""';
      i += 3;
    } else if (c === '"') {
      out += '"';
      i++;
      while (i < n && text[i] !== '"' && text[i] !== "\n") {
        if (text[i] === "\\") {
          out += "  ";
          i += 2;
          continue;
        }
        out += " ";
        i++;
      }
      if (i < n) {
        out += text[i];
        i++;
      }
    } else {
      out += c;
      i++;
    }
  }
  return out;
}

function matching(code, open) {
  const pairs = { "(": ")", "{": "}", "[": "]" };
  const close = pairs[code[open]];
  let depth = 0;
  for (let i = open; i < code.length; i++) {
    if (code[i] === code[open]) depth++;
    else if (code[i] === close) {
      depth--;
      if (depth === 0) return i;
    }
  }
  return code.length - 1;
}

function skipSpace(code, i) {
  while (i < code.length && /\s/.test(code[i])) i++;
  return i;
}

function lineOf(code, index) {
  let line = 1;
  for (let i = 0; i < index; i++) if (code[i] === "\n") line++;
  return line;
}

function menuRegions(code) {
  const regions = [];
  const openers =
    /\b(contextMenu|CommandMenu|CommandGroup|commands|menuBarExtra|MenuBarExtra|menu)\s*(\(|\{)/g;
  for (const match of code.matchAll(openers)) {
    let i = match.index + match[0].length - 1;
    if (code[i] === "(") i = skipSpace(code, matching(code, i) + 1);
    if (code[i] === "{") regions.push([i, matching(code, i)]);
  }
  return regions;
}

export function findMenus(text) {
  const code = maskCode(text);
  const found = [];
  const nested = menuRegions(code);
  const menus = [];
  for (const match of code.matchAll(/(?<![\w.])Menu\s*(\(|\{)/g)) {
    const start = match.index;
    let i = start + match[0].length - 1;
    let content = null;
    let labelled = false;
    if (code[i] === "(") {
      const end = matching(code, i);
      i = skipSpace(code, end + 1);
    }
    while (code[i] === "{") {
      const end = matching(code, i);
      content ??= [i, end];
      i = skipSpace(code, end + 1);
      const label = /^(label|primaryAction)\s*:\s*\{/.exec(code.slice(i));
      if (label) {
        labelled = true;
        i = i + label[0].length - 1;
      }
    }
    let chain = "";
    while (code[i] === ".") {
      const name = /^\.(\w+)/.exec(code.slice(i));
      if (!name) break;
      let j = i + name[0].length;
      j = skipSpace(code, j);
      if (code[j] === "(") j = matching(code, j) + 1;
      j = skipSpace(code, j);
      if (code[j] === "{") j = matching(code, j) + 1;
      chain += name[1] + " ";
      i = skipSpace(code, j);
    }
    menus.push({ start, content, chain, labelled });
  }
  for (const menu of menus) {
    const inside = (region) => menu.start > region[0] && menu.start < region[1];
    if (nested.some(inside)) continue;
    if (
      menus.some(
        (other) => other !== menu && other.content && inside(other.content),
      )
    )
      continue;
    if (/\b(borderlessMenu|menuStyle)\b/.test(menu.chain)) continue;
    const presented =
      menu.labelled ||
      /\b(fixedSize|frame|padding|help|menuIndicator|buttonStyle|font|foregroundStyle|background|controlSize)\b/.test(
        menu.chain,
      );
    if (!presented) continue;
    found.push({ line: lineOf(code, menu.start), rule: "menu" });
  }
  return found;
}

export function findTogglePlates(text) {
  const code = maskCode(text);
  const found = [];
  const bodies = new Set();
  for (const match of code.matchAll(
    /\b(struct|class)\s+(\w+)\s*:\s*[^{]*\bToggleStyle\b[^{]*\{/g,
  )) {
    const open = match.index + match[0].length - 1;
    const body = code.slice(open, matching(code, open) + 1);
    bodies.add(match[2]);
    for (const used of body.matchAll(/\b([A-Z]\w*)\s*\(\s*configuration\s*:/g))
      bodies.add(used[1]);
  }
  for (const name of bodies) {
    const declaration = new RegExp(
      `\\b(struct|class)\\s+${name}\\b[^{]*\\{`,
      "g",
    );
    for (const match of code.matchAll(declaration)) {
      const open = match.index + match[0].length - 1;
      const close = matching(code, open);
      const body = code.slice(open, close);
      const plate =
        /edithHoverHighlight|EdithHoverPlate|EdithOutsetHoverPlate|\.buttonStyle\(\s*\.(edith|edithLink|pageChip)\b/g;
      for (const hit of body.matchAll(plate))
        found.push({
          line: lineOf(code, open + hit.index),
          rule: "toggle-plate",
        });
    }
  }
  return found;
}

const SHAPE_PAINT =
  /\bin:\s*(Circle|Capsule)\(|\.clipShape\(\s*(Circle|Capsule)\(|\.background\(\s*(Circle|Capsule)\(/;
const BARE_SHAPE = /(^|\n)\s*(Circle|Capsule)\(\)/;

export function findShapedPlates(text) {
  const code = maskCode(text);
  const found = [];
  for (const match of code.matchAll(/(?<![\w.])(Button|Menu)\s*(\(|\{)/g)) {
    let i = match.index + match[0].length - 1;
    if (code[i] === "(") i = skipSpace(code, matching(code, i) + 1);
    let label = "";
    while (code[i] === "{") {
      const end = matching(code, i);
      label = code.slice(i, end);
      i = skipSpace(code, end + 1);
      const next = /^label\s*:\s*\{/.exec(code.slice(i));
      if (next) i += next[0].length - 1;
    }
    let plated = false;
    while (code[i] === ".") {
      const name = /^\.(\w+)/.exec(code.slice(i));
      if (!name) break;
      let j = skipSpace(code, i + name[0].length);
      const start = j;
      if (code[j] === "(") j = matching(code, j) + 1;
      if (
        name[1] === "borderlessMenu" ||
        (name[1] === "buttonStyle" &&
          /\.edith\(|EdithButtonStyle\(/.test(code.slice(start, j)))
      )
        plated = true;
      j = skipSpace(code, j);
      if (code[j] === "{") j = matching(code, j) + 1;
      i = skipSpace(code, j);
    }
    if (!plated) continue;
    const bare = BARE_SHAPE.test(label) && !/(?<![\w.])Text\(/.test(label);
    if (SHAPE_PAINT.test(label) || bare)
      found.push({ line: lineOf(code, match.index), rule: "shaped-plate" });
  }
  return found;
}

export function findBypasses(text) {
  const code = maskCode(text);
  const found = [];
  code.split("\n").forEach((content, index) => {
    for (const [rule, pattern] of LINE_RULES) {
      pattern.lastIndex = 0;
      for (const _ of content.matchAll(pattern))
        found.push({ line: index + 1, rule });
    }
  });
  return [
    ...found,
    ...findMenus(text),
    ...findTogglePlates(text),
    ...findShapedPlates(text),
  ].sort((a, b) => a.line - b.line);
}

export function excluded(path) {
  return (
    path.includes("/Tests/") ||
    path.includes("/vendor/") ||
    path.includes("/.build/") ||
    path.startsWith("Packages/EdithIcons/tools/") ||
    !path.endsWith(".swift")
  );
}

export function loadAllowlist(raw) {
  const allowed = new Map();
  for (const entry of raw) {
    if (!entry.path || !entry.rule || !entry.reason?.trim())
      throw new Error(
        `allowlist entry needs path, rule and reason: ${JSON.stringify(entry)}`,
      );
    if (!(entry.rule in MESSAGES))
      throw new Error(`unknown rule ${entry.rule}`);
    allowed.set(`${entry.path}#${entry.rule}`, entry.count ?? 1);
  }
  return allowed;
}

export function failuresFor(files, allowed = new Map()) {
  const failures = [];
  for (const { path, text } of files) {
    if (excluded(path)) continue;
    const byRule = new Map();
    for (const hit of findBypasses(text)) {
      byRule.set(hit.rule, [...(byRule.get(hit.rule) ?? []), hit]);
    }
    for (const [rule, hits] of byRule) {
      const key = `${path}#${rule}`;
      const budget = allowed.get(key) ?? 0;
      if (hits.length > budget)
        for (const { line } of hits)
          failures.push(`${path}:${line}: ${rule} ${MESSAGES[rule]}`);
    }
  }
  return failures;
}

export function staleEntries(files, allowed) {
  const counts = new Map();
  for (const { path, text } of files) {
    if (excluded(path)) continue;
    for (const hit of findBypasses(text)) {
      const key = `${path}#${hit.rule}`;
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
  }
  return [...allowed]
    .filter(([key, budget]) => (counts.get(key) ?? 0) < budget)
    .map(
      ([key, budget]) =>
        `${key} allows ${budget} but finds ${counts.get(key) ?? 0}`,
    );
}

if (import.meta.main) {
  const paths = execSync(
    "git ls-files --cached --others --exclude-standard -- '*.swift'",
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  )
    .split("\n")
    .filter((path) => path && existsSync(path));
  const allowed = loadAllowlist(
    JSON.parse(readFileSync(ALLOWLIST_PATH, "utf8")),
  );
  const files = paths.map((path) => ({
    path,
    text: readFileSync(path, "utf8"),
  }));
  const failures = [
    ...failuresFor(files, allowed),
    ...staleEntries(files, allowed),
  ];
  if (failures.length) {
    console.error(failures.join("\n"));
    console.error(
      `check-button-styles: ${failures.length} problems. Buttons, menus and rows use .edith(...), EdithRowList, .edithLink, .pageChip, .borderlessMenu() or .edithHoverHighlight(); toggles never draw a plate; exceptions go in ${ALLOWLIST_PATH} with a reason`,
    );
    process.exit(1);
  }
  console.log(
    "check-button-styles: every clickable control shows the shared hover state",
  );
}
