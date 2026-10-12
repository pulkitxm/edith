import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import {
  factoryCompileArguments,
  factoryNativeArguments,
} from "./hosted-managed-views/factory-overlay.mjs";
import { admitManagedPreparation } from "./hosted-managed-views/prepare-owner.mjs";

const definitions = JSON.parse(
  await readFile(new URL("../Extensions/manifest.json", import.meta.url)),
);
const root = resolve(new URL("..", import.meta.url).pathname);
const environment = {
  GITHUB_ACTIONS: "true",
  RUNNER_OS: "macOS",
  RUNNER_ENVIRONMENT: "github-hosted",
  EDITH_HOSTED_MANAGED_VIEWS: "1",
};
const uuid = "00000000-0000-4000-8000-000000000001";
const home = "/Users/synthetic";
const directory = `${home}/Applications/Edith Managed Views ${uuid}`;

test("closed hosted preparation rejects local execution and namespace/path substitution", () => {
  for (const id of ["calendar", "music", "virtualCamera"]) {
    const identifier = `com.pulkit.edith.tests.${id === "calendar" ? "remote" : "worker"}-${uuid}`;
    expect(() =>
      admitManagedPreparation(environment, directory, identifier, home, id),
    ).not.toThrow();
    for (const key of Object.keys(environment))
      expect(() =>
        admitManagedPreparation(
          { ...environment, [key]: "other" },
          directory,
          identifier,
          home,
          id,
        ),
      ).toThrow();
    expect(() =>
      admitManagedPreparation(
        environment,
        `${directory}/../other`,
        identifier,
        home,
        id,
      ),
    ).toThrow();
    expect(() =>
      admitManagedPreparation(
        environment,
        directory,
        "com.pulkit.edith",
        home,
        id,
      ),
    ).toThrow();
    expect(() =>
      admitManagedPreparation(
        environment,
        directory,
        identifier.replace(uuid, "not-a-uuid"),
        home,
        id,
      ),
    ).toThrow();
  }
});

test("unknown future owner cannot use a known synthetic namespace", () => {
  expect(() =>
    admitManagedPreparation(
      environment,
      directory,
      `com.pulkit.edith.tests.worker-${uuid}`,
      home,
      "futureWorker",
    ),
  ).toThrow();
  expect(() =>
    admitManagedPreparation(
      environment,
      directory,
      `com.pulkit.edith.tests.worker-${uuid}`,
      "relative/home",
      "music",
    ),
  ).toThrow();
});

test("factory compile keeps scoped SDK, current role sources and factory exports", () => {
  for (const id of ["plugins", "studio"]) {
    const definition = definitions.find((item) => item.id === id);
    const sources = definition.roles.app.map(
      (_, index) => `/synthetic/source/${index}.swift`,
    );
    const args = factoryCompileArguments({
      definition,
      sources,
      support: { products: "/synthetic/sdk", product: "ScopedSupport" },
      root,
      contents: "/synthetic/payload/app.bundle/Contents",
      developer: "/synthetic/Xcode/Contents/Developer",
    });
    expect(args.slice(0, 3)).toEqual([
      "swiftc",
      "-emit-library",
      "-parse-as-library",
    ]);
    expect(
      args.filter((item) => item === "_edith_extension_create"),
    ).toHaveLength(1);
    expect(
      args.filter((item) => item === "_edith_extension_presentation_create"),
    ).toHaveLength(1);
    expect(args).toContain("-lScopedSupport");
    for (const source of sources) expect(args).toContain(source);
    expect(args.at(-1)).toBe(
      "/synthetic/payload/app.bundle/Contents/MacOS/Runtime",
    );
    expect(() =>
      factoryCompileArguments({
        definition: { ...definition, id: "music" },
        sources,
        support: {},
        root,
        contents: "",
        developer: "",
      }),
    ).toThrow();
    expect(() =>
      factoryCompileArguments({
        definition,
        sources: sources.slice(1),
        support: {},
        root,
        contents: "",
        developer: "",
      }),
    ).toThrow();
  }
});

test("native overlay build uses one job even when ambient environment requests more", () => {
  const definition = definitions.find((item) => item.id === "studio");
  const previous = process.env.EXTENSION_SWIFT_JOBS;
  try {
    process.env.EXTENSION_SWIFT_JOBS = "8";
    const args = factoryNativeArguments(
      root,
      definition,
      "/synthetic/Xcode/Contents/Developer",
    );
    expect(args[args.indexOf("--jobs") + 1]).toBe("1");
    expect(args[args.indexOf("--product") + 1]).toBe(definition.nativeProduct);
    expect(args).toContain("--force-resolved-versions");
  } finally {
    if (previous === undefined) delete process.env.EXTENSION_SWIFT_JOBS;
    else process.env.EXTENSION_SWIFT_JOBS = previous;
  }
});
