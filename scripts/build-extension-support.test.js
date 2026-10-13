import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  rewriteArgumentParserSource,
  rewriteSupportImports,
  supportModules,
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

test("each extension role has independent Swift and Objective-C support types", () => {
  const first = supportModules("calendar_app");
  const second = supportModules("presenter_helper");
  const helper = supportModules("calendar_helper");
  expect(first.EdithExtensionSupport).not.toBe(second.EdithExtensionSupport);
  expect(first.EdithExtensionUI).not.toBe(helper.EdithExtensionUI);
  expect(Object.values(first)).not.toContain("EdithExtensionSupport");
});

test.each(["../escape", "invalid-role", "", "1invalid", "a".repeat(162)])(
  "invalid support scope %s cannot select a build directory",
  (scope) => {
    expect(() => supportModules(scope)).toThrow();
  },
);

test("only imports change when compiling private support copies", () => {
  const modules = supportModules("calendar_app");
  const source =
    'import Foundation\nimport EdithExtensionSupport\n@testable import EdithExtensionUI\nlet label = "EdithExtensionSupport"\n';
  expect(rewriteSupportImports(source, modules)).toBe(
    'import Foundation\nimport EdithExtensionSupport_calendar_app\n@testable import EdithExtensionUI_calendar_app\nlet label = "EdithExtensionSupport"\n',
  );
});

test("optional document code and resources are excluded from core and UI products", () => {
  expect(supportProducts("EdithExtensionSupport")).toEqual([
    "EdithExtensionSupport",
  ]);
  expect(supportProducts("EdithExtensionUI")).toEqual([
    "EdithExtensionSupport",
    "EdithExtensionUI",
  ]);
  expect(supportProducts("EdithExtensionDocuments")).toEqual([
    "EdithExtensionSupport",
    "EdithExtensionUI",
    "EdithExtensionDocuments",
  ]);
  expect(supportSourceInputs("EdithExtensionUI")).not.toContain(
    "Packages/ExtensionSupport/Sources/EdithExtensionDocuments",
  );
  expect(() => supportProducts("Invalid")).toThrow();
});

test("document imports also get private extension module names", () => {
  expect(
    rewriteSupportImports(
      "import EdithExtensionDocuments\n",
      supportModules("plugins_app"),
    ),
  ).toBe("import EdithExtensionDocuments_plugins_app\n");
});

test("archive support stays separate from document rendering", () => {
  expect(supportProducts("EdithExtensionArchive")).toEqual([
    "EdithExtensionSupport",
    "EdithExtensionUI",
    "EdithExtensionArchive",
  ]);
  expect(supportSourceInputs("EdithExtensionArchive")).not.toContain(
    "Packages/ExtensionSupport/Sources/EdithExtensionDocuments",
  );
  const modules = supportModules("latex_helper");
  expect(rewriteSupportImports("import EdithExtensionArchive\n", modules)).toBe(
    "import EdithExtensionArchive_latex_helper\n",
  );
});

test("archive dependency types are isolated from the host and other workers", () => {
  const first = supportModules("latex_app");
  const second = supportModules("downloads_app");
  expect(first.ZIPFoundation).not.toBe("ZIPFoundation");
  expect(first.ZIPFoundation).not.toBe(second.ZIPFoundation);
  expect(rewriteSupportImports("import ZIPFoundation\n", first)).toBe(
    "import ZIPFoundation\n",
  );
});

test("terminal parser code belongs only to explicitly selected command products", () => {
  expect(supportProducts("EdithExtensionCommands")).toEqual([
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
  const first = supportModules("calendar_app");
  const second = supportModules("database_app");
  expect(first.ArgumentParser).not.toBe(second.ArgumentParser);
  expect(first.ArgumentParserToolInfo).not.toBe(second.ArgumentParserToolInfo);
  expect(
    rewriteSupportImports(
      "import ArgumentParser\nimport EdithExtensionCommands\n",
      first,
    ),
  ).toBe(
    "import ArgumentParser_calendar_app\nimport EdithExtensionCommands_calendar_app\n",
  );
  expect(
    rewriteSupportImports(
      "@_implementationOnly import ArgumentParserToolInfo\n",
      first,
    ),
  ).toBe("@_implementationOnly import ArgumentParserToolInfo_calendar_app\n");
});

test("composed products share one deterministic dependency closure", () => {
  const selection = ["EdithExtensionDocuments", "EdithExtensionCommands"];
  expect(supportProducts(selection)).toEqual([
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

test("private parser targets rewrite Swift 6 internal imports without alias flags", () => {
  expect(
    rewriteSupportImports(
      "internal import ArgumentParserToolInfo\n",
      supportModules("latex_app"),
    ),
  ).toBe("internal import ArgumentParserToolInfo_latex_app\n");
});

test("private parser defaults use the current error prefix without changing overrides", () => {
  const source =
    'import ArgumentParserToolInfo\n  public static var _errorPrefix: String {\n    "\\(_errorLabel): "\n  }\nstruct Command { static var _errorPrefix: String { "Fixture: " } }\n';
  expect(
    rewriteArgumentParserSource(
      source,
      supportModules("fixture_app"),
      "Parsable Types/ParsableArguments.swift",
    ),
  ).toBe(
    'import ArgumentParserToolInfo_fixture_app\n  public static var _errorPrefix: String {\n    "Error: "\n  }\nstruct Command { static var _errorPrefix: String { "Fixture: " } }\n',
  );
});

test("private parser help maps single-argument callbacks to the current completion kind", () => {
  const source =
    "    case .customDeprecated(_):\n      self = .customDeprecated\n    case .custom(_):\n      self = .custom\n    case .customAsync(_):\n      self = .customAsync\n";
  expect(
    rewriteArgumentParserSource(
      source,
      supportModules("fixture_app"),
      "Usage/DumpHelpGenerator.swift",
    ),
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
      rewriteArgumentParserSource(
        "struct Changed {}",
        supportModules("fixture_app"),
        path,
      ),
    ).toThrow("Unexpected pinned ArgumentParser source");
  },
);

test("private parser migration leaves other declarations and text unchanged", () => {
  const source =
    'import ArgumentParserToolInfo\nlet value = "_errorLabel customDeprecated"\n';
  expect(
    rewriteArgumentParserSource(
      source,
      supportModules("fixture_app"),
      "Other.swift",
    ),
  ).toBe(
    'import ArgumentParserToolInfo_fixture_app\nlet value = "_errorLabel customDeprecated"\n',
  );
});

test("account code is an optional dependency isolated from the empty host products", () => {
  expect(supportProducts("EdithExtensionAccounts")).toEqual([
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

test("account imports remain private to each independently loaded extension", () => {
  const source =
    '@testable import EdithExtensionAccounts\nlet text = "EdithExtensionAccounts"\n';
  expect(rewriteSupportImports(source, supportModules("herdr_app"))).toBe(
    '@testable import EdithExtensionAccounts_herdr_app\nlet text = "EdithExtensionAccounts"\n',
  );
  expect(rewriteSupportImports(source, supportModules("usage_app"))).toBe(
    '@testable import EdithExtensionAccounts_usage_app\nlet text = "EdithExtensionAccounts"\n',
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
