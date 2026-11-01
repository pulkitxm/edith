import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, watch } from "node:fs";
import { readFile } from "node:fs/promises";
import { relative, resolve } from "node:path";
import { developmentVersion, launch } from "./dev-catalog.mjs";

const root = resolve(import.meta.dir, "..");
const app = resolve(root, "dist/Edith.app");
const ed = resolve(app, "Contents/MacOS/ed");

export function watchedPaths(root, definition) {
  const paths = new Set([
    resolve(root, "Extensions", definition.id),
    resolve(root, "Packages/ExtensionSupport/Sources"),
  ]);
  for (const sources of Object.values(definition.roles))
    for (const source of sources) {
      const top = source.split("/").slice(0, 2).join("/");
      if (top.startsWith("Extensions/") || top.startsWith("Packages/"))
        paths.add(resolve(root, top));
    }
  return [...paths].filter((path) => existsSync(path));
}

export function relevantChange(name) {
  if (!name) return false;
  const parts = name.split("/");
  if (
    parts.some((part) =>
      [".build", "build", "dist", "node_modules", "Tests"].includes(part),
    )
  )
    return false;
  return /\.(swift|json|plist|strings|png|svg|js|css|html|metal|c|h|m|rs)$/.test(
    name,
  );
}

function edithCLI(args, options = {}) {
  return spawnSync(ed, args, { encoding: "utf8", ...options });
}

function running() {
  return (
    spawnSync("pgrep", ["-f", `${app}/Contents/MacOS/Edith$`]).status === 0
  );
}

function passthroughEnvironment() {
  return Object.fromEntries(
    ["EDITH_DEV_CATALOG", "EDITH_DEV_CATALOG_KEY"]
      .filter((key) => process.env[key])
      .map((key) => [key, process.env[key]]),
  );
}

async function waitFor(id, version, seconds = 60) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    const reply = edithCLI(["extensions", "info", id, "--json"]);
    if (reply.status === 0) {
      const info = JSON.parse(reply.stdout);
      if (info.version === version && info.state === "active") return info;
      if (info.state === "failed") return info;
    }
    await Bun.sleep(250);
  }
  throw new Error(`${id} ${version} did not become active`);
}

export async function cycle(id, definition) {
  const started = performance.now();
  const version = developmentVersion(definition.version);
  execFileSync("bun", ["scripts/prepare-extension-native.mjs", id], {
    cwd: root,
    stdio: "inherit",
  });
  const build = spawnSync(
    "bun",
    ["scripts/build-extension-package.mjs", id, "--development"],
    {
      cwd: root,
      stdio: ["ignore", "ignore", "inherit"],
      env: { ...process.env, EXTENSION_VERSION: version },
    },
  );
  if (build.status !== 0) throw new Error(`Building ${id} failed`);
  const built = performance.now();
  if (!running()) {
    await launch(root, passthroughEnvironment());
    for (let attempt = 0; attempt < 120; attempt++) {
      if (edithCLI(["extensions", "ls", "--json"]).status === 0) break;
      await Bun.sleep(250);
    }
  }
  const sideload = edithCLI([
    "extensions",
    "sideload",
    resolve(root, "dist/extensions", `${id}.zip`),
    "--json",
  ]);
  if (sideload.status !== 0)
    throw new Error(sideload.stderr || sideload.stdout || "sideload failed");
  await launch(root, passthroughEnvironment());
  const info = await waitFor(id, version);
  const finished = performance.now();
  return {
    id,
    version,
    state: info.state,
    buildSeconds: Number(((built - started) / 1000).toFixed(1)),
    totalSeconds: Number(((finished - started) / 1000).toFixed(1)),
    timings: info.timings,
  };
}

if (import.meta.main) {
  const [id, ...flags] = process.argv.slice(2);
  if (!id) {
    process.stderr.write(
      "usage: bun scripts/dev-extension.mjs <id> [--watch]\n",
    );
    process.exit(2);
  }
  if (!existsSync(ed)) {
    process.stderr.write(
      "build the development app first: ./build.sh --no-open\n",
    );
    process.exit(1);
  }
  const manifest = JSON.parse(
    await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  const definition = manifest.find((entry) => entry.id === id);
  if (!definition) {
    process.stderr.write(`Unknown extension ${id}\n`);
    process.exit(2);
  }
  const report = async () => {
    try {
      process.stdout.write(`${JSON.stringify(await cycle(id, definition))}\n`);
    } catch (error) {
      process.stderr.write(`${error.message}\n`);
      if (!flags.includes("--watch")) process.exitCode = 1;
    }
  };
  await report();
  if (flags.includes("--watch")) {
    let timer;
    let busy = false;
    let pending = false;
    const trigger = () => {
      clearTimeout(timer);
      timer = setTimeout(async () => {
        if (busy) {
          pending = true;
          return;
        }
        busy = true;
        do {
          pending = false;
          await report();
        } while (pending);
        busy = false;
      }, 400);
    };
    for (const path of watchedPaths(root, definition)) {
      watch(path, { recursive: true }, (_, name) => {
        if (relevantChange(name)) {
          process.stdout.write(
            `changed ${relative(root, resolve(path, name))}\n`,
          );
          trigger();
        }
      });
    }
    process.stdout.write(`watching ${id}; press Ctrl-C to stop\n`);
  }
}
