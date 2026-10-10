import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  downloadCIArtifact,
  prepareCIArtifacts,
  proveFixturePayload,
  readCIArtifactSet,
  validateCIArtifactSet,
  validatePackageReceipt,
  verifyFactoryOverlaySources,
} from "./hosted-managed-views/package-preparation.mjs";

const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const sha = "a".repeat(40);
const fingerprint = "b".repeat(64);
function input() {
  const definitions = Array.from({ length: 39 }, (_, index) => ({
    id: `feature${index}`,
    roles: { app: [] },
  }));
  const run = {
    id: 123,
    head_sha: sha,
    path: ".github/workflows/extensions.yml",
    status: "completed",
    conclusion: "success",
  };
  return {
    repository: "pulkitxm/edith",
    run,
    sourceCommit: sha,
    definitions,
    fingerprints: Object.fromEntries(
      definitions.map(({ id }) => [id, fingerprint]),
    ),
    jobs: definitions.map(({ id }, index) => ({
      id: 1000 + index,
      name: `build (${id})`,
      run_id: 123,
      status: "completed",
      conclusion: "success",
    })),
    artifacts: definitions.map(({ id }, index) => ({
      id: 2000 + index,
      name: `extension-${id}`,
      size_in_bytes: 10,
      expired: false,
      digest: `sha256:${fingerprint}`,
      workflow_run: { id: 123, head_sha: sha },
    })),
  };
}
function inventory(signed = "c".repeat(64), normalized = "d".repeat(64)) {
  return {
    schema: 1,
    signatureVerified: true,
    signatures: {},
    resources: {
      "Contents/Info.plist": { bytes: 12, sha256: "e".repeat(64), mode: 0o644 },
    },
    code: {
      "Contents/runtime.dylib": {
        signedSHA256: signed,
        rawUnsignedSHA256: "f".repeat(64),
        normalizedUnsignedSHA256: normalized,
        filetype: 6,
        mode: 0o755,
      },
    },
  };
}
function receipt(id = "feature0") {
  return {
    schema: 1,
    extensionID: id,
    sourceCommit: sha,
    sourceFingerprint: fingerprint,
    sourceHostExecutableSHA256: "1".repeat(64),
    zipSHA256: "2".repeat(64),
    downloadBytes: 10,
    installedBytes: 100,
    zipCRCVerified: true,
    sealedHostProvenanceVerified: true,
    signaturesVerified: true,
    packageCodeExecuted: false,
    roles: { app: inventory() },
  };
}

describe("closed successful CI39 intake", () => {
  test("binds every original archive to successful exact source build and artifact digest", () => {
    const result = validateCIArtifactSet(input());
    expect(result.originals).toHaveLength(39);
    expect(result.originals[0].jobID).toBe(1000);
    expect(result.sourceCommit).toBe(sha);
  });
  test("missing, duplicated, stale, canceled, expired, excessive and malformed rows reject", () => {
    const mutations = [
      (value) => {
        value.run.head_sha = "0".repeat(40);
      },
      (value) => {
        value.run.status = "in_progress";
      },
      (value) => {
        value.run.conclusion = "cancelled";
      },
      (value) => {
        value.run.path = ".github/workflows/ci.yml";
      },
      (value) => {
        value.jobs.pop();
      },
      (value) => {
        value.jobs[0].conclusion = "failure";
      },
      (value) => {
        value.jobs[0].run_id = 12;
      },
      (value) => {
        value.artifacts.pop();
      },
      (value) => {
        value.artifacts.push(value.artifacts[0]);
      },
      (value) => {
        value.artifacts[0].expired = true;
      },
      (value) => {
        value.artifacts[0].workflow_run.head_sha = "0".repeat(40);
      },
      (value) => {
        value.artifacts[0].workflow_run.id = 12;
      },
      (value) => {
        value.artifacts[0].digest = "sha256:not-a-digest";
      },
      (value) => {
        value.artifacts[0].size_in_bytes = 2 ** 32;
      },
      (value) => {
        delete value.fingerprints.feature0;
      },
    ];
    for (const mutate of mutations) {
      const value = input();
      mutate(value);
      expect(() => validateCIArtifactSet(value)).toThrow();
    }
  });
  test("uses derived API endpoints and validates pagination instead of supplied archive URLs", async () => {
    const value = input();
    const urls = [];
    const result = await readCIArtifactSet({
      ...value,
      runID: 123,
      fetch: async (url) => {
        urls.push(url);
        const data = url.includes("/jobs?")
          ? { total_count: 39, jobs: value.jobs }
          : url.includes("/artifacts?")
            ? { total_count: 39, artifacts: value.artifacts }
            : value.run;
        return new Response(JSON.stringify(data));
      },
    });
    expect(result.originals).toHaveLength(39);
    expect(urls).toHaveLength(3);
    expect(
      urls.every((url) =>
        url.startsWith(
          "https://api.github.com/repos/pulkitxm/edith/actions/runs/123",
        ),
      ),
    ).toBe(true);
    await expect(
      readCIArtifactSet({
        ...value,
        runID: 123,
        fetch: async (url) =>
          new Response(
            JSON.stringify(
              url.includes("?")
                ? { total_count: 101, jobs: [], artifacts: [] }
                : value.run,
            ),
          ),
      }),
    ).rejects.toThrow();
  });
});

