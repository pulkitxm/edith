import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { releaseExtensionsLocally } from "./release-extensions-local.mjs";

function fixture({ ids = ["docs", "virtualCamera"], draft = false } = {}) {
  const root = mkdtempSync(join(tmpdir(), "extension-local-release-"));
  mkdirSync(join(root, "Extensions"));
  writeFileSync(
    join(root, "Extensions/manifest.json"),
    JSON.stringify(ids.map((id) => ({ id }))),
  );
  const target = "a".repeat(40);
  const state = {
    head: target,
    remote: target,
    dirty: "",
    fail: undefined,
    afterBuild: undefined,
    afterNotary: undefined,
  };
  const include = ids.map((id) => ({
    id,
    version: "1.0.1",
    tag: `extensions/${id}/1.0.1-${"b".repeat(20)}`,
  }));
  const environment = {
    BUILT_SHA: target,
    GITHUB_SHA: "c".repeat(40),
    GITHUB_REF: "refs/heads/stale",
    EDITH_SIGN_IDENTITY: "Developer ID Application: Synthetic Publisher",
    EXTENSION_CATALOG_PRIVATE_KEY: "synthetic",
    NOTARY_KEY_ID: "synthetic",
    NOTARY_ISSUER_ID: "synthetic",
    NOTARY_KEY: "synthetic",
    EXTENSION_FORCE_ALL: "true",
  };
  const calls = [];
  const execute = (file, args, options) => {
    calls.push({ file, args, environment: options.env });
    const command = [file, ...args].join(" ");
    if (state.fail?.(file, args)) throw new Error("synthetic command failure");
    if (file === "git") {
      if (args[0] === "rev-parse") return `${state.head}\n`;
      if (args[0] === "ls-remote") return `${state.remote}\trefs/heads/main\n`;
      if (args[0] === "status") return state.dirty;
    }
    if (file === "bun" && args[1] === "--read-catalog") {
      writeFileSync(
        args[2],
        JSON.stringify({ schemaVersion: 1, revision: 7, packages: [] }),
      );
      writeFileSync(
        join(root, "dist/extensions-local/previous-state.json"),
        JSON.stringify({ draft }),
      );
      return "Verified catalog revision: 7\n";
    }
    if (file === "bun" && args[0] === "scripts/extension-release-plan.mjs")
      return JSON.stringify({ include });
    if (file === "bun" && args[0] === "scripts/build-extension-package.mjs") {
      state.afterBuild?.();
      return `built\n${JSON.stringify(include.find(({ id }) => id === args[1]))}\n`;
    }
    if (file === "python3" && args[0] === "scripts/notary_wait.py")
      state.afterNotary?.();
    if (["make", "python3", "bash", "swift"].includes(file)) return "";
    if (
      file === "bun" &&
      [
        "scripts/extension-publish.mjs",
        "scripts/extension-ghostty-native.mjs",
      ].includes(args[0])
    )
      return "";
    throw new Error(`Unexpected command: ${command}`);
  };
  const run = () =>
    releaseExtensionsLocally({ root, environment, execute, log: () => {} });
  return {
    root,
    state,
    calls,
    environment,
    include,
    run,
    clean: () => rmSync(root, { recursive: true, force: true }),
  };
}

test("local releases build planned versions, notarize together and use the guarded publisher", async () => {
  const f = fixture();
  try {
    expect(await f.run()).toEqual({ built: 2, resumed: false });
    const builds = f.calls.filter(
      ({ args }) => args[0] === "scripts/build-extension-package.mjs",
    );
    expect(builds.map(({ args }) => args[1])).toEqual([
      "docs",
      "virtualCamera",
    ]);
    for (const build of builds) {
      expect(build.environment.EXTENSION_VERSION).toBe("1.0.1");
      expect(build.environment.GITHUB_SHA).toBe("a".repeat(40));
      expect(build.environment.GITHUB_REF).toBe("refs/heads/main");
      expect(build.environment.EXTENSION_FORCE_ALL).toBe("true");
      expect(build.environment.EXTENSION_OUTPUT).toBe(
        join(f.root, "dist/extensions-local"),
      );
    }
    const submission = f.calls.find(
      ({ args }) => args[0] === "scripts/notary-submit.sh",
    );
    expect(submission.args.slice(2)).toEqual(
      ["docs", "virtualCamera"].map((id) =>
        join(f.root, `dist/extensions-local/${id}.zip`),
      ),
    );
    const wait = f.calls.findIndex(
      ({ args }) => args[0] === "scripts/notary_wait.py",
    );
    const publish = f.calls.findIndex(
      ({ args }) =>
        args.length === 1 && args[0] === "scripts/extension-publish.mjs",
    );
    expect(wait).toBeGreaterThan(f.calls.indexOf(submission));
    expect(publish).toBeGreaterThan(wait);
    expect(f.calls.some(({ file }) => ["gh", "pukbot"].includes(file))).toBe(
      false,
    );
  } finally {
    f.clean();
  }
});

