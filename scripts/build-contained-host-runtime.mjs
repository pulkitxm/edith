import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFile,
  cp,
  lstat,
  mkdir,
  readdir,
  readFile,
  rm,
} from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

const hash = async (file) =>
  createHash("sha256")
    .update(await readFile(file))
    .digest("hex");

export async function requireRegularTree(directory) {
  const info = await lstat(directory);
  if (info.isSymbolicLink() || (!info.isFile() && !info.isDirectory()))
    throw new Error("Contained packages require regular files and directories");
  if (info.isDirectory())
    for (const child of await readdir(directory))
      await requireRegularTree(join(directory, child));
}

function sign(path, identity, development, entitlements) {
  const options = development ? [] : ["--options", "runtime", "--timestamp"];
  execFileSync(
    "codesign",
    [
      "--force",
      "--sign",
      identity,
      ...options,
      ...(entitlements ? ["--entitlements", entitlements] : []),
      path,
    ],
    { stdio: "inherit" },
  );
}

async function signRuntimeTree(directory, identity, development) {
  for (const item of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, item.name);
    if (item.isDirectory()) await signRuntimeTree(path, identity, development);
    else if (
      execFileSync("file", ["-b", path], { encoding: "utf8" }).includes(
        "Mach-O",
      )
    )
      sign(path, identity, development);
  }
  if (["framework", "app", "xpc"].includes(directory.split(".").at(-1)))
    sign(directory, identity, development);
}

export async function copyContainedHostRuntime(
  hostApp,
  contents,
  { identity, development },
) {
  const source = resolve(hostApp, "Contents/MacOS/Edith");
  const destination = resolve(contents, "MacOS/Edith");
  await mkdir(dirname(destination), { recursive: true });
  const originalSHA256 = await hash(source);
  await copyFile(source, destination);
  if ((await hash(destination)) !== originalSHA256)
    throw new Error(
      "The contained executable differs from its host provenance",
    );
  const hostResources = resolve(
    hostApp,
    "Contents/Resources/EdithHost_EdithHost.bundle",
  );
  await requireRegularTree(hostResources);
  await mkdir(resolve(contents, "Resources"), { recursive: true });
  await cp(
    hostResources,
    resolve(contents, "Resources/EdithHost_EdithHost.bundle"),
    {
      recursive: true,
      dereference: false,
    },
  );
  const dependencies = execFileSync("otool", ["-L", source], {
    encoding: "utf8",
  })
    .split("\n")
    .slice(1)
    .map((line) => line.trim().split(" ")[0])
    .filter(Boolean);
  const frameworks = resolve(contents, "Frameworks");
  await mkdir(frameworks, { recursive: true });
  const copied = new Set();
  for (const dependency of dependencies) {
    if (dependency.startsWith("/System/") || dependency.startsWith("/usr/"))
      continue;
    if (!dependency.startsWith("@rpath/") || dependency.includes(".."))
      throw new Error(
        "The host executable has an unsupported runtime dependency",
      );
    const path = dependency.slice(7);
    const name = path.split("/")[0];
    if (!copied.has(name)) {
      copied.add(name);
      const origin = resolve(hostApp, "Contents/Frameworks", name);
      const target = resolve(frameworks, name);
      execFileSync("/bin/cp", ["-RL", origin, target]);
      if (name.endsWith(".framework")) {
        await rm(join(target, "Versions"), {
          recursive: true,
          force: true,
        });
        if (path.split("/").length !== 2)
          throw new Error(
            "The release host framework load paths must be normalized before signing",
          );
      }
      await signRuntimeTree(
        name.endsWith(".framework") ? target : frameworks,
        identity,
        development,
      );
    }
    await lstat(resolve(frameworks, path));
  }
  await requireRegularTree(frameworks);
  if ((await hash(destination)) !== originalSHA256)
    throw new Error("Runtime packaging modified the copied host executable");
  return {
    originalSHA256,
    runtimeDependencies: dependencies.filter((path) =>
      path.startsWith("@rpath/"),
    ),
  };
}
