import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { parse } from "@babel/parser";
import { validateFunctionalCaseDefinition } from "./contract.mjs";
import {
  functionalActionCasePaths,
  functionalActionOwners,
} from "./owners.mjs";

export async function loadFunctionalActionCase(
  root,
  owner,
  read = readFile,
  admittedSnapshot,
) {
  const paths = functionalActionCasePaths(owner);
  assert.match(admittedSnapshot.sourceCommit, /^[0-9a-f]{40}$/);
  assert.deepEqual(Object.keys(admittedSnapshot).sort(), [
    "files",
    "sourceCommit",
  ]);
  assert(Array.isArray(admittedSnapshot.files));
  assert(
    admittedSnapshot.files.length >= 3 && admittedSnapshot.files.length <= 10,
  );
  const pins = new Map();
  for (const pin of admittedSnapshot.files) {
    assert.deepEqual(Object.keys(pin).sort(), ["path", "sha256"]);
    assert.match(pin.sha256, /^[0-9a-f]{64}$/);
    assert(!pins.has(pin.path));
    pins.set(pin.path, pin.sha256);
  }
  const admit = (path, bytes) => {
    assert.equal(
      createHash("sha256").update(bytes).digest("hex"),
      pins.get(path),
      "Case source differs from the independently admitted snapshot",
    );
  };
  const [definitionBytes, nativeBytes] = await Promise.all([
    read(join(root, paths.definition)),
    read(join(root, paths.native)),
  ]);
  assert(definitionBytes.length > 0 && definitionBytes.length <= 32768);
  assert(nativeBytes.length > 0 && nativeBytes.length <= 65536);
  admit(paths.definition, definitionBytes);
  admit(paths.native, nativeBytes);
  const tree = parse(definitionBytes.toString("utf8"), {
    sourceType: "module",
  });
  assert.equal(tree.program.body.length, 1);
  const statement = tree.program.body[0];
  assert.equal(statement.type, "ExportNamedDeclaration");
  assert.equal(statement.specifiers.length, 0);
  const declaration = statement.declaration;
  assert.equal(declaration.type, "VariableDeclaration");
  assert.equal(declaration.kind, "const");
  assert.equal(declaration.declarations.length, 1);
  assert.equal(declaration.declarations[0].id.name, "definition");
  const definition = validateFunctionalCaseDefinition(
    literal(declaration.declarations[0].init),
  );
  assert.equal(definition.owner, owner);
  assert.deepEqual(
    [...pins.keys()].sort(),
    [
      paths.definition,
      paths.native,
      ...definition.activation.sources.map((pin) => pin.path),
    ].sort(),
  );
  for (const pin of definition.activation.sources) {
    assert.equal(pins.get(pin.path), pin.sha256);
    assert.equal(
      createHash("sha256")
        .update(await read(join(root, pin.path)))
        .digest("hex"),
      pin.sha256,
      "Original control source changed",
    );
  }
  assert(
    (await read(join(root, paths.definition))).equals(definitionBytes),
    "Case definition changed during admission",
  );
  assert(
    (await read(join(root, paths.native))).equals(nativeBytes),
    "Native case changed during admission",
  );
  return Object.freeze({
    definition: freezeLiteral(definition),
    sourceCommit: admittedSnapshot.sourceCommit,
    sourcePins: [
      {
        path: paths.definition,
        sha256: createHash("sha256").update(definitionBytes).digest("hex"),
      },
      {
        path: paths.native,
        sha256: createHash("sha256").update(nativeBytes).digest("hex"),
      },
    ],
  });
}

function freezeLiteral(value) {
  if (value && typeof value === "object") {
    for (const child of Object.values(value)) freezeLiteral(child);
    Object.freeze(value);
  }
  return value;
}

export async function loadAllFunctionalActionCases(
  root,
  read = readFile,
  admittedSnapshots,
) {
  const cases = [];
  for (const owner of functionalActionOwners)
    cases.push(
      await loadFunctionalActionCase(
        root,
        owner,
        read,
        admittedSnapshots?.[owner],
      ),
    );
  assert.equal(cases.length, 39);
  return Object.freeze(cases);
}

function literal(node, depth = 0) {
  assert(node && depth < 64);
  if (["StringLiteral", "BooleanLiteral", "NumericLiteral"].includes(node.type))
    return node.value;
  if (node.type === "NullLiteral") return null;
  if (node.type === "ArrayExpression")
    return node.elements.map((element) => literal(element, depth + 1));
  assert.equal(node.type, "ObjectExpression");
  const entries = [],
    seen = new Set();
  for (const property of node.properties) {
    assert.equal(property.type, "ObjectProperty");
    assert.equal(property.computed, false);
    assert.equal(property.shorthand, false);
    assert(["Identifier", "StringLiteral"].includes(property.key.type));
    const key = property.key.name ?? property.key.value;
    assert(
      !seen.has(key) &&
        !["__proto__", "constructor", "prototype"].includes(key),
    );
    seen.add(key);
    entries.push([key, literal(property.value, depth + 1)]);
  }
  return Object.fromEntries(entries);
}
