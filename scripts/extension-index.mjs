import { readdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import iconNames from "../Packages/EdithIcons/names.json" with { type: "json" };

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

const pageParents = ["agents", "utilities", "media", "developer"];
const sectionPages = ["appMaintenance"];
const surfaceCards = [
  "actions",
  "activity",
  "usage",
  "limits",
  "music",
  "calendar",
  "codeStats",
  "agents",
  "focus",
  "databases",
  "machines",
  "desk",
  "media",
  "github",
];
const notchTabs = [
  "agents",
  "browser",
  "files",
  "clipboard",
  "audio",
  "camera",
];

function surfaceItems(declaration, directory, field, allowed) {
  const values = declaration[field] ?? [];
  if (
    !Array.isArray(values) ||
    values.some((value) => !allowed.includes(value)) ||
    new Set(values).size !== values.length
  )
    throw new Error(
      `${directory}: ${field} must contain unique registered surface ids`,
    );
  return values;
}

function checked(declaration, directory, field, required, optional = {}) {
  const allowed = [...Object.keys(required), ...Object.keys(optional)];
  const unknown = Object.keys(declaration).filter(
    (key) => !allowed.includes(key),
  );
  const invalid = Object.entries(required).filter(
    ([key, type]) =>
      typeof declaration[key] !== type ||
      (type === "string" && !declaration[key]) ||
      (type === "number" && !Number.isInteger(declaration[key])),
  );
  const invalidOptional = Object.entries(optional).filter(
    ([key, type]) =>
      Object.hasOwn(declaration, key) && typeof declaration[key] !== type,
  );
  if (unknown.length || invalid.length || invalidOptional.length)
    throw new Error(
      `${directory}: ${field} need ${Object.keys(required).join(", ")}`,
    );
  return declaration;
}

const knownIcons = new Set([
  ...iconNames.icons,
  ...Object.keys(iconNames.aliases ?? {}),
]);

function requireIcon(name, directory) {
  if (!knownIcons.has(name))
    throw new Error(
      `${directory}: unknown icon ${name}, draw it in Packages/EdithIcons`,
    );
}

function page(declaration, directory) {
  requireIcon(declaration.icon, directory);
  const { detachable = true, ...rest } = checked(
    declaration,
    directory,
    "pages",
    {
      id: "string",
      title: "string",
      icon: "string",
      order: "number",
    },
    { detachable: "boolean", logoName: "string" },
  );
  return { ...rest, detachable };
}

function section(declaration, directory) {
  requireIcon(declaration.icon, directory);
  checked(declaration, directory, "sections", {
    page: "string",
    id: "string",
    title: "string",
    icon: "string",
    summary: "string",
    order: "number",
  });
  if (!sectionPages.includes(declaration.page))
    throw new Error(`${directory}: unknown section page ${declaration.page}`);
  return declaration;
}

function guide(declaration, directory) {
  if (declaration === undefined) return undefined;
  const fail = (reason) => {
    throw new Error(`${directory}: guide ${reason}`);
  };
  if (typeof declaration !== "object" || Array.isArray(declaration))
    fail("must be an object");
  const allowed = ["tagline", "summary", "steps", "examples"];
  const unknown = Object.keys(declaration).filter(
    (key) => !allowed.includes(key),
  );
  if (unknown.length) fail(`has unknown keys ${unknown.join(", ")}`);
  for (const key of ["tagline", "summary"])
    if (typeof declaration[key] !== "string" || !declaration[key].trim())
      fail(`needs ${key}`);
  if (declaration.tagline.length > 90)
    fail("tagline must be 90 characters or fewer");
  if (declaration.summary.length > 280)
    fail("summary must be 280 characters or fewer");
  const steps = declaration.steps;
  if (!Array.isArray(steps) || steps.length < 2 || steps.length > 4)
    fail("needs two to four steps");
  const stepKeys = ["icon", "title", "detail"];
  for (const step of steps)
    if (
      typeof step !== "object" ||
      Object.keys(step).some((key) => !stepKeys.includes(key)) ||
      stepKeys.some((key) => typeof step[key] !== "string" || !step[key].trim())
    )
      fail(`steps need ${stepKeys.join(", ")}`);
  for (const step of steps) requireIcon(step.icon, directory);
  const examples = declaration.examples ?? [];
  if (
    !Array.isArray(examples) ||
    examples.length > 4 ||
    examples.some(
      (example) => typeof example !== "string" || !example.startsWith("ed "),
    )
  )
    fail("examples must be up to four ed commands");
  return { ...declaration, examples };
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
    "icon",
    "category",
    "background",
    "commands",
    "hotkeys",
    "launchWhen",
    "pages",
    "sections",
    "homeCards",
    "notchCards",
    "notchTabs",
    "guide",
  ];
  const unknown = Object.keys(declaration).filter((key) => !keys.includes(key));
  if (unknown.length)
    throw new Error(`${directory}: unknown keys ${unknown.join(", ")}`);
  if (declaration.id !== directory)
    throw new Error(`${directory}: id must match its directory`);
  for (const key of ["title", "icon"])
    if (typeof declaration[key] !== "string" || !declaration[key])
      throw new Error(`${directory}: ${key} is required`);
  requireIcon(declaration.icon, directory);
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
  const launchWhen = declaration.launchWhen ?? [];
  if (
    !Array.isArray(launchWhen) ||
    launchWhen.some(
      (condition) =>
        Object.keys(condition).some(
          (key) => !["key", "default"].includes(key),
        ) ||
        typeof condition.key !== "string" ||
        !condition.key ||
        typeof condition.default !== "boolean",
    )
  )
    throw new Error(`${directory}: launchWhen needs key and boolean default`);
  if (declaration.background && launchWhen.length)
    throw new Error(`${directory}: background already starts at launch`);
  for (const field of ["hotkeys", "pages", "sections"])
    if (!Array.isArray(declaration[field] ?? []))
      throw new Error(`${directory}: ${field} must be a list`);
  const pages = (declaration.pages ?? []).map((entry) =>
    page(entry, directory),
  );
  if (pages.length && !pageParents.includes(declaration.category))
    throw new Error(
      `${directory}: ${declaration.category} extensions have no pages`,
    );
  return {
    ...declaration,
    launchWhen,
    homeCards: surfaceItems(declaration, directory, "homeCards", [
      ...surfaceCards,
      `extension:${directory}`,
    ]),
    notchCards: surfaceItems(declaration, directory, "notchCards", [
      ...surfaceCards,
      `extension:${directory}`,
    ]),
    notchTabs: surfaceItems(declaration, directory, "notchTabs", notchTabs),
    pages,
    sections: (declaration.sections ?? []).map((entry) =>
      section(entry, directory),
    ),
    hotkeys: (declaration.hotkeys ?? []).map((entry) =>
      hotkey(entry, directory),
    ),
    ...(declaration.guide === undefined
      ? {}
      : { guide: guide(declaration.guide, directory) }),
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
  for (const [field, values] of [
    ["page id", index.flatMap(({ pages }) => pages.map(({ id }) => id))],
    [
      "section id",
      index.flatMap(({ sections }) => sections.map(({ id }) => id)),
    ],
  ])
    if (new Set(values).size !== values.length)
      throw new Error(`Two extensions declare the same ${field}`);
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
