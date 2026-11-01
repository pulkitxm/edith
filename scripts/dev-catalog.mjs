import { execFileSync, spawnSync } from "node:child_process";
import {
  createHash,
  createPrivateKey,
  generateKeyPairSync,
  sign,
} from "node:crypto";
import { existsSync } from "node:fs";
import {
  copyFile,
  mkdir,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { resolve } from "node:path";

export const defaultPort = 47321;
const repository = "pulkitxm/edith";
const productionCatalog = `https://github.com/${repository}/releases/download/extension-catalog-v1/catalog.json`;

export function catalogRoot(root) {
  return resolve(root, "local/dev-catalog");
}

function base64(base64url) {
  return Buffer.from(base64url, "base64url").toString("base64");
}

export async function signingKey(root) {
  const path = resolve(catalogRoot(root), "key.json");
  if (!existsSync(path)) {
    const { privateKey } = generateKeyPairSync("ed25519");
    await mkdir(catalogRoot(root), { recursive: true });
    await writeFile(
      path,
      JSON.stringify(privateKey.export({ format: "jwk" })),
      {
        mode: 0o600,
      },
    );
  }
  const jwk = JSON.parse(await readFile(path, "utf8"));
  return {
    privateKey: createPrivateKey({ key: jwk, format: "jwk" }),
    publicKey: base64(jwk.x),
  };
}

export function signCatalog(catalog, privateKey) {
  const payload = Buffer.from(JSON.stringify(catalog));
  return {
    payload: payload.toString("base64"),
    signature: sign(null, payload, privateKey).toString("base64"),
  };
}

export function developmentVersion(version, now = Date.now()) {
  const [major, minor] = version.split(".");
  return `${major}.${minor}.${Math.floor(now / 1000)}`;
}

export function releaseTag(id, version) {
  return `dev-${id}-${version}`;
}

export function localRecord(record, { tag, hostABI } = {}) {
  const { sourceFingerprint: _, ...rest } = record;
  const file = new URL(record.downloadURL).pathname.split("/").at(-1);
  return {
    ...rest,
    hostABI: hostABI ?? record.hostABI,
    downloadURL: `https://github.com/${repository}/releases/download/${tag}/${file}`,
  };
}

export function catalogPayload(records, production, revision) {
  const local = new Set(records.map((record) => record.id));
  const packages = [
    ...production.filter((record) => !local.has(record.id)),
    ...records,
  ];
  return { schemaVersion: 1, revision, packages };
}

async function records(root) {
  const directory = resolve(catalogRoot(root), "records");
  if (!existsSync(directory)) return [];
  const names = (await readdir(directory)).filter((name) =>
    name.endsWith(".json"),
  );
  return Promise.all(
    names
      .sort()
      .map(async (name) =>
        JSON.parse(await readFile(resolve(directory, name), "utf8")),
      ),
  );
}

async function production() {
  const response = await fetch(productionCatalog, {
    headers: { "User-Agent": "Edith development catalog" },
  });
  if (!response.ok)
    throw new Error(`Production catalog returned ${response.status}`);
  const envelope = await response.json();
  return JSON.parse(Buffer.from(envelope.payload, "base64")).packages;
}

export async function addExtension(
  root,
  id,
  { version, hostABI, environment = process.env } = {},
) {
  const manifest = JSON.parse(
    await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  const definition = manifest.find((entry) => entry.id === id);
  if (!definition) throw new Error(`Unknown extension ${id}`);
  const selected = version ?? developmentVersion(definition.version);
  const tag = releaseTag(id, selected);
  const output = resolve(catalogRoot(root), "build");
  execFileSync("bun", ["scripts/prepare-extension-native.mjs", id], {
    cwd: root,
    stdio: "inherit",
  });
  const result = spawnSync(
    "bun",
    ["scripts/build-extension-package.mjs", id, "--development"],
    {
      cwd: root,
      stdio: ["ignore", "pipe", "inherit"],
      env: {
        ...environment,
        EXTENSION_VERSION: selected,
        EXTENSION_RELEASE_TAG: tag,
        EXTENSION_OUTPUT: output,
      },
    },
  );
  if (result.status !== 0) throw new Error(`Building ${id} failed`);
  const built = JSON.parse(
    await readFile(resolve(output, `${id}.json`), "utf8"),
  );
  const releases = resolve(catalogRoot(root), "releases", tag);
  await mkdir(releases, { recursive: true });
  await copyFile(resolve(output, `${id}.zip`), resolve(releases, `${id}.zip`));
  const record = localRecord(built, { tag, hostABI });
  const recordsDirectory = resolve(catalogRoot(root), "records");
  await mkdir(recordsDirectory, { recursive: true });
  await writeFile(
    resolve(recordsDirectory, `${id}.json`),
    `${JSON.stringify(record, null, 2)}\n`,
  );
  return record;
}

export async function removeExtension(root, id) {
  await rm(resolve(catalogRoot(root), "records", `${id}.json`), {
    force: true,
  });
}

export async function serve(root, { port = defaultPort, withProduction }) {
  const { privateKey, publicKey } = await signingKey(root);
  const upstream = withProduction ? await production() : [];
  let signed = { digest: "", body: "" };
  async function catalog() {
    const local = await records(root);
    const digest = createHash("sha256")
      .update(JSON.stringify([local, upstream.length]))
      .digest("hex");
    if (digest !== signed.digest) {
      const revision = Math.max(Date.now(), (signed.revision ?? 0) + 1);
      signed = {
        digest,
        revision,
        body: JSON.stringify(
          signCatalog(catalogPayload(local, upstream, revision), privateKey),
        ),
      };
    }
    return signed.body;
  }
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/catalog.json")
        return new Response(await catalog(), {
          headers: { "Content-Type": "application/json" },
        });
      const match = path.match(
        /^\/releases\/([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+)$/,
      );
      if (!match || match[1].startsWith(".") || match[2].startsWith("."))
        return new Response("not found", { status: 404 });
      const file = resolve(catalogRoot(root), "releases", match[1], match[2]);
      if (existsSync(file)) return new Response(Bun.file(file));
      return Response.redirect(
        `https://github.com/${repository}/releases/download/${match[1]}/${match[2]}`,
        302,
      );
    },
  });
  return {
    server,
    environment: {
      EDITH_DEV_CATALOG: `http://127.0.0.1:${server.port}`,
      EDITH_DEV_CATALOG_KEY: publicKey,
    },
  };
}

