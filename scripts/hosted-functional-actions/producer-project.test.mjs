import assert from "node:assert/strict";
import test from "node:test";
import {
  admitFunctionalRunner,
  functionalProducerBootstrapSource,
} from "./producer-project.mjs";

const sourceCommit = "a".repeat(40);
const environment = {
  GITHUB_ACTIONS: "true",
  RUNNER_ENVIRONMENT: "github-hosted",
  RUNNER_OS: "macOS",
  GITHUB_REPOSITORY: "pulkitxm/edith",
  GITHUB_EVENT_NAME: "workflow_dispatch",
  EDITH_HOSTED_FUNCTIONAL_ACTIONS: "1",
  GITHUB_SHA: sourceCommit,
  EXPECTED_SOURCE_SHA: sourceCommit,
  EXTENSION_SWIFT_JOBS: "1",
  GITHUB_ACTOR_ID: "65671483",
  GITHUB_REF: "refs/heads/feat/extension-marketplace",
  EXTENSION_SIGN_IDENTITY: "synthetic reviewed signer",
  DEVELOPER_DIR: "/Applications/Xcode.app/Contents/Developer",
  RUNNER_TEMP: "/private/synthetic",
};

test("producer builds cannot run on local, unreviewed, unsigned, different source or unbounded build environments", () => {
  admitFunctionalRunner(environment, sourceCommit);
  for (const [key, value] of Object.entries({
    GITHUB_ACTIONS: "false",
    RUNNER_ENVIRONMENT: "self-hosted",
    GITHUB_EVENT_NAME: "push",
    GITHUB_SHA: "b".repeat(40),
    EXPECTED_SOURCE_SHA: "b".repeat(40),
    GITHUB_ACTOR_ID: "1",
    GITHUB_REF: "refs/heads/unreviewed",
    EXTENSION_SIGN_IDENTITY: "-",
    EXTENSION_SWIFT_JOBS: "4",
    DEVELOPER_DIR: "/Library/Developer/CommandLineTools",
    RUNNER_TEMP: "relative",
  }))
    assert.throws(() =>
      admitFunctionalRunner({ ...environment, [key]: value }, sourceCommit),
    );
});

test("source-built producer pins issuer scope, exact independently reviewed operation arrays and actual original role map before Host build", () => {
  const source = functionalProducerBootstrapSource({
    sourceCommit,
    session: "12345678-1234-4123-8123-123456789abc",
    root: "/private/synthetic/functional-fixture-12345678-1234-4123-8123-123456789abc",
    hostIdentifier:
      "com.pulkit.edith.tests.worker-12345678-1234-4123-8123-123456789abc",
    producerIdentifier:
      "com.pulkit.edith.tests.functional-producer-12345678-1234-4123-8123-123456789abc",
    certificateSHA256: Buffer.alloc(32, 9).toString("base64"),
    definitions: [
      {
        owner: "synthetic",
        operations: ["synthetic.change"],
        activation: { operation: "synthetic.change" },
      },
    ],
    roles: { synthetic: ["helper"] },
    recipes: { synthetic: { location: "main", section: "synthetic" } },
    policySHA256: "b".repeat(64),
    rolePolicySwiftExpression: "[]",
  });
  assert(
    source.includes(
      'static let operations: [String: [String]] = ["synthetic": ["synthetic.change"]]',
    ),
  );
  assert(
    source.includes(
      'static let roles: [String: [String]] = ["synthetic": ["helper"]]',
    ),
  );
  assert(!source.includes("hostExecutableSHA256"));
  assert(!source.includes("privateKey"));
  assert(!source.includes("descriptorPath"));
});
