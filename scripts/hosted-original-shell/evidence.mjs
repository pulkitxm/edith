import assert from "node:assert/strict";

export const journeyImageNames = [
  "marketplace-installed-calendar.png",
  "storage-distribution.png",
];

export function validateJourneyImage(name, bytes, outcome) {
  assert.equal(outcome.actualJourneyValidated, true);
  assert.equal(outcome.outcome, "passed");
  assert(journeyImageNames.includes(name));
  assert(Buffer.isBuffer(bytes));
  assert(bytes.length >= 33 && bytes.length <= 8_388_608);
  assert(
    bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])),
  );
  assert.equal(bytes.readUInt32BE(8), 13);
  assert.equal(bytes.toString("ascii", 12, 16), "IHDR");
  const width = bytes.readUInt32BE(16);
  const height = bytes.readUInt32BE(20);
  assert(width > 0 && width <= 16_384 && height > 0 && height <= 16_384);
  assert(width * height <= 134_217_728);
  return { name, bytes: bytes.length, width, height };
}