describe("bounded digest-bound artifact transfer", () => {
  test("records exact bytes and never overwrites an existing original", async () => {
    const directory = await mkdtemp(join(tmpdir(), "managed-artifact-test-"));
    try {
      const destination = join(directory, "original.zip");
      const bytes = Buffer.from("synthetic artifact");
      const row = {
        artifactID: 1,
        artifactBytes: bytes.length,
        artifactSHA256: digest(bytes),
      };
      const fetch = async () => new Response(bytes);
      expect(
        await downloadCIArtifact({
          repository: "pulkitxm/edith",
          row,
          destination,
          fetch,
        }),
      ).toEqual({ bytes: bytes.length, sha256: digest(bytes) });
      await expect(
        downloadCIArtifact({
          repository: "pulkitxm/edith",
          row,
          destination,
          fetch,
        }),
      ).rejects.toThrow();
      expect(await readFile(destination)).toEqual(bytes);
    } finally {
      await rm(directory, { recursive: true });
    }
  });
  test("corruption, short and excess transfer leaves no verified or partial artifact", async () => {
    for (const body of ["wrong", "", "synthetic artifact plus excess"]) {
      const directory = await mkdtemp(join(tmpdir(), "managed-artifact-test-"));
      try {
        const destination = join(directory, "original.zip");
        await expect(
          downloadCIArtifact({
            repository: "pulkitxm/edith",
            row: {
              artifactID: 1,
              artifactBytes: 18,
              artifactSHA256: digest("synthetic artifact"),
            },
            destination,
            fetch: async () => new Response(body),
          }),
        ).rejects.toThrow();
        await expect(readFile(destination)).rejects.toThrow();
        await expect(readFile(`${destination}.partial`)).rejects.toThrow();
      } finally {
        await rm(directory, { recursive: true });
      }
    }
  });
  test("stalled fetch is bounded independently of transport cancellation", async () => {
    const directory = await mkdtemp(join(tmpdir(), "managed-artifact-test-"));
    try {
      await expect(
        downloadCIArtifact({
          repository: "pulkitxm/edith",
          row: {
            artifactID: 1,
            artifactBytes: 10,
            artifactSHA256: fingerprint,
          },
          destination: join(directory, "original.zip"),
          totalMilliseconds: 30,
          inactivityMilliseconds: 10,
          fetch: () => new Promise(() => {}),
        }),
      ).rejects.toThrow("progress");
    } finally {
      await rm(directory, { recursive: true });
    }
  });
});

