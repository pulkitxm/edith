import { expect, test } from "bun:test";
import {
  rewriteSupportImports,
  supportModules,
  supportProducts,
  supportSourceInputs,
} from "./build-extension-support.mjs";

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
