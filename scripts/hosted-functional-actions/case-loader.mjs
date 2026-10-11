import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { validateFunctionalCaseDefinition } from "./contract.mjs";
import {
  functionalActionCasePaths,
  functionalActionOwners,
} from "./owners.mjs";

export async function loadFunctionalActionCase(
  root,
  owner,
  read = readFile,
  load = (url) => import(url),
) {
  const paths = functionalActionCasePaths(owner);
  const [definitionBytes, nativeBytes] = await Promise.all([
    read(join(root, paths.definition)),
    read(join(root, paths.native)),
  ]);
  assert(definitionBytes.length > 0 && definitionBytes.length <= 32768);
  assert(nativeBytes.length > 0 && nativeBytes.length <= 65536);
  const module = await load(pathToFileURL(join(root, paths.definition)).href);
  assert.deepEqual(Object.keys(module).sort(), ["definition"]);
  const definition = validateFunctionalCaseDefinition(module.definition);
  assert.equal(definition.owner, owner);
  for (const pin of definition.activation.sources) {
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
    definition,
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

export async function loadAllFunctionalActionCases(
  root,
  read = readFile,
  load,
) {
  const cases = [];
  for (const owner of functionalActionOwners)
    cases.push(await loadFunctionalActionCase(root, owner, read, load));
  assert.equal(cases.length, 39);
  return Object.freeze(cases);
}