describe("original and fixture payload truth", () => {
  test("re-signing records changed signed hashes but requires identical code/resources", () => {
    const original = receipt();
    const fixture = receipt();
    fixture.roles.app.code["Contents/runtime.dylib"].signedSHA256 = "3".repeat(
      64,
    );
    const proof = proveFixturePayload(original, fixture, {
      extensionID: "feature0",
    });
    expect(proof.rawSignedPayloadUnchanged).toBe(false);
    expect(proof.featureCodeAndResourcesUnchanged).toBe(true);
    expect(proof.functionalActionsValidated).toBe(false);
    fixture.roles.app.code["Contents/runtime.dylib"].normalizedUnsignedSHA256 =
      "4".repeat(64);
    expect(() =>
      proveFixturePayload(original, fixture, { extensionID: "feature0" }),
    ).toThrow("code changed");
  });
  test("resource, mode, absent code and invalid role changes cannot be hidden by signing", () => {
    const original = receipt();
    for (const mutate of [
      (value) => {
        value.roles.app.resources["Contents/Info.plist"].sha256 = "3".repeat(
          64,
        );
      },
      (value) => {
        value.roles.app.code["Contents/runtime.dylib"].mode = 0o644;
      },
      (value) => {
        delete value.roles.app.code["Contents/runtime.dylib"];
      },
      (value) => {
        value.roles.helper = inventory();
      },
    ]) {
      const fixture = receipt();
      mutate(fixture);
      expect(() =>
        proveFixturePayload(original, fixture, { extensionID: "feature0" }),
      ).toThrow();
    }
  });
  test("only explicit pinned Plugins/Studio native factory overlays are admitted and qualified", () => {
    for (const extensionID of ["plugins", "studio"]) {
      const original = receipt(extensionID);
      const fixture = receipt(extensionID);
      fixture.roles.app.code[
        "Contents/runtime.dylib"
      ].normalizedUnsignedSHA256 = "4".repeat(64);
      const overlay = {
        extensionID,
        reviewedSource: sha,
        sourceFilesVerified: true,
        functionalActionsValidated: false,
        sources: [
          {
            path: `Extensions/${extensionID}/Runtime.swift`,
            originalSHA256: fingerprint,
            fixtureSHA256: "5".repeat(64),
          },
        ],
        codeChanges: [
          {
            role: "app",
            path: "Contents/runtime.dylib",
            originalNormalizedSHA256: "d".repeat(64),
            fixtureNormalizedSHA256: "4".repeat(64),
          },
        ],
      };
      expect(
        proveFixturePayload(original, fixture, { extensionID, overlay })
          .factoryOverlay,
      ).toBe(true);
      expect(() =>
        proveFixturePayload(original, fixture, { extensionID }),
      ).toThrow();
      overlay.codeChanges[0].fixtureNormalizedSHA256 = "6".repeat(64);
      expect(() =>
        proveFixturePayload(original, fixture, { extensionID, overlay }),
      ).toThrow();
    }
    expect(() =>
      proveFixturePayload(receipt(), receipt(), {
        extensionID: "feature0",
        overlay: {},
      }),
    ).toThrow();
  });
  test("static package receipts reject lost CRC/signature/FP or unknown roles", () => {
    const row = { extensionID: "feature0", sourceFingerprint: fingerprint };
    const definition = { roles: { app: [] } };
    expect(
      validatePackageReceipt(receipt(), row, definition, sha, "1".repeat(64))
        .extensionID,
    ).toBe("feature0");
    for (const key of [
      "zipCRCVerified",
      "sealedHostProvenanceVerified",
      "signaturesVerified",
    ]) {
      const value = receipt();
      value[key] = false;
      expect(() =>
        validatePackageReceipt(value, row, definition, sha, "1".repeat(64)),
      ).toThrow();
    }
    const value = receipt();
    value.sourceFingerprint = "7".repeat(64);
    expect(() =>
      validatePackageReceipt(value, row, definition, sha, "1".repeat(64)),
    ).toThrow();
  });
});

