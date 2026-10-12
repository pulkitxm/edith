import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { compileSparkleImplementation } from "./hosted-sparkle-update/build-host.mjs";
import {
  historicalSparkleSource,
  readSparkleImplementation,
  sparkleChildEnvironment,
  sparkleExecutableIdentity,
  sparkleImplementationPaths,
  validateSparkleImplementations,
  verifySparkleImplementationCopy,
} from "./hosted-sparkle-update/implementations.mjs";

const sourceCommit = "a".repeat(40);
const gitBlob = (bytes) =>
  createHash("sha1")
    .update(`blob ${bytes.length}\0`)
    .update(bytes)
    .digest("hex");
function sourceReader(change = (bytes) => bytes) {
  return (command, args) => {
    expect(command).toBe("git");
    const [commit, path] = args[1].split(":");
    expect(commit).toBe(sourceCommit);
    const historical = path.startsWith(
      "Tests/HostedSparkleUpdate/ImplementationSources/",
    );
    const name = path.split("/").at(-1);
    expect(
      Object.keys(sparkleImplementationPaths).some((value) =>
        value.endsWith(`/${name}`),
      ),
    ).toBe(true);
    const original = readFileSync(
      `Tests/HostedSparkleUpdate/ImplementationSources/${name}`,
    );
    const bytes = change(
      historical
        ? original
        : Buffer.concat([
            original,
            Buffer.from("\nstruct DifferentHostImplementation {}\n"),
          ]),
      historical,
    );
    if (args[0] === "show") return bytes;
    expect(args[0]).toBe("rev-parse");
    return gitBlob(bytes);
  };
}
function implementations() {
  const previous = readSparkleImplementation(
    "previous",
    sourceCommit,
    sourceReader(),
  );
  const current = readSparkleImplementation(
    "current",
    sourceCommit,
    sourceReader(),
  );
  return {
    composition: "current-base-with-historical-onboarding",
    baseSourceCommit: sourceCommit,
    previous: {
      sourceCommit: previous.sourceCommit,
      sources: previous.metadata,
      normalizedUnsignedSHA256: "1".repeat(64),
    },
    current: {
      sourceCommit: current.sourceCommit,
      sources: current.metadata,
      normalizedUnsignedSHA256: "2".repeat(64),
    },
  };
}

test("historical inputs are actual pinned reviewed blobs and current inputs use only the two allowed source paths", () => {
  const previous = readSparkleImplementation(
    "previous",
    sourceCommit,
    sourceReader(),
  );
  expect(previous.sourceCommit).toBe(historicalSparkleSource);
  expect(previous.baseSourceCommit).toBe(sourceCommit);
  expect(Object.keys(previous.sources)).toEqual(
    Object.keys(sparkleImplementationPaths),
  );
  for (const [path, pinned] of Object.entries(sparkleImplementationPaths)) {
    expect(previous.metadata[path].blob).toBe(pinned);
    expect(gitBlob(previous.sources[path])).toBe(pinned);
  }
  expect(
    validateSparkleImplementations(implementations(), sourceCommit),
  ).toEqual(implementations());
});

test("edited historical sources wrong Git identities empty and excessive inputs fail before compilation", () => {
  for (const changed of [
    Buffer.alloc(0),
    Buffer.from("synthetic changed historical implementation"),
    Buffer.alloc(1048577),
  ]) {
    expect(() =>
      readSparkleImplementation(
        "previous",
        sourceCommit,
        sourceReader(() => changed),
      ),
    ).toThrow();
  }
  const reader = sourceReader();
  expect(() =>
    readSparkleImplementation("previous", sourceCommit, (command, args) =>
      args[0] === "rev-parse" ? "f".repeat(40) : reader(command, args),
    ),
  ).toThrow();
  expect(() =>
    readSparkleImplementation(
      "current",
      sourceCommit,
      sourceReader((bytes, historical) =>
        historical
          ? bytes
          : readFileSync(
              `Tests/HostedSparkleUpdate/ImplementationSources/HostWorkflowOnboardingModel.swift`,
            ),
      ),
    ),
  ).toThrow();
  expect(() =>
    readSparkleImplementation("foreign", sourceCommit, reader),
  ).toThrow();
  expect(() =>
    readSparkleImplementation("previous", historicalSparkleSource, reader),
  ).toThrow();
});

test("a new signature metadata source claim or process birth cannot turn equal implementation code into cross-host proof", () => {
  const value = implementations();
  const edits = [
    (row) => {
      row.current.normalizedUnsignedSHA256 =
        row.previous.normalizedUnsignedSHA256;
    },
    (row) => {
      row.current.sourceCommit = historicalSparkleSource;
    },
    (row) => {
      row.baseSourceCommit = "b".repeat(40);
    },
    (row) => {
      row.current.sources.foreign = {
        blob: "b".repeat(40),
        sha256: "c".repeat(64),
      };
    },
    (row) => {
      delete row.previous.sources[Object.keys(sparkleImplementationPaths)[0]];
    },
    (row) => {
      row.previous.sources[Object.keys(sparkleImplementationPaths)[0]].blob =
        "b".repeat(40);
    },
    (row) => {
      row.current.sources[Object.keys(sparkleImplementationPaths)[0]].sha256 =
        row.previous.sources[Object.keys(sparkleImplementationPaths)[0]].sha256;
    },
    (row) => {
      row.current.normalizedUnsignedSHA256 += "\n";
    },
  ];
  for (const edit of edits) {
    const changed = structuredClone(value);
    edit(changed);
    expect(() =>
      validateSparkleImplementations(changed, sourceCommit),
    ).toThrow();
  }
});

