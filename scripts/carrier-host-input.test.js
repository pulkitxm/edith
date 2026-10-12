import { afterEach, expect, test } from "bun:test";
import {
  chmod,
  link,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readlink,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import vm from "node:vm";
import { requireRegularTree } from "./build-contained-host-runtime.mjs";
import { verifyExtensionUIHost } from "./build-extension-ui-carrier.mjs";

const roots = [];
afterEach(async () => {
  for (const root of roots.splice(0))
    await rm(root, { recursive: true, force: true });
});

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "carrier-host-input-"));
  roots.push(root);
  const host = join(await realpath(root), "Edith.app");
  const executable = join(host, "Contents/MacOS/Edith");
  const launcher = join(host, "Contents/MacOS/ed");
  const target = join(host, "Contents/Resources/ed-launcher");
  const resources = join(host, "Contents/Resources/EdithHost_EdithHost.bundle");
  await mkdir(join(host, "Contents/MacOS"), { recursive: true });
  await mkdir(resources, { recursive: true });
  await writeFile(executable, "synthetic executable", { mode: 0o755 });
  await writeFile(target, "synthetic launcher", { mode: 0o755 });
  await writeFile(join(resources, "index.json"), "synthetic index");
  return { root, host, executable, launcher, target, resources };
}

test("only the signed host launcher link is admitted before exact signature verification", async () => {
  const value = await fixture();
  await symlink("../Resources/ed-launcher", value.launcher);
  const calls = [];
  await verifyExtensionUIHost(value.host, (args) => calls.push(args));
  expect(calls).toEqual([["--verify", "--deep", "--strict", value.host]]);
  expect(await readlink(value.launcher)).toBe("../Resources/ed-launcher");
  expect(await readFile(value.executable, "utf8")).toBe("synthetic executable");
  expect(await readFile(value.target, "utf8")).toBe("synthetic launcher");
  expect((await lstat(value.target)).mode & 0o777).toBe(0o755);
  await expect(requireRegularTree(value.host)).rejects.toThrow("regular files");
});

test("original regular synthetic hosts still require the exact deep strict signature check", async () => {
  const value = await fixture();
  const calls = [];
  await verifyExtensionUIHost(value.host, (args) => calls.push(args));
  expect(calls).toEqual([["--verify", "--deep", "--strict", value.host]]);
});

test("foreign escaping nested dangling and hardlinked targets reject before signature checking", async () => {
  for (const kind of [
    "foreign",
    "absolute",
    "unknown",
    "directory",
    "nested",
    "missing",
    "hardlink",
    "root-link",
  ]) {
    const value = await fixture();
    let host = value.host;
    if (kind === "foreign")
      await symlink("../Resources/index.json", value.launcher);
    else if (kind === "absolute") await symlink(value.target, value.launcher);
    else if (kind === "unknown")
      await symlink(
        "../Resources/ed-launcher",
        join(value.host, "Contents/MacOS/foreign"),
      );
    else if (kind === "root-link") {
      host = join(value.root, "alias.app");
      await symlink(value.host, host);
    } else {
      await rm(value.target);
      if (kind === "directory") await mkdir(value.target);
      if (kind === "nested")
        await symlink("EdithHost_EdithHost.bundle/index.json", value.target);
      if (kind === "hardlink") {
        const foreign = join(value.root, "foreign");
        await writeFile(foreign, "preserved source");
        await link(foreign, value.target);
      }
      await symlink("../Resources/ed-launcher", value.launcher);
    }
    const calls = [];
    await expect(
      verifyExtensionUIHost(host, (args) => calls.push(args)),
    ).rejects.toThrow();
    expect(calls).toEqual([]);
    expect(await readFile(value.executable, "utf8")).toBe(
      "synthetic executable",
    );
  }
});

test("signature failure is propagated without changing the signed input", async () => {
  const value = await fixture();
  await symlink("../Resources/ed-launcher", value.launcher);
  await expect(
    verifyExtensionUIHost(value.host, () => {
      throw new Error("synthetic signature rejection");
    }),
  ).rejects.toThrow("synthetic signature rejection");
  expect(await readlink(value.launcher)).toBe("../Resources/ed-launcher");
  expect(await readFile(value.target, "utf8")).toBe("synthetic launcher");
});

test("actual contained runtime copy preserves executable bytes and mode without copying the launcher", async () => {
  const value = await fixture();
  await chmod(value.executable, 0o751);
  await symlink("../Resources/ed-launcher", value.launcher);
  await verifyExtensionUIHost(value.host, () => {});
  const source = await readFile(
    join(import.meta.dir, "build-contained-host-runtime.mjs"),
    "utf8",
  );
  const context = vm.createContext({ Buffer });
  const module = new vm.SourceTextModule(source, { context });
  const calls = [];
  await module.link(async (specifier) => {
    expect([
      "node:child_process",
      "node:crypto",
      "node:fs/promises",
      "node:path",
    ]).toContain(specifier);
    const namespace =
      specifier === "node:child_process"
        ? {
            execFileSync(file, args) {
              expect(file).toBe("otool");
              expect(args).toEqual(["-L", value.executable]);
              calls.push([file, args]);
              return `${value.executable}:\n /usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n`;
            },
          }
        : await import(specifier);
    const names = Object.keys(namespace);
    return new vm.SyntheticModule(
      names,
      function () {
        for (const name of names) this.setExport(name, namespace[name]);
      },
      { context },
    );
  });
  await module.evaluate();
  const output = join(value.root, "carrier/Contents");
  const receipt = await module.namespace.copyContainedHostRuntime(
    value.host,
    output,
    {
      identity: "synthetic identity",
      development: false,
    },
  );
  expect(calls.length).toBe(1);
  expect(receipt.runtimeDependencies).toEqual([]);
  expect(await readFile(join(output, "MacOS/Edith"), "utf8")).toBe(
    "synthetic executable",
  );
  expect((await lstat(join(output, "MacOS/Edith"))).mode & 0o777).toBe(0o751);
  expect(
    await readFile(
      join(output, "Resources/EdithHost_EdithHost.bundle/index.json"),
      "utf8",
    ),
  ).toBe("synthetic index");
  await expect(lstat(join(output, "MacOS/ed"))).rejects.toThrow();
  await requireRegularTree(output);
  expect(await readlink(value.launcher)).toBe("../Resources/ed-launcher");
});
