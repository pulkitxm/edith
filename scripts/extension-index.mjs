import { readdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

export const indexPath =
  "Packages/EdithHost/Sources/EdithHostCore/Resources/index.json";

const categories = [
  "agents",
  "utilities",
  "desk",
  "media",
  "developer",
  "labs",
];
const commandWord = /^[a-z][a-z0-9-]{0,40}$/;
const keyCodes = {
  a: 0,
  s: 1,
  d: 2,
  f: 3,
  h: 4,
  g: 5,
  z: 6,
  x: 7,
  c: 8,
  v: 9,
  b: 11,
  q: 12,
  w: 13,
  e: 14,
  r: 15,
  y: 16,
  t: 17,
  o: 31,
  u: 32,
  i: 34,
  p: 35,
  l: 37,
  j: 38,
  k: 40,
  n: 45,
  m: 46,
  space: 49,
};
const modifierKeys = [
  ["control", 4096, "\u2303"],
  ["option", 2048, "\u2325"],
  ["shift", 512, "\u21e7"],
  ["command", 256, "\u2318"],
];

export function parseShortcut(shortcut, context) {
  const parts = String(shortcut).split("+");
  const key = parts.pop();
  const modifiers = modifierKeys.filter(([name]) => parts.includes(name));
  if (
    !Object.hasOwn(keyCodes, key) ||
    !modifiers.length ||
    modifiers.length !== parts.length ||
    new Set(parts).size !== parts.length
  )
    throw new Error(`${context}: invalid shortcut ${shortcut}`);
  return {
    code: keyCodes[key],
    modifiers: modifiers.reduce((sum, [, value]) => sum + value, 0),
    label:
      modifiers.map(([, , symbol]) => symbol).join("") +
      (key === "space" ? "\u2423" : key.toUpperCase()),
  };
}

function hotkey(declaration, directory) {
  const keys = ["id", "prefix", "title", "subtitle", "shortcut"];
  if (
    Object.keys(declaration).some((key) => !keys.includes(key)) ||
    keys.some(
      (key) => typeof declaration[key] !== "string" || !declaration[key],
    )
  )
    throw new Error(`${directory}: hotkeys need ${keys.join(", ")}`);
  const { shortcut, ...rest } = declaration;
  return { ...rest, ...parseShortcut(shortcut, directory) };
}

export function validateDeclaration(declaration, directory) {
  const keys = [
    "id",
    "title",
    "symbolName",
    "category",
    "background",
    "commands",
    "hotkeys",
    "launchWhen",
  ];
  const unknown = Object.keys(declaration).filter((key) => !keys.includes(key));
  if (unknown.length)
    throw new Error(`${directory}: unknown keys ${unknown.join(", ")}`);
  if (declaration.id !== directory)
    throw new Error(`${directory}: id must match its directory`);
  for (const key of ["title", "symbolName"])
    if (typeof declaration[key] !== "string" || !declaration[key])
      throw new Error(`${directory}: ${key} is required`);
  if (!categories.includes(declaration.category))
    throw new Error(`${directory}: unknown category ${declaration.category}`);
  if (typeof declaration.background !== "boolean")
    throw new Error(`${directory}: background must be true or false`);
  if (
    !Array.isArray(declaration.commands) ||
    declaration.commands.some((word) => !commandWord.test(word)) ||
    new Set(declaration.commands).size !== declaration.commands.length
  )
    throw new Error(`${directory}: commands must be unique command words`);
  if (!Array.isArray(declaration.hotkeys ?? []))
    throw new Error(`${directory}: hotkeys must be a list`);
  const launchWhen = declaration.launchWhen ?? [];
  if (
    !Array.isArray(launchWhen) ||
    launchWhen.some(
      (condition) =>
        Object.keys(condition).some((key) => !["key", "default"].includes(key)) ||
        typeof condition.key !== "string" ||
        !condition.key ||
        typeof condition.default !== "boolean",
    )
  )
    throw new Error(`${directory}: launchWhen needs key and boolean default`);
  if (declaration.background && launchWhen.length)
    throw new Error(`${directory}: background already starts at launch`);
  return {
    ...declaration,
    launchWhen,
    hotkeys: (declaration.hotkeys ?? []).map((entry) =>
      hotkey(entry, directory),
    ),
  };
}

export async function extensionDeclarations(root = process.cwd()) {
  const declarations = [];
  for (const entry of await readdir(resolve(root, "Extensions"), {
    withFileTypes: true,
  })) {
    if (!entry.isDirectory()) continue;
    const path = resolve(root, "Extensions", entry.name, "package.json");
    let source;
    try {
      source = await readFile(path, "utf8");
    } catch (error) {
      if (error.code === "ENOENT") continue;
      throw error;
    }
    declarations.push(validateDeclaration(JSON.parse(source), entry.name));
  }
  return declarations;
}

export function orderedIndex(declarations, previous = []) {
  const position = new Map(previous.map(({ id }, index) => [id, index]));
  return declarations.toSorted(
    (left, right) =>
      categories.indexOf(left.category) - categories.indexOf(right.category) ||
      (position.get(left.id) ?? Number.MAX_SAFE_INTEGER) -
        (position.get(right.id) ?? Number.MAX_SAFE_INTEGER) ||
      left.id.localeCompare(right.id),
  );
}

export async function renderIndex(root = process.cwd()) {
  const previous = JSON.parse(await readFile(resolve(root, indexPath), "utf8"));
  const index = orderedIndex(await extensionDeclarations(root), previous);
  for (const field of ["id", "prefix"]) {
    const values = index.flatMap(({ hotkeys }) =>
      hotkeys.map((entry) => entry[field]),
    );
    if (new Set(values).size !== values.length)
      throw new Error(`Two hotkeys declare the same ${field}`);
  }
  return `${JSON.stringify(index, null, 2)}\n`;
}

if (import.meta.main) {
  const mode = process.argv[2];
  if (!["--check", "--write"].includes(mode))
    throw new Error("Usage: extension-index.mjs --check|--write");
  const rendered = await renderIndex();
  const current = await readFile(resolve(indexPath), "utf8");
  if (mode === "--write") {
    if (rendered !== current) await writeFile(resolve(indexPath), rendered);
  } else if (rendered !== current) {
    console.error(
      `${indexPath} is out of date. Run bun scripts/extension-index.mjs --write`,
    );
    process.exit(1);
  }
}