export async function launch(root, environment) {
  execFileSync("scripts/dev-slots.sh", ["stop"], {
    cwd: root,
    stdio: "ignore",
  });
  const app = resolve(root, "dist/Edith.app");
  for (let attempt = 0; attempt < 60; attempt++) {
    const running = spawnSync("pgrep", ["-f", `${app}/Contents/MacOS/Edith$`]);
    if (running.status !== 0) break;
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 500);
  }
  const variables = {
    EDITH_BACKGROUND_TESTING: "1",
    EDITH_USAGE_OFFLINE: "1",
    ...environment,
  };
  execFileSync("open", [
    "-g",
    "-j",
    "-F",
    ...Object.entries(variables).flatMap(([key, value]) => [
      "--env",
      `${key}=${value}`,
    ]),
    app,
  ]);
}

function option(argumentsList, name) {
  const index = argumentsList.indexOf(name);
  return index === -1 ? undefined : argumentsList[index + 1];
}

if (import.meta.main) {
  const root = resolve(import.meta.dir, "..");
  const [command, ...rest] = process.argv.slice(2);
  if (command === "add") {
    for (const id of rest.filter(
      (value, index) =>
        !value.startsWith("--") && !rest[index - 1]?.startsWith("--"),
    )) {
      const record = await addExtension(root, id, {
        version: option(rest, "--version"),
        hostABI: option(rest, "--host-abi"),
      });
      process.stdout.write(
        `${record.id} ${record.version} ${record.hostABI}\n`,
      );
    }
  } else if (command === "remove") {
    for (const id of rest) await removeExtension(root, id);
  } else if (command === "serve") {
    const port = Number(option(rest, "--port") ?? defaultPort);
    const { environment } = await serve(root, {
      port,
      withProduction: rest.includes("--production"),
    });
    if (rest.includes("--launch")) await launch(root, environment);
    for (const [key, value] of Object.entries(environment))
      process.stdout.write(`${key}=${value}\n`);
    process.stdout.write("serving; press Ctrl-C to stop\n");
  } else {
    process.stderr.write(
      "usage: bun scripts/dev-catalog.mjs add <id>... [--version x.y.z] [--host-abi abi]\n" +
        "       bun scripts/dev-catalog.mjs remove <id>...\n" +
        "       bun scripts/dev-catalog.mjs serve [--port N] [--production] [--launch]\n",
    );
    process.exitCode = 2;
  }
}
