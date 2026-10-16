import assert from "node:assert/strict";
import { prepareHostRemoteFixture } from "./prepare-host-remote-fixture.mjs";

const [extensionID, directory, sourceHost, identifier, sourceExecutable] =
  process.argv.slice(2);
assert(
  extensionID && directory && sourceHost && identifier,
  "Usage: prepare-managed-shipping-fixture.mjs extension directory frozen-host fixture-identifier [fixture-executable]",
);
console.log(
  JSON.stringify(
    await prepareHostRemoteFixture({
      root: process.cwd(),
      extensionID,
      directory,
      sourceHost,
      identifier,
      sourceExecutable,
    }),
  ),
);
