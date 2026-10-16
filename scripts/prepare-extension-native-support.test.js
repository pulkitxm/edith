import { expect, test } from "bun:test";
import { prepareNativeSupport } from "./prepare-extension-native-support.mjs";

const definition = {
  id: "attention",
  nativePackage: "Extensions/attention/NativeRuntime",
  nativeProduct: "AttentionNative",
  nativeSupportProduct: "EdithExtensionCommands",
};

test("native preparation uses one maintained private SDK scope", () => {
  const calls = [];
  const expected = {
    products: "/fixture/products",
    product: "private-static-product",
  };
  expect(
    prepareNativeSupport("/fixture", definition, (...arguments_) => {
      calls.push(arguments_);
      return expected;
    }),
  ).toBe(expected);
  expect(calls).toEqual([
    ["/fixture", "EdithExtensionCommands", "attention_native"],
  ]);
});

test("native preparation leaves non-consumers alone and supports complete product closures", () => {
  let count = 0;
  const build = () => {
    count += 1;
  };
  expect(
    prepareNativeSupport("/fixture", { id: "ordinary" }, build),
  ).toBeUndefined();
  expect(count).toBe(0);
  const selection = ["EdithExtensionDocuments", "EdithExtensionCommands"];
  prepareNativeSupport(
    "/fixture",
    { ...definition, nativeSupportProduct: selection },
    (_, product, scope) => {
      expect(product).toEqual(selection);
      expect(scope).toBe("attention_native");
      count += 1;
    },
  );
  expect(count).toBe(1);
});

test.each([
  { nativePackage: null },
  { nativePackage: "../foreign" },
  { nativeProduct: null },
  { id: "../escape" },
  { nativeSupportProduct: [] },
  { nativeSupportProduct: "foreign" },
])(
  "native preparation rejects invalid selection before building %j",
  (override) => {
    let called = false;
    expect(() =>
      prepareNativeSupport("/fixture", { ...definition, ...override }, () => {
        called = true;
      }),
    ).toThrow();
    expect(called).toBe(false);
  },
);
