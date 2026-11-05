import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { rewriteArgumentParserWarnings } from "./argument-parser-source.mjs";
import {
  contextModule,
  supportProducts,
  supportSourceInputs,
} from "./build-extension-support.mjs";
import { planExtensionBuilds } from "./extension-release-plan.mjs";

test("account support changes select Herdr and Usage independently of the empty host", () => {
  const definitions = JSON.parse(
    readFileSync("Extensions/manifest.json", "utf8"),
  );
  expect(
    planExtensionBuilds(definitions, [
      "Packages/ExtensionSupport/Sources/EdithExtensionAccounts/ClaudeAccountStorage.swift",
    ])
      .map(({ id }) => id)
      .sort(),
  ).toEqual(["herdr", "usage"]);
  expect(
    readFileSync("Packages/EdithHost/Package.swift", "utf8"),
  ).not.toContain("EdithExtensionAccounts");
  for (const id of ["herdr", "usage"]) {
    const definition = definitions.find((entry) => entry.id === id);
    expect(supportProducts(definition.supportProduct)).toContain(
      "EdithExtensionAccounts",
    );
    expect(
      definition.roles.app.some((path) => path.includes("ClaudeAccount")),
    ).toBeTrue();
    expect(definition.testTargets).toContain("ci-extension-accounts");
  }
});

test("each extension role gets its own context module", () => {
  expect(contextModule("calendar_app")).toBe(
    "EdithExtensionSupport_calendar_app",
  );
  expect(contextModule("calendar_app")).not.toBe(
    contextModule("calendar_helper"),
  );
});

test.each(["../escape", "invalid-role", "", "1invalid", "a".repeat(162)])(
  "invalid support scope %s cannot select a build directory",
  (scope) => {
    expect(() => contextModule(scope)).toThrow();
  },
);

test("optional document code and resources are excluded from core and UI products", () => {
  expect(supportProducts("EdithExtensionSupport")).toEqual([
    "EdithExtensionCore",
    "EdithExtensionSupport",
  ]);
  expect(supportProducts("EdithExtensionUI")).toEqual([
    "EdithExtensionCore",
    "EdithExtensionSupport",
    "EdithExtensionUI",
  ]);
  expect(supportProducts("EdithExtensionDocuments")).toEqual([
    "EdithExtensionCore",
    "EdithExtensionSupport",
    "EdithExtensionUI",
    "EdithExtensionDocuments",
  ]);
  expect(supportSourceInputs("EdithExtensionUI")).toContain(
    "Packages/EdithIcons/Sources",
  );
  expect(supportSourceInputs("EdithExtensionCore")).not.toContain(
    "Packages/EdithIcons/Sources",
  );
  expect(supportSourceInputs("EdithExtensionUI")).not.toContain(
    "Packages/ExtensionSupport/Sources/EdithExtensionDocuments",
  );
  expect(() => supportProducts("Invalid")).toThrow();
});

test("file browsing support builds on documents and gets private module names", () => {
  expect(supportProducts("EdithExtensionFiles")).toEqual([
    "EdithExtensionCore",
    "EdithExtensionSupport",
    "EdithExtensionUI",
    "EdithExtensionDocuments",
    "EdithExtensionFiles",
  ]);
  expect(supportSourceInputs("EdithExtensionFiles")).toContain(
    "Packages/ExtensionSupport/Sources/EdithExtensionFiles",
  );
  expect(supportSourceInputs("EdithExtensionDocuments")).not.toContain(
    "Packages/ExtensionSupport/Sources/EdithExtensionFiles",
  );
});

test("archive support stays separate from document rendering", () => {
  expect(supportProducts("EdithExtensionArchive")).toEqual([
    "EdithExtensionCore",
    "EdithExtensionSupport",
    "EdithExtensionUI",
    "EdithExtensionArchive",
  ]);
  expect(supportSourceInputs("EdithExtensionArchive")).not.toContain(
    "Packages/ExtensionSupport/Sources/EdithExtensionDocuments",
  );
});

test("terminal parser code belongs only to explicitly selected command products", () => {
  expect(supportProducts("EdithExtensionCommands")).toEqual([
    "EdithExtensionCore",
    "EdithExtensionSupport",
    "EdithExtensionUI",
    "EdithExtensionCommands",
  ]);
  expect(supportSourceInputs("EdithExtensionUI")).not.toContain(
    "Packages/ExtensionSupport/Sources/EdithExtensionCommands",
  );
  expect(supportSourceInputs("EdithExtensionCommands")).toContain(
    "Packages/ExtensionSupport/Licenses/swift-argument-parser-license.txt",
  );
});

