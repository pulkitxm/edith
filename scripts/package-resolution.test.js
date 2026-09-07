import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const readPins = (path) =>
  new Map(
    JSON.parse(readFileSync(new URL(path, import.meta.url), "utf8")).pins.map(
      (pin) => [pin.identity, pin.state],
    ),
  );

test("the packaged application and package tests use identical dependency revisions", () => {
  const packagePins = readPins("../Packages/Edith/Package.resolved");
  const applicationPins = readPins(
    "../edth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
  );
  expect([...applicationPins.keys()].sort()).toEqual(
    [...packagePins.keys()].sort(),
  );
  for (const [identity, state] of packagePins) {
    expect(applicationPins.get(identity), identity).toEqual(state);
  }
});
