import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(
  new URL("./build-minimal-host.mjs", import.meta.url),
  "utf8",
);
function helper(name) {
  const start = source.indexOf(`function ${name}(`);
  assert(start >= 0);
  const end = source.indexOf("\n}\n", start);
  assert(end > start);
  return vm.runInNewContext(`(${source.slice(start, end + 2)})`, { assert });
}

const requireTracked = helper("requireTrackedHostSource");
const dirty = helper("hostSourceDirty");
function gitOutput(expected, output) {
  return (command, arguments_, options) => {
    assert.equal(command, "git");
    assert.deepEqual(Array.from(arguments_), expected);
    assert.equal(options.encoding, "utf8");
    return output;
  };
}

test("unknown compiled source and source files inside new directories reject before building", () => {
  for (const output of [
    "Packages/EdithHost/Sources/EdithHost/Unexpected.swift\0",
    "Packages/EdithHost/Sources/NewRole/Unexpected.swift\0",
    "Packages/EdithHost/Sources/EdithHost/with space.swift\0",
  ]) {
    assert.throws(() =>
      requireTracked(
        gitOutput(["ls-files", "--others", "--exclude-standard", "-z"], output),
      ),
    );
  }
});

test("ignored build outputs do not enter Git's unknown-source inventory", () => {
  requireTracked(
    gitOutput(["ls-files", "--others", "--exclude-standard", "-z"], ""),
  );
  assert.equal(
    dirty(gitOutput(["status", "--porcelain", "--untracked-files=all"], "")),
    false,
  );
});

test("tracked modifications, maintained version stamps and new source mark metadata dirty", () => {
  for (const output of [
    " M Packages/EdithHost/Sources/EdithHost/HostEntry.swift\n",
    " M Resources/Info.plist\n M Resources/HelperInfo.plist\n",
    "?? Packages/EdithHost/Sources/NewRole/Unexpected.swift\n",
  ]) {
    assert.equal(
      dirty(
        gitOutput(["status", "--porcelain", "--untracked-files=all"], output),
      ),
      true,
    );
  }
});

test("metadata retains dirtiness from either source sample and the exact HEAD guard", () => {
  const expression = source.match(
    /sourceTreeDirty: (sourceTreeDirty \|\| finalSourceTreeDirty),/,
  )?.[1];
  assert(expression);
  assert(source.includes("const finalSourceTreeDirty = hostSourceDirty();"));
  for (const [before, after, expected] of [
    [false, false, false],
    [true, false, true],
    [false, true, true],
    [true, true, true],
  ]) {
    assert.equal(
      vm.runInNewContext(expression, {
        sourceTreeDirty: before,
        finalSourceTreeDirty: after,
      }),
      expected,
    );
  }
  assert(source.includes('"Source commit changed while building the host"'));
  assert.equal(source.split('["rev-parse", "HEAD"]').length, 3);
});
