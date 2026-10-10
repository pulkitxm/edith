import { expect, test } from "bun:test";
import {
  nativeTaskLinkerFlags,
  presentationLinkerFlags,
} from "./build-extension-package.mjs";

test("only declared native task roles retain the fixed signed bundle entry", () => {
  const definition = {
    roles: { app: [], helper: [] },
    nativeTaskRoles: ["app"],
  };
  expect(nativeTaskLinkerFlags(definition, "app")).toEqual([
    "-Xlinker",
    "-exported_symbol",
    "-Xlinker",
    "_edith_extension_native_task",
  ]);
  expect(nativeTaskLinkerFlags(definition, "helper")).toEqual([]);
  expect(nativeTaskLinkerFlags({ roles: { app: [] } }, "app")).toEqual([]);
  for (const roles of [["missing"], ["app", "app"], "app"]) {
    expect(() =>
      nativeTaskLinkerFlags(
        { roles: { app: [] }, nativeTaskRoles: roles },
        "app",
      ),
    ).toThrow();
  }
});

test("UI support products export their scoped presentation factory", () => {
  for (const product of [
    "EdithExtensionUI",
    "EdithExtensionDocuments",
    "EdithExtensionArchive",
  ])
    expect(presentationLinkerFlags(product)).toEqual([
      "-Xlinker",
      "-exported_symbol",
      "-Xlinker",
      "_edith_extension_presentation_create",
    ]);
  for (const product of [undefined, "EdithExtensionSupport"])
    expect(presentationLinkerFlags(product)).toEqual([]);
  expect(() => presentationLinkerFlags("foreign")).toThrow();
});
