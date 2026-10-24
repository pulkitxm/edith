import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmod,
  copyFile,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rename,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { withFrozenCarrierDirectory } from "./extension-native-evidence.mjs";

const sourceRoot = dirname(dirname(import.meta.path));
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const python = (script, args, cwd) =>
  execFileSync("python3", ["-I", "-B", "-c", script, ...args], {
    cwd,
    timeout: 3000,
    maxBuffer: 1024 ** 2,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });

async function fixture(operation) {
  const root = await mkdtemp(join(tmpdir(), "synthetic-native-carrier-"));
  await chmod(root, 0o700);
  try {
    for (const path of [
      "scripts/hosted-managed-views/frozen-host-artifact.py",
      "scripts/hosted-managed-views/verify-package.py",
      "scripts/package_extension_lifecycle_tools.py",
      "scripts/macho_code_identity.py",
    ]) {
      await mkdir(dirname(join(root, path)), { recursive: true, mode: 0o700 });
      await copyFile(join(sourceRoot, path), join(root, path));
    }
    const rows = Array.from({ length: 40 }, (_, index) => ({
      id: `owner${index}`,
      title: `Synthetic ${index}`,
      symbolName: "square",
      category: "Synthetic",
    }));
    const index = Buffer.from(JSON.stringify(rows));
    await mkdir(
      join(root, "Packages/EdithHost/Sources/EdithHostCore/Resources"),
      {
        recursive: true,
        mode: 0o700,
      },
    );
    await mkdir(join(root, "Extensions"), { mode: 0o700 });
    await writeFile(
      join(
        root,
        "Packages/EdithHost/Sources/EdithHostCore/Resources/index.json",
      ),
      index,
    );
    await writeFile(
      join(root, "Extensions/manifest.json"),
      JSON.stringify(rows),
    );
    await writeFile(join(root, ".gitignore"), "local/\n");
    const git = (...args) =>
      execFileSync("git", args, {
        cwd: root,
        timeout: 3000,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      });
    git("init", "--quiet");
    git("add", "Packages", "Extensions", ".gitignore", "scripts");
    git(
      "-c",
      "user.name=Synthetic Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "Synthetic frozen source",
    );
    const source = git("rev-parse", "HEAD").trim();
    const minimal = Buffer.from("synthetic minimal host");
    const carrier = Buffer.from("synthetic tiny carrier");
    const receipt = {
      kind: "carrier",
      schema: 2,
      sourceCommit: source,
      hostExecutableSHA256: hash(minimal),
      indexSHA256: hash(index),
      files: {
        "EdithHost_EdithHostCore.bundle/index.json": {
          sha256: hash(index),
          bytes: index.length,
          mode: 0o600,
        },
        EdithExtensionCarrier: {
          sha256: hash(carrier),
          bytes: carrier.length,
          mode: 0o700,
        },
      },
    };
    const contents = {
      "local/minimal-host/Edith.app/Contents/MacOS/Edith": [
        minimal.toString(),
        0o700,
      ],
      "local/minimal-host/Edith.app/Contents/Info.plist": [
        "synthetic info",
        0o600,
      ],
      "local/minimal-host/Edith.app/Contents/Resources/index.json": [
        index.toString(),
        0o600,
      ],
      "local/minimal-host/build-metadata.json": [
        JSON.stringify({
          sourceCommit: source,
          sourceTreeDirty: false,
          hostExecutableSHA256: hash(minimal),
        }),
        0o600,
      ],
      "local/minimal-host/carrier-tools/lifecycle-tools.json": [
        JSON.stringify(receipt),
        0o600,
      ],
      "local/minimal-host/carrier-tools/EdithHost_EdithHostCore.bundle/index.json":
        [index.toString(), 0o600],
      "local/minimal-host/carrier-tools/EdithExtensionCarrier": [
        carrier.toString(),
        0o700,
      ],
      "local/extension-release-host/Edith.app/Contents/MacOS/Edith": [
        "different signed release bytes",
        0o700,
      ],
    };
    const document = join(root, "archive-input.json");
    const artifact = join(root, "artifact.zip");
    await writeFile(document, JSON.stringify(contents));
    python(
      "import io,json,tarfile,zipfile,sys\nrows=json.load(open(sys.argv[1]))\ncompressed=io.BytesIO()\nwith tarfile.open(fileobj=compressed,mode='w:gz') as archive:\n for name,(text,mode) in rows.items():\n  data=text.encode();entry=tarfile.TarInfo(name);entry.size=len(data);entry.mode=mode;archive.addfile(entry,io.BytesIO(data))\nwith zipfile.ZipFile(sys.argv[2],'w') as archive:archive.writestr('host.tar.gz',compressed.getvalue())",
      [document, artifact],
      root,
    );
    const provider = (directory) =>
      JSON.parse(
        python(
          "import importlib.util,json,sys\nfrom pathlib import Path\np=Path(sys.argv[1]);spec=importlib.util.spec_from_file_location('verify_package',p);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)\nvalue=module.frozen_carrier_provider(sys.argv[2])()\nvalue['path']=str(value['path']);print(json.dumps(value))",
          [
            join(root, "scripts/hosted-managed-views/verify-package.py"),
            directory,
          ],
          root,
        ),
      );
    return await operation({
      root,
      artifact,
      source,
      minimal,
      carrier,
      provider,
    });
  } finally {
    await rm(root, { recursive: true });
  }
}

