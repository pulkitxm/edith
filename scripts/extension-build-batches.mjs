import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

export const maximumBuildBatches = 5;

export const extensionBuildCost = {
  database: 640,
  virtualCamera: 600,
  herdr: 450,
  studio: 380,
  music: 380,
  attention: 360,
  machines: 340,
  usage: 310,
  companion: 260,
  audioMixer: 240,
  appMaintenance: 230,
  bifrost: 220,
  quinjet: 200,
  clipboard: 200,
  cleaner: 190,
  notchShelf: 190,
  docs: 180,
  lidAwake: 180,
  emoji: 170,
  seoAudit: 170,
};

export function buildCost(id) {
  return extensionBuildCost[id] ?? 120;
}

const identifier = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
const version = /^\d+\.\d+\.\d+$/;
const fingerprint = /^[a-f0-9]{64}$/;

export function batchExtensionBuilds(include, limit = maximumBuildBatches) {
  if (!Array.isArray(include) || !Number.isSafeInteger(limit) || limit < 1)
    throw new Error("Invalid extension build plan");
  const ids = new Set();
  for (const entry of include) {
    if (
      !identifier.test(entry?.id ?? "") ||
      !version.test(entry.version ?? "") ||
      !fingerprint.test(entry.supportFingerprint ?? "") ||
      ids.has(entry.id)
    )
      throw new Error("Invalid extension build plan");
    ids.add(entry.id);
  }
  const batches = Array.from(
    { length: Math.min(limit, include.length) },
    () => ({ cost: 0, entries: [] }),
  );
  const ordered = [...include].sort(
    (left, right) =>
      buildCost(right.id) - buildCost(left.id) ||
      left.id.localeCompare(right.id),
  );
  for (const entry of ordered) {
    const target = batches.reduce((lightest, batch) =>
      batch.cost < lightest.cost ? batch : lightest,
    );
    target.entries.push(entry);
    target.cost += buildCost(entry.id);
  }
  return batches.map(({ cost, entries }, index) => {
    const sorted = [...entries].sort((left, right) =>
      left.id.localeCompare(right.id),
    );
    const support = sorted.map(
      ({ id, supportFingerprint }) => `${id}:${supportFingerprint}`,
    );
    return {
      batch: String(index + 1),
      cost,
      ids: sorted.map(({ id }) => id).join(" "),
      builds: sorted.map(({ id, version }) => `${id}=${version}`).join(" "),
      camera: sorted.some(({ id }) => id === "virtualCamera"),
      supportPaths: sorted
        .flatMap(({ id }) => [
          `local/extension-support/${id}_*/build.json`,
          `local/extension-support/${id}_*/.build/arm64-apple-macosx/release/lib*.a`,
          `local/extension-support/${id}_*/.build/arm64-apple-macosx/release/Modules`,
          `local/extension-support/${id}_*/.build/arm64-apple-macosx/release/*.bundle`,
          `local/extension-support/${id}_*/.build/out/Products/Release`,
        ])
        .join("\n"),
      supportKey: createHash("sha256").update(support.join("\n")).digest("hex"),
    };
  });
}

if (import.meta.main) {
  if (process.argv.length !== 3) throw new Error("Specify the extension plan");
  const plan = JSON.parse(await readFile(process.argv[2], "utf8"));
  process.stdout.write(
    `${JSON.stringify({ include: batchExtensionBuilds(plan.include) })}\n`,
  );
}