test("a changed main is rejected before planning or building", async () => {
  const f = fixture();
  try {
    f.state.remote = "b".repeat(40);
    await expect(f.run()).rejects.toThrow("main changed");
    expect(f.calls.every(({ file }) => file === "git")).toBe(true);
  } finally {
    f.clean();
  }
});

test("a dirty source and missing credentials fail before any build", async () => {
  const f = fixture();
  try {
    f.state.dirty = " M tracked.swift\n";
    await expect(f.run()).rejects.toThrow("clean frozen source");
    f.calls.length = 0;
    delete f.environment.NOTARY_KEY;
    await expect(f.run()).rejects.toThrow("NOTARY_KEY is required");
    expect(f.calls).toHaveLength(0);
  } finally {
    f.clean();
  }
});

test("build failure and source changes during build never notarize or publish", async () => {
  for (const dirty of [false, true]) {
    const f = fixture();
    try {
      if (dirty)
        f.state.afterBuild = () => {
          f.state.dirty = " M changed.swift\n";
        };
      else
        f.state.fail = (_file, args) =>
          args[0] === "scripts/build-extension-package.mjs";
      await expect(f.run()).rejects.toThrow();
      expect(
        f.calls.some(({ args }) => args[0] === "scripts/notary-submit.sh"),
      ).toBe(false);
      expect(
        f.calls.some(
          ({ args }) =>
            args.length === 1 && args[0] === "scripts/extension-publish.mjs",
        ),
      ).toBe(false);
    } finally {
      f.clean();
    }
  }
});

test("notary failure or a changed main after notarization blocks publication", async () => {
  for (const moved of [false, true]) {
    const f = fixture();
    try {
      if (moved)
        f.state.afterNotary = () => {
          f.state.remote = "b".repeat(40);
        };
      else f.state.fail = (_file, args) => args[0] === "scripts/notary_wait.py";
      await expect(f.run()).rejects.toThrow();
      expect(
        f.calls.some(
          ({ args }) =>
            args.length === 1 && args[0] === "scripts/extension-publish.mjs",
        ),
      ).toBe(false);
    } finally {
      f.clean();
    }
  }
});

test("an unchanged public catalog skips builds while an owned draft resumes through the publisher", async () => {
  for (const draft of [false, true]) {
    const f = fixture({ ids: [], draft });
    try {
      expect(await f.run()).toEqual({ built: 0, resumed: draft });
      expect(f.calls.some(({ file }) => file === "make")).toBe(false);
      expect(
        f.calls.some(({ args }) => args[0] === "scripts/notary-submit.sh"),
      ).toBe(false);
      expect(
        f.calls.filter(
          ({ args }) =>
            args.length === 1 && args[0] === "scripts/extension-publish.mjs",
        ),
      ).toHaveLength(draft ? 1 : 0);
    } finally {
      f.clean();
    }
  }
});

test("terminal packages prepare their native dependency before packaging", async () => {
  const f = fixture({ ids: ["terminal"] });
  try {
    writeFileSync(
      join(f.root, "Extensions/manifest.json"),
      JSON.stringify([{ id: "terminal", nativeProduct: "GhosttyTerminal" }]),
    );
    await f.run();
    const native = f.calls.findIndex(
      ({ args }) => args[0] === "ghostty-extension",
    );
    const build = f.calls.findIndex(
      ({ args }) => args[0] === "scripts/build-extension-package.mjs",
    );
    expect(native).toBeGreaterThan(-1);
    expect(native).toBeLessThan(build);
  } finally {
    f.clean();
  }
});