describe("atomic complete preparation receipts", () => {
  test("only a complete exact-source 39-set produces an aggregate and executes no package", async () => {
    const directory = await realpath(
      await mkdtemp(join(tmpdir(), "managed-preparation-test-")),
    );
    try {
      const hostApp = join(directory, "Host.app");
      await mkdir(join(hostApp, "Contents/MacOS"), { recursive: true });
      await writeFile(
        join(hostApp, "Contents/MacOS/Edith"),
        "never-executed synthetic host",
      );
      const hostSHA256 = digest("never-executed synthetic host");
      const value = input();
      const bytes = Buffer.from("synthetic-ci-artifact");
      for (const artifact of value.artifacts) {
        artifact.digest = `sha256:${digest(bytes)}`;
        artifact.size_in_bytes = bytes.length;
      }
      const fetch = async (url) => {
        if (url.includes("/zip")) return new Response(bytes);
        return new Response(
          JSON.stringify(
            url.includes("/jobs?")
              ? { total_count: 39, jobs: value.jobs }
              : url.includes("/artifacts?")
                ? { total_count: 39, artifacts: value.artifacts }
                : value.run,
          ),
        );
      };
      const common = {
        ...value,
        runID: 123,
        hostApp,
        hostSHA256,
        hostBuildMetadata: {
          sourceCommit: sha,
          sourceTreeDirty: false,
          hostExecutableSHA256: hostSHA256,
        },
        fetch,
      };
      const visited = [];
      const result = await prepareCIArtifacts({
        ...common,
        output: join(directory, "complete"),
        verifyPackage: async ({ row }) => {
          visited.push(row.extensionID);
          return {
            ...receipt(row.extensionID),
            sourceHostExecutableSHA256: hostSHA256,
          };
        },
      });
      expect(result.originals).toHaveLength(39);
      expect(visited).toHaveLength(39);
      expect(result.packageCodeExecuted).toBe(false);
      expect(
        JSON.parse(
          await readFile(join(directory, "complete/receipt.json"), "utf8"),
        ).sourceCommit,
      ).toBe(sha);
      await expect(
        prepareCIArtifacts({
          ...common,
          output: join(directory, "failed"),
          verifyPackage: async () => {
            throw new Error("static proof rejected");
          },
        }),
      ).rejects.toThrow("static proof rejected");
      await expect(
        readFile(join(directory, "failed/receipt.json")),
      ).rejects.toThrow();
      await expect(
        prepareCIArtifacts({
          ...common,
          output: join(directory, "wrong-source"),
          hostBuildMetadata: {
            ...common.hostBuildMetadata,
            sourceCommit: "0".repeat(40),
          },
        }),
      ).rejects.toThrow();
    } finally {
      await rm(directory, { recursive: true });
    }
  });
});

test("factory source review checks both actual source trees and rejects changed or escaped source", async () => {
  const directory = await realpath(
    await mkdtemp(join(tmpdir(), "managed-overlay-test-")),
  );
  try {
    const originalRoot = join(directory, "original");
    const fixtureRoot = join(directory, "fixture");
    const path = "Extensions/plugins/Runtime.swift";
    for (const root of [originalRoot, fixtureRoot])
      await mkdir(join(root, "Extensions/plugins"), { recursive: true });
    await writeFile(join(originalRoot, path), "original synthetic factory");
    await writeFile(join(fixtureRoot, path), "reviewed synthetic factory");
    const overlay = {
      extensionID: "plugins",
      reviewedSource: sha,
      sources: [
        {
          path,
          originalSHA256: digest("original synthetic factory"),
          fixtureSHA256: digest("reviewed synthetic factory"),
        },
      ],
    };
    expect(
      (
        await verifyFactoryOverlaySources(overlay, {
          originalRoot,
          fixtureRoot,
        })
      ).sourceFilesVerified,
    ).toBe(true);
    await writeFile(join(fixtureRoot, path), "unreviewed factory");
    await expect(
      verifyFactoryOverlaySources(overlay, { originalRoot, fixtureRoot }),
    ).rejects.toThrow("differs from its review");
    overlay.sources[0].path = "Extensions/plugins/../Runtime.swift";
    await expect(
      verifyFactoryOverlaySources(overlay, { originalRoot, fixtureRoot }),
    ).rejects.toThrow();
  } finally {
    await rm(directory, { recursive: true });
  }
});
