import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

function recipe(target) {
  return execFileSync("make", ["-n", "EDITH_MAKE_GATE=1", target], {
    encoding: "utf8",
  });
}

test.each([
  ["ci-extension-system-stats", "Extensions/systemStats"],
  ["ci-extension-docs-native", "Extensions/docs"],
  ["ci-extension-usage-accounts", "Extensions/usage"],
  ["ci-extension-support", "Packages/ExtensionSupport"],
])(
  "ordinary parser preparation precedes the real compiler in %s",
  (target, path) => {
    const commands = recipe(target);
    const prepare = commands.indexOf(
      `python3 -I -B scripts/prepare-argument-parser.py ${path}`,
    );
    const compile = commands.indexOf(`swift test --package-path ${path}`);
    expect(prepare).toBeGreaterThanOrEqual(0);
    expect(compile).toBeGreaterThan(prepare);
  },
);

test.each([
  ["ci-extension-time-lapse", "swift test --package-path"],
  ["ci-extension-blitztree", "swift test --package-path"],
  [
    "ci-extension-keep-awake",
    "python3 -B scripts/run-host-swift-testing.py package-test --package-path Extensions/keepAwake",
  ],
  ["ci-extension-attention", "swift test --package-path"],
])(
  "%s retains its existing nonparser or generated support route",
  (target, compiler) => {
    const commands = recipe(target);
    expect(commands).not.toContain("scripts/prepare-argument-parser.py");
    expect(commands).toContain(compiler);
    if (target === "ci-extension-keep-awake")
      expect(commands).not.toContain("/usr/bin/time -p swift test");
    if (target === "ci-extension-attention")
      expect(commands).toContain(
        "scripts/prepare-extension-native-support.mjs attention",
      );
  },
);

function testArguments(argumentsList) {
  const source = readFileSync("Packages/Edith/test.sh", "utf8");
  const start = source.indexOf("parser_scratch=()");
  const end = source.indexOf('DEV="$(xcode-select -p)"', start);
  expect(start).toBeGreaterThanOrEqual(0);
  expect(end).toBeGreaterThan(start);
  const block = source.slice(start, end);
  return execFileSync(
    "bash",
    [
      "-c",
      'set -eu; fail_isolation() { exit 2; }; python3() { printf "[%s]\\n" "$@"; }; ' +
        block,
      "argument-forwarding",
      ...argumentsList,
    ],
    { encoding: "utf8" },
  );
}

test.each([
  ["ci-extension-usage-native", "usage", "swift test --package-path ."],
  ["ci-extension-studio", "studio", "bun test.mjs"],
])(
  "%s prepares the nested owner before its unchanged compiler driver",
  (target, owner, compiler) => {
    const commands = recipe(target);
    const prepare = commands.indexOf(
      `python3 -I -B ../../scripts/prepare-argument-parser.py "${resolve("Extensions", owner)}"`,
    );
    expect(prepare).toBeGreaterThanOrEqual(0);
    expect(commands.indexOf(compiler)).toBeGreaterThan(prepare);
    if (owner === "studio") {
      const source = readFileSync("Extensions/studio/test.mjs", "utf8");
      expect(source).toContain(
        'execFileSync("swift", ["test", "list", ...shared]',
      );
      expect(source).toContain(
        'spawnSync("swift", ["test", ...shared, "--skip-build", "--no-parallel", "--filter", pattern]',
      );
      expect(source).toContain("timeout: 300_000");
    }
  },
);

test("database prepares the owner root before its isolated suite driver", () => {
  const commands = recipe("ci-extension-database");
  const prepare = commands.indexOf(
    "python3 -I -B scripts/prepare-argument-parser.py Extensions/database",
  );
  expect(prepare).toBeGreaterThanOrEqual(0);
  expect(commands.indexOf("node test.mjs")).toBeGreaterThan(prepare);
  expect(
    commands.indexOf(
      "swift test --package-path Extensions/database/DatabaseEngine",
    ),
  ).toBeLessThan(prepare);
});

test("preparation pure tests are defined only inside the existing resource gate body", () => {
  const source = readFileSync("Makefile", "utf8");
  expect(source.indexOf("ci-argument-parser-source:\n")).toBeLessThan(
    source.lastIndexOf("\nendif\n"),
  );
  expect(source.match(/^ci-argument-parser-source:/gm)).toHaveLength(1);
});

test("direct test entry forwards the actual scratch option without consuming compiler arguments", () => {
  expect(
    testArguments(["--filter", "SyntheticSuite", "--jobs", "1"]),
  ).not.toContain("scratch-path");
  for (const argumentsList of [
    ["--scratch-path", "local/parser-tests", "--filter", "SyntheticSuite"],
    [
      "--filter",
      "SyntheticSuite",
      "--scratch-path=local/parser-tests",
      "--jobs",
      "1",
    ],
  ]) {
    const output = testArguments(argumentsList);
    expect(output).toContain("[--scratch-path]\n[local/parser-tests]");
    expect(output).toContain("[../../scripts/prepare-argument-parser.py]");
  }
  expect(() => testArguments(["--scratch-path"])).toThrow();
});
