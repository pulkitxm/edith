import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export function publishHostRelease({
  directory,
  repository,
  tag,
  target,
  rebuild = false,
  execute = execFileSync,
}) {
  if (
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) ||
    !/^v\d+\.\d+\.\d+$/.test(tag) ||
    !/^[0-9a-f]{40}$/.test(target)
  )
    throw new Error("Invalid release identity");
  const assets = ["Edith.dmg", "appcast.xml"];
  for (const name of assets) {
    if (statSync(resolve(directory, name)).size === 0)
      throw new Error("Empty release asset");
  }
  const appcast = readFileSync(resolve(directory, "appcast.xml"), "utf8");
  if (
    !appcast.includes(
      `https://github.com/${repository}/releases/download/${tag}/Edith.dmg`,
    ) ||
    !/sparkle:edSignature="[^"\s]+"/.test(appcast)
  )
    throw new Error("Invalid signed appcast");
  const gh = (...args) => execute("gh", args, { encoding: "utf8" });
  const mutate = (...args) =>
    execute("pukbot", [...args, "--repo", repository, "--json"], {
      encoding: "utf8",
    });
  let release;
  try {
    release = JSON.parse(gh("api", `repos/${repository}/releases/tags/${tag}`));
  } catch (error) {
    if (!String(error.stderr).includes("404")) throw error;
  }
  if (!release) {
    if (rebuild) throw new Error("Cannot rebuild a missing release");
    mutate(
      "release",
      "create",
      tag,
      "--name",
      `Edith ${tag}`,
      "--target",
      target,
      "--draft",
      "--generate-notes",
    );
    release = JSON.parse(gh("api", `repos/${repository}/releases/tags/${tag}`));
  }
  for (const name of assets) {
    const file = resolve(directory, name);
    const existing = release.assets.find((asset) => asset.name === name);
    if (existing) {
      const downloaded = execute("gh", [
        "api",
        "-H",
        "Accept: application/octet-stream",
        `repos/${repository}/releases/assets/${existing.id}`,
      ]);
      if (Buffer.from(downloaded).equals(readFileSync(file))) continue;
      if (!rebuild) throw new Error(`Existing release asset differs: ${name}`);
      gh(
        "api",
        "--method",
        "DELETE",
        `repos/${repository}/releases/assets/${existing.id}`,
      );
    }
    mutate("release", "upload-asset", String(release.id), file);
  }
  mutate(
    "release",
    "edit",
    String(release.id),
    "--draft",
    "false",
    "--make-latest",
    "true",
  );
  return { tag, assets };
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  const target = execFileSync(
    "git",
    ["-C", "release-source", "rev-parse", "HEAD"],
    { encoding: "utf8" },
  ).trim();
  process.stdout.write(
    `${JSON.stringify(publishHostRelease({ directory: resolve(process.argv[2]), repository: process.env.GITHUB_REPOSITORY, tag: process.env.RELEASE_TAG, target, rebuild: Boolean(process.env.REBUILD) }))}\n`,
  );
}
