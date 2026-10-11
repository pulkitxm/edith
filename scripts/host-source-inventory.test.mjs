import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(
  new URL("./build-minimal-host.mjs", import.meta.url),
  "utf8",
);
function helper(name) {
  const definitions = [
    "hostUntrackedInputs",
    "requireTrackedHostSource",
    "hostSourceDirty",
  ].map((helperName) => {
    const start = source.indexOf(`function ${helperName}(`);
    assert(start >= 0);
    const end = source.indexOf("\n}\n", start);
    assert(end > start);
    return source.slice(start, end + 2);
  });
  return vm.runInNewContext(`${definitions.join("\n")}\n${name}`, { assert });
}

const requireTracked = helper("requireTrackedHostSource");
const dirty = helper("hostSourceDirty");
function gitOutput(expected, output) {
  let first = true;
  return (command, arguments_, options) => {
    assert.equal(command, "git");
    if (first) {
      assert.deepEqual(Array.from(arguments_), expected);
      first = false;
    } else if (arguments_.includes("--exclude-standard")) {
      assert.deepEqual(Array.from(arguments_), [
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
      ]);
    } else {
      assert.equal(arguments_[0], "ls-files");
      assert(arguments_.includes("Extensions/fixtureSupport"));
      assert(arguments_.includes(":(glob,exclude)**/.build/**"));
    }
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

test("a private ignored compiled source rejects while ignored output and Finder metadata remain allowed", async () => {
  const root = await mkdtemp(join(tmpdir(), "host-source-inventory-"));
  const gitDirectory = execFileSync(
    "git",
    ["rev-parse", "--absolute-git-dir"],
    {
      encoding: "utf8",
    },
  ).trim();
  const execute = (command, arguments_, options) =>
    execFileSync(
      command,
      ["--git-dir", gitDirectory, "--work-tree", root, ...arguments_],
      { ...options, env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" } },
    );
  try {
    await writeFile(
      join(root, ".gitignore"),
      ".build/\n.swiftpm/\n.DS_Store\nUntrackedFixture.swift\nUntrackedFixture.json\n",
    );
    for (const path of [
      "Packages/EdithHost/.build/derived.swift",
      "Packages/EdithHost/Sources/.DS_Store",
      "Extensions/fixtureSupport/.build/derived.swift",
    ]) {
      const file = join(root, path);
      await mkdir(dirname(file), { recursive: true });
      await writeFile(file, "synthetic fixture");
    }
    requireTracked(execute);
    for (const path of [
      "Packages/EdithHost/Sources/EdithHost/UntrackedFixture.swift",
      "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/UntrackedFixture.swift",
      "Packages/ExtensionSupport/Sources/EdithExtensionSupport/UntrackedFixture.swift",
      "Extensions/fixtureSupport/UntrackedFixture.swift",
      "Packages/EdithHost/Sources/EdithHostCore/Resources/UntrackedFixture.json",
    ]) {
      const file = join(root, path);
      await mkdir(dirname(file), { recursive: true });
      await writeFile(file, "synthetic fixture");
      assert.throws(() => requireTracked(execute));
      const cleanStatus = (command, arguments_, options) =>
        arguments_[0] === "status" ? "" : execute(command, arguments_, options);
      assert.equal(dirty(cleanStatus), true);
      await rm(file);
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
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
