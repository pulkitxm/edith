import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

export function buildExtensionSupport(root, product) {
  if (!["EdithExtensionSupport", "EdithExtensionUI"].includes(product))
    throw new Error("Unknown extension support product");
  const directory = resolve(root, "Packages/ExtensionSupport");
  const developer =
    process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer";
  const environment = { ...process.env, DEVELOPER_DIR: developer };
  execFileSync(
    "swift",
    [
      "build",
      "--package-path",
      directory,
      "--build-system",
      "native",
      "--configuration",
      "release",
      "--jobs",
      "2",
      "--product",
      product,
      "-Xswiftc",
      "-plugin-path",
      "-Xswiftc",
      `${developer}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins`,
    ],
    { env: environment, stdio: "inherit" },
  );
  return execFileSync(
    "swift",
    [
      "build",
      "--package-path",
      directory,
      "--build-system",
      "native",
      "--configuration",
      "release",
      "--show-bin-path",
    ],
    { env: environment, encoding: "utf8" },
  ).trim();
}
