import { expect, test } from "bun:test";
import { chmod, link, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createSparkleCatalogSwitch,
  readSparkleFixedFile,
} from "./hosted-sparkle-update/fixed-files.mjs";

test("catalog admission switches only the pinned synthetic envelopes once and refuses changed bytes", async () => {
  const directory = await mkdtemp(join(tmpdir(), "sparkle-fixed-"));
  const bytes = (revision) =>
    Buffer.from(
      JSON.stringify({
        payload: Buffer.from(JSON.stringify({ revision })).toString("base64"),
        signature: Buffer.alloc(64, revision).toString("base64"),
      }),
    );
  try {
    await chmod(directory, 0o700);
    await writeFile(join(directory, "active-catalog.json"), bytes(1), {
      mode: 0o600,
    });
    await writeFile(join(directory, "updated-catalog.json"), bytes(2), {
      mode: 0o600,
    });
    const change = await createSparkleCatalogSwitch(directory);
    await writeFile(join(directory, "updated-catalog.json"), bytes(3));
    await expect(change()).rejects.toThrow();
    expect(
      await readSparkleFixedFile(directory, "active-catalog.json", 4096),
    ).toEqual(bytes(1));
    await writeFile(join(directory, "updated-catalog.json"), bytes(2));
    await change();
    expect(
      await readSparkleFixedFile(directory, "active-catalog.json", 4096),
    ).toEqual(bytes(2));
    await expect(change()).rejects.toThrow();
  } finally {
    await rm(directory, { recursive: true });
  }
});

test("fixed document reader rejects outside names, symlink, hardlink, public mode and nonprivate root", async () => {
  const directory = await mkdtemp(join(tmpdir(), "sparkle-fixed-"));
  try {
    await chmod(directory, 0o700);
    const file = join(directory, "updated-catalog.json");
    await writeFile(file, "synthetic", { mode: 0o600 });
    await expect(
      readSparkleFixedFile(directory, "../outside", 1024),
    ).rejects.toThrow();
    await symlink(file, join(directory, "active-catalog.json"));
    await expect(
      readSparkleFixedFile(directory, "active-catalog.json", 1024),
    ).rejects.toThrow();
    await rm(join(directory, "active-catalog.json"));
    await link(file, join(directory, "active-catalog.json"));
    await expect(
      readSparkleFixedFile(directory, "active-catalog.json", 1024),
    ).rejects.toThrow();
    await rm(join(directory, "active-catalog.json"));
    await chmod(file, 0o644);
    await expect(
      readSparkleFixedFile(directory, "updated-catalog.json", 1024),
    ).rejects.toThrow();
    await chmod(file, 0o600);
    await chmod(directory, 0o740);
    await expect(
      readSparkleFixedFile(directory, "updated-catalog.json", 1024),
    ).rejects.toThrow();
  } finally {
    await rm(directory, { recursive: true });
  }
});
