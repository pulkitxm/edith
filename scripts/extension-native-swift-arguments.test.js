import { expect, test } from "bun:test";
import { nativeSwiftPackageArguments } from "./build-extension-package.mjs";

test("native package builds admit the selected Xcode macro plugins as distinct compiler arguments", () => {
  const args = nativeSwiftPackageArguments(
    "/fixture root",
    {
      nativePackage: "Extensions/sample/NativeRuntime",
      nativeProduct: "SampleNative",
    },
    "/Applications/Xcode 27.app/Contents/Developer",
  );
  const flag = args.indexOf("-plugin-path");
  expect(args.slice(flag - 1, flag + 3)).toEqual([
    "-Xswiftc",
    "-plugin-path",
    "-Xswiftc",
    "/Applications/Xcode 27.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins",
  ]);
  expect(args[args.indexOf("--package-path") + 1]).toBe(
    "/fixture root/Extensions/sample/NativeRuntime",
  );
  expect(args[args.indexOf("--product") + 1]).toBe("SampleNative");
  expect(args[args.indexOf("--configuration") + 1]).toBe("release");
  expect(args).toContain("--force-resolved-versions");
});