test("same frozen archive restores the raw minimal carrier binding and cleans its owned context", async () => {
  await fixture(
    async ({ root, artifact, source, minimal, carrier, provider }) => {
      let directory;
      const result = await withFrozenCarrierDirectory(
        root,
        artifact,
        async (owned) => {
          directory = owned;
          expect(
            (
              await readFile(join(owned, "Edith.app/Contents/MacOS/Edith"))
            ).equals(minimal),
          ).toBe(true);
          const value = provider(owned);
          expect(value.sourceCommit).toBe(source);
          expect(value.hostExecutableSHA256).toBe(hash(minimal));
          expect(value.sha256).toBe(hash(carrier));
          expect(value.path).toBe(
            join(owned, "carrier-tools/EdithExtensionCarrier"),
          );
          return value.sha256;
        },
      );
      expect(result).toBe(hash(carrier));
      expect(await readdir(join(root, "local"))).toEqual([]);
      await expect(
        readFile(join(directory, "build-metadata.json")),
      ).rejects.toThrow();
    },
  );
});

test("foreign source and mutated carrier bytes reject without leaving extracted provenance", async () => {
  await fixture(async ({ root, artifact, provider }) => {
    for (const mutate of [
      async (owned) => {
        const path = join(owned, "build-metadata.json");
        const metadata = JSON.parse(await readFile(path, "utf8"));
        metadata.sourceCommit = "f".repeat(40);
        await writeFile(path, JSON.stringify(metadata));
      },
      async (owned) =>
        writeFile(
          join(owned, "carrier-tools/EdithExtensionCarrier"),
          "changed",
        ),
    ]) {
      await expect(
        withFrozenCarrierDirectory(root, artifact, async (owned) => {
          await mutate(owned);
          return provider(owned);
        }),
      ).rejects.toThrow();
      expect(await readdir(join(root, "local"))).toEqual([]);
    }
  });
});

test("verifier carrier context cannot escape its real source workspace", async () => {
  await fixture(async ({ root, artifact, provider }) => {
    await withFrozenCarrierDirectory(root, artifact, async () => {
      expect(() => provider(dirname(root))).toThrow();
    });
    expect(await readdir(join(root, "local"))).toEqual([]);
  });
});

test("malformed authenticated input fails extraction and removes only the new context", async () => {
  await fixture(async ({ root, artifact }) => {
    await writeFile(artifact, "not a zip");
    let called = false;
    await expect(
      withFrozenCarrierDirectory(root, artifact, async () => {
        called = true;
      }),
    ).rejects.toThrow();
    expect(called).toBe(false);
    expect(await readdir(join(root, "local"))).toEqual([]);
  });
});

test("replaced directory identity fails cleanup without following a foreign target", async () => {
  await fixture(async ({ root, artifact }) => {
    const foreign = join(root, "foreign");
    await mkdir(foreign, { mode: 0o700 });
    await writeFile(join(foreign, "sentinel"), "untouched");
    let moved;
    let replaced;
    try {
      await expect(
        withFrozenCarrierDirectory(root, artifact, async (owned) => {
          moved = `${owned}-held`;
          replaced = owned;
          await rename(owned, moved);
          await symlink(foreign, owned);
        }),
      ).rejects.toThrow();
      expect(await readFile(join(foreign, "sentinel"), "utf8")).toBe(
        "untouched",
      );
    } finally {
      if (replaced) await rm(replaced);
      if (moved) await rm(moved, { recursive: true });
    }
  });
});
