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

export function validateDeclaration(declaration, directory) {
  const keys = [
    "id",
    "title",
    "symbolName",
    "category",
    "background",
    "commands",
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
  return declaration;
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
