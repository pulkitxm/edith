import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import vm from "node:vm";

const source = await readFile(
  new URL("./build-minimal-host.mjs", import.meta.url),
  "utf8",
);
function definition(name, prefix = "function") {
  const start = source.indexOf(`${prefix} ${name}(`);
  const end = source.indexOf("\n}\n", start);
  expect(start).toBeGreaterThanOrEqual(0);
  expect(end).toBeGreaterThan(start);
  return source.slice(start, end + 2);
}

const removeSignature = vm.runInNewContext(
  `${definition("removeCopiedCodeSignature")}\nremoveCopiedCodeSignature`,
);

test("copied signed code loses only its signature before transformation", () => {
  const calls = [];
  removeSignature("/synthetic/copied/Sparkle", (command, args, options) => {
    calls.push([command, Array.from(args), options]);
    return "Load command 12\n      cmd LC_CODE_SIGNATURE\n  cmdsize 16\n";
  });
  expect(calls).toEqual([
    ["otool", ["-l", "/synthetic/copied/Sparkle"], { encoding: "utf8" }],
    ["codesign", ["--remove-signature", "/synthetic/copied/Sparkle"], undefined],
  ]);
});

test("unsigned copied code skips signature removal", () => {
  for (const commands of [
    "Load command 0\n      cmd LC_SEGMENT_64\n",
    "path /synthetic/LC_CODE_SIGNATURE\n",
  ]) {
    const calls = [];
    removeSignature("/synthetic/copied/tool", (command) => {
      calls.push(command);
      return commands;
    });
    expect(calls).toEqual(["otool"]);
  }
});

test("inspection and signature removal failures propagate", () => {
  for (const failingCommand of ["otool", "codesign"]) {
    const failure = new Error(`synthetic ${failingCommand} failure`);
    expect(() =>
      removeSignature("/synthetic/copied/tool", (command) => {
        if (command === failingCommand) throw failure;
        return "cmd LC_CODE_SIGNATURE\n";
      }),
    ).toThrow(failure);
  }
});

test("actual copied framework preparation removes signatures before thinning and relinking", async () => {
  const calls = [];
  const execute = (command, args) => {
    calls.push([command, Array.from(args)]);
    if (command === "file") return "Mach-O universal binary";
    if (command === "otool" && args[0] === "-l")
      return "cmd LC_CODE_SIGNATURE\n";
    if (command === "otool")
      return "Sparkle:\n /synthetic/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.0.0)\n";
    return "";
  };
  const prepare = vm.runInNewContext(
    `${definition("removeCopiedCodeSignature")}\n${definition("prepareFramework", "async function")}\nprepareFramework`,
    {
      execFileSync: execute,
      join,
      readdir: async () => [
        { name: "Sparkle", isDirectory: () => false, isFile: () => true },
      ],
    },
  );
  await prepare("/synthetic/copied/Sparkle.framework");
  expect(calls.map(([command]) => command)).toEqual([
    "file",
    "otool",
    "codesign",
    "lipo",
    "mv",
    "otool",
    "install_name_tool",
    "install_name_tool",
    "codesign",
    "codesign",
  ]);
  expect(calls[2][1]).toEqual([
    "--remove-signature",
    "/synthetic/copied/Sparkle.framework/Sparkle",
  ]);
  expect(calls.at(-1)).toEqual([
    "codesign",
    ["--force", "--sign", "-", "/synthetic/copied/Sparkle.framework"],
  ]);
});

test("host executable signature removal precedes its first load-command mutation", () => {
  const removal = source.indexOf("removeCopiedCodeSignature(executable);");
  const linking = source.indexOf('const linked = execFileSync("otool"');
  const transformation = source.indexOf(
    'execFileSync("install_name_tool"',
    linking,
  );
  expect(removal).toBeGreaterThan(source.indexOf("await copyFile(join(products"));
  expect(removal).toBeLessThan(linking);
  expect(linking).toBeLessThan(transformation);
  expect(source).toContain('["--verify", "--deep", "--strict", destination]');
});