test("normalization uses the existing signed Mach-O verifier and rejects missing or unknown code identity", () => {
  const identity = {
    signedSHA256: "1".repeat(64),
    normalizedUnsignedSHA256: "2".repeat(64),
    normalization:
      "arm64-terminal-linkedit-vmsize-after-verified-signature-removal-v1",
  };
  expect(
    sparkleExecutableIdentity(
      "/fixture/source",
      "/fixture/Host.app",
      { HOME: "/fixture/home", PATH: "/usr/bin:/bin" },
      (command, args, options) => {
        expect(command).toBe("python3");
        expect(args.slice(-2)).toEqual([
          "/fixture/source/scripts",
          "/fixture/Host.app/Contents/MacOS/Edith",
        ]);
        expect(args[3]).toContain(
          "macho_code_identity import executable_identity",
        );
        expect(options.timeout).toBe(40000);
        expect(args.slice(0, 3)).toEqual(["-I", "-B", "-c"]);
        expect(options.env).toEqual({
          HOME: "/fixture/home",
          PATH: "/usr/bin:/bin",
        });
        return JSON.stringify(identity);
      },
    ),
  ).toEqual(identity);
  for (const changed of [
    {},
    { ...identity, normalizedUnsignedSHA256: "" },
    { ...identity, normalization: "signature-only" },
  ]) {
    expect(() =>
      sparkleExecutableIdentity(
        "/fixture/source",
        "/fixture/Host.app",
        { HOME: "/fixture/home" },
        () => JSON.stringify(changed),
      ),
    ).toThrow();
  }
});

test("implementation copies are checked before and after compilation and changed HEAD or dirty inputs reject", async () => {
  const directory = await mkdtemp(join(tmpdir(), "sparkle-copy-"));
  try {
    const implementation = readSparkleImplementation(
      "previous",
      sourceCommit,
      sourceReader(),
    );
    const first = Object.keys(implementation.sources)[0];
    const copied = join(directory, first.slice("Packages/EdithHost/".length));
    const restore = async () => {
      for (const [path, bytes] of Object.entries(implementation.sources)) {
        const target = join(
          directory,
          path.slice("Packages/EdithHost/".length),
        );
        await mkdir(join(target, ".."), { recursive: true, mode: 0o700 });
        await rm(target, { force: true });
        await writeFile(target, bytes, { mode: 0o600 });
      }
    };
    const run = async (mutation, initial = false) => {
      await restore();
      let built = false;
      const calls = [];
      let head = sourceCommit;
      let dirty = "";
      if (initial) await writeFile(copied, "wrong copy");
      const pending = compileSparkleImplementation({
        packageDirectory: directory,
        implementation,
        sourceCommit,
        builderPath: "/fixture/builder.mjs",
        environment: {
          HOME: directory,
          PATH: "/usr/bin:/bin",
          GITHUB_TOKEN: "synthetic-private",
          EDITH_EXTENSION_ID: "foreign",
        },
        execute(command, args, options) {
          calls.push(command);
          expect(options.env.GITHUB_TOKEN).toBeUndefined();
          expect(options.env.EDITH_EXTENSION_ID).toBeUndefined();
          if (command === "git") return args[0] === "status" ? dirty : head;
          expect(command).toBe(process.execPath);
          expect(options.env.EXTENSION_SWIFT_JOBS).toBe("1");
          built = true;
          if (mutation === "copy")
            writeFileSync(copied, "changed during child");
          if (mutation === "head") head = "b".repeat(40);
          if (mutation === "dirty") dirty = " M synthetic.swift";
        },
      });
      if (mutation || initial) await expect(pending).rejects.toThrow();
      else await pending;
      expect(built).toBe(!initial);
      return calls;
    };
    expect(await run()).toEqual(["git", "git", process.execPath, "git", "git"]);
    await run("copy");
    await run("head");
    await run("dirty");
    await run(undefined, true);
    await restore();
    await rm(copied);
    const outside = join(directory, "outside.swift");
    await writeFile(outside, implementation.sources[first], { mode: 0o600 });
    await symlink(outside, copied);
    await expect(
      verifySparkleImplementationCopy(directory, implementation),
    ).rejects.toThrow();
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("explicit child environments strip secrets and reject interpreter path or startup authority", () => {
  const environment = {
    HOME: "/fixture/home",
    PATH: "/usr/bin:/bin",
    LANG: "en_US.UTF-8",
    GITHUB_TOKEN: "synthetic",
    SSH_AUTH_SOCK: "/foreign",
    EDITH_EXTENSION_ID: "foreign",
  };
  expect(sparkleChildEnvironment(environment)).toEqual({
    HOME: environment.HOME,
    PATH: environment.PATH,
    LANG: environment.LANG,
  });
  for (const key of ["PYTHONPATH", "PYTHONHOME", "NODE_OPTIONS", "NODE_PATH"])
    expect(() =>
      sparkleChildEnvironment({ ...environment, [key]: "synthetic-authority" }),
    ).toThrow();
  expect(() =>
    sparkleChildEnvironment({ ...environment, CFFIXED_USER_HOME: "/foreign" }),
  ).toThrow();
});

test("build compilation forwards the original executor so its admitted one-job environment cannot be overwritten", () => {
  const source = readFileSync(
    "scripts/hosted-sparkle-update/build-host.mjs",
    "utf8",
  );
  const build = source.slice(
    source.indexOf("export async function buildSparkleHost("),
  );
  const call = build.slice(
    build.indexOf("await compileSparkleImplementation({"),
    build.indexOf("const receipt ="),
  );
  expect(call).toMatch(/execute:\s*childExecute/);
  expect(call).not.toMatch(/\n\s*execute,/);
});
