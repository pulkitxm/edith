import {
  createHash,
  createPrivateKey,
  createPublicKey,
  sign,
} from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import {
  managedNativeBuildSteps,
  shippingNativeTestSteps,
} from "./hosted-managed-views/native-ci-contract.mjs";
import {
  nativeLineage,
  preservationStep,
  publicationComposition,
} from "./hosted-public-release/evidence.mjs";

const privateKey = createPrivateKey({
  key: Buffer.concat([
    Buffer.from("302e020100300506032b657004220420", "hex"),
    Buffer.alloc(32, 7),
  ]),
  format: "der",
  type: "pkcs8",
});
const envelope = (value) => {
  const payload = Buffer.from(JSON.stringify(value));
  return Buffer.from(
    JSON.stringify({
      payload: payload.toString("base64"),
      signature: sign(null, payload, privateKey).toString("base64"),
    }),
  );
};
const digest = (bytes) => ({
  bytes: bytes.length,
  sha256: createHash("sha256").update(bytes).digest("hex"),
});
const [destination, mode = "retained"] = process.argv.slice(2);
if (mode === "resign") {
  await writeFile(
    destination,
    envelope(JSON.parse(await readFile(destination, "utf8"))),
  );
} else {
  const root = resolve(destination);
  const ids = [
    "first",
    "second",
    ...Array.from({ length: 38 }, (_, index) => `synthetic${index}`),
  ];
  const fingerprints = Object.fromEntries(
    ids.map((id) => [id, "f".repeat(64)]),
  );
  const records = Object.fromEntries(
    ids.map((id) => [
      id,
      { id, sha256: "c".repeat(64), sourceFingerprint: fingerprints[id] },
    ]),
  );
  const links = `${root}/native-links`;
  await mkdir(links, { recursive: true });
  const current = { source: "b".repeat(40), runID: 300, attempt: 2 };
  async function release(sourceCommit, runID, runAttempt, plannedIDs) {
    const directory = `${root}/evidence-assets/${sourceCommit}/${runID}-${runAttempt}`;
    await mkdir(directory, { recursive: true });
    const artifacts = [];
    for (const [index, name] of [
      "extension-plan",
      "frozen-extension-host",
      ...plannedIDs.map((id) => `extension-${id}`),
    ].entries()) {
      const bytes = Buffer.from("original synthetic archive bytes");
      const assetName = `${name}-${index + 1}.zip`;
      await writeFile(`${directory}/${assetName}`, bytes);
      artifacts.push({
        name,
        artifactID: index + 1,
        artifactBytes: bytes.length,
        artifactSHA256: digest(bytes).sha256,
        assetName,
      });
    }
    const jobs = [
      "plan",
      "frozen-host",
      "tests",
      "publish",
      ...(plannedIDs.length
        ? plannedIDs.map((id) => `build (${id})`)
        : ["build"]),
    ]
      .map((name, index) => ({
        id: index + 1,
        name,
        steps: (name === "tests"
          ? shippingNativeTestSteps
          : name.startsWith("build (")
            ? managedNativeBuildSteps
            : name === "publish"
              ? [preservationStep]
              : []
        ).map((name, index) => ({ name, number: index + 1 })),
      }))
      .sort((left, right) => left.name.localeCompare(right.name));
    const payload = {
      schema: 1,
      kind: "extension-native-evidence",
      repository: "pulkitxm/edith",
      workflowPath: ".github/workflows/extensions.yml",
      event: "push",
      sourceCommit,
      runID,
      runAttempt,
      plannedIDs,
      fingerprints,
      jobs,
      artifacts,
    };
    const bytes = envelope(payload);
    await writeFile(`${directory}/native-evidence.json`, bytes);
    return { directory, payload, bytes };
  }
  const origin =
    mode === "current"
      ? await release(current.source, current.runID, current.attempt, ids)
      : await release("a".repeat(40), 100, 1, ids);
  const rows = [];
  for (const id of ids) {
    const lineage = nativeLineage(
      records[id],
      origin.payload,
      digest(origin.bytes),
    );
    const bytes = envelope(lineage);
    await writeFile(`${links}/${id}.native-evidence.json`, bytes);
    rows.push({
      package: records[id],
      lineageSHA256: digest(bytes).sha256,
      lineageBytes: bytes.length,
      sourceCommit: lineage.sourceCommit,
      runID: lineage.runID,
      runAttempt: lineage.runAttempt,
      evidenceSHA256: lineage.evidenceSHA256,
      evidenceBytes: lineage.evidenceBytes,
    });
  }
  const publication =
    mode === "current"
      ? origin
      : await release(
          current.source,
          current.runID,
          current.attempt,
          mode === "zero-plan" ? [] : ["first"],
        );
  await writeFile(
    `${publication.directory}/publication-composition.json`,
    envelope(
      publicationComposition(
        current.source,
        current.runID,
        current.attempt,
        rows,
        fingerprints,
      ),
    ),
  );
  if (mode === "historical-composition") {
    await writeFile(
      `${origin.directory}/publication-composition.json`,
      envelope(
        publicationComposition(
          origin.payload.sourceCommit,
          origin.payload.runID,
          origin.payload.runAttempt,
          rows,
          fingerprints,
        ),
      ),
    );
  }
  const key = Buffer.from(
    createPublicKey(privateKey).export({ format: "jwk" }).x,
    "base64url",
  ).toString("base64");
  process.stdout.write(JSON.stringify({ key, records, current }));
}