test("composed products share one deterministic dependency closure", () => {
  const selection = ["EdithExtensionDocuments", "EdithExtensionCommands"];
  expect(supportProducts(selection)).toEqual([
    "EdithExtensionCore",
    "EdithExtensionSupport",
    "EdithExtensionUI",
    "EdithExtensionCommands",
    "EdithExtensionDocuments",
  ]);
  expect(supportProducts(selection.toReversed())).toEqual(
    supportProducts(selection),
  );
  expect(supportProducts([...selection, ...selection])).toEqual(
    supportProducts(selection),
  );
  expect(supportSourceInputs(selection)).toContain(
    "Packages/ExtensionSupport/Licenses/swift-argument-parser-license.txt",
  );
  expect(supportSourceInputs(selection)).not.toContain(
    "Packages/ExtensionSupport/Sources/EdithExtensionArchive",
  );
  expect(
    supportProducts(["EdithExtensionArchive", "EdithExtensionCommands"]),
  ).not.toContain("EdithExtensionDocuments");
  expect(() => supportProducts([])).toThrow();
  expect(() => supportProducts([["EdithExtensionUI"]])).toThrow();
  expect(() => supportProducts(["EdithExtensionUI", null])).toThrow();
});

test("parser defaults use the current error prefix without changing overrides", () => {
  const source =
    'import ArgumentParserToolInfo\n  public static var _errorPrefix: String {\n    "\\(_errorLabel): "\n  }\nstruct Command { static var _errorPrefix: String { "Fixture: " } }\n';
  expect(
    rewriteArgumentParserWarnings(
      source,
      "Parsable Types/ParsableArguments.swift",
    ),
  ).toBe(
    'import ArgumentParserToolInfo\n  public static var _errorPrefix: String {\n    "Error: "\n  }\nstruct Command { static var _errorPrefix: String { "Fixture: " } }\n',
  );
});

test("parser help maps single-argument callbacks to the current completion kind", () => {
  const source =
    "    case .customDeprecated(_):\n      self = .customDeprecated\n    case .custom(_):\n      self = .custom\n    case .customAsync(_):\n      self = .customAsync\n";
  expect(
    rewriteArgumentParserWarnings(source, "Usage/DumpHelpGenerator.swift"),
  ).toBe(
    "    case .customDeprecated(_):\n      self = .custom\n    case .custom(_):\n      self = .custom\n    case .customAsync(_):\n      self = .customAsync\n",
  );
});

test.each([
  "Parsable Types/ParsableArguments.swift",
  "Usage/DumpHelpGenerator.swift",
])(
  "private parser source migration rejects changed upstream shape %s",
  (path) => {
    expect(() =>
      rewriteArgumentParserWarnings("struct Changed {}", path),
    ).toThrow("Unexpected pinned ArgumentParser source");
  },
);

test("parser migration leaves other declarations and text unchanged", () => {
  const source =
    'import ArgumentParserToolInfo\nlet value = "_errorLabel customDeprecated"\n';
  expect(rewriteArgumentParserWarnings(source, "Other.swift")).toBe(
    'import ArgumentParserToolInfo\nlet value = "_errorLabel customDeprecated"\n',
  );
});

test("account code is an optional dependency isolated from the empty host products", () => {
  expect(supportProducts("EdithExtensionAccounts")).toEqual([
    "EdithExtensionCore",
    "EdithExtensionSupport",
    "EdithExtensionAccounts",
  ]);
  for (const product of ["EdithExtensionSupport", "EdithExtensionUI"]) {
    expect(supportProducts(product)).not.toContain("EdithExtensionAccounts");
    expect(supportSourceInputs(product)).not.toContain(
      "Packages/ExtensionSupport/Sources/EdithExtensionAccounts",
    );
  }
  const selection = ["EdithExtensionUI", "EdithExtensionAccounts"];
  expect(supportProducts(selection)).toEqual([
    "EdithExtensionCore",
    "EdithExtensionSupport",
    "EdithExtensionUI",
    "EdithExtensionAccounts",
  ]);
  expect(supportProducts(selection.toReversed())).toEqual(
    supportProducts(selection),
  );
  expect(supportSourceInputs(selection)).toContain(
    "Packages/ExtensionSupport/Sources/EdithExtensionAccounts",
  );
});

test("shared parser rewrite bytes belong only to command support source and cache inputs", () => {
  expect(supportSourceInputs("EdithExtensionCommands")).toContain(
    "scripts/argument-parser-source.mjs",
  );
  for (const product of [
    "EdithExtensionSupport",
    "EdithExtensionUI",
    "EdithExtensionAccounts",
  ])
    expect(supportSourceInputs(product)).not.toContain(
      "scripts/argument-parser-source.mjs",
    );
  const definitions = JSON.parse(
    readFileSync("Extensions/manifest.json", "utf8"),
  );
  const selected = planExtensionBuilds(definitions, [
    "scripts/argument-parser-source.mjs",
  ]).map(({ id }) => id);
  for (const owner of ["attention", "calendar", "herdr", "usage"])
    expect(selected).toContain(owner);
  for (const owner of ["keepAwake", "timeLapse", "blitztree"])
    expect(selected).not.toContain(owner);
});
