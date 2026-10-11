export function parseSystemVersion(value) {
  if (
    typeof value !== "string" ||
    !/^(0|[1-9][0-9]{0,9})\.(0|[1-9][0-9]{0,9})\.(0|[1-9][0-9]{0,9})$/.test(value)
  )
    throw new Error("Invalid system version");
  const parts = value.split(".").map(Number);
  if (parts.some((part) => part > 2147483647))
    throw new Error("Invalid system version");
  return parts;
}

export function compareSystemVersions(left, right) {
  const a = parseSystemVersion(left);
  const b = parseSystemVersion(right);
  for (let index = 0; index < 3; index++) {
    if (a[index] !== b[index]) return Math.sign(a[index] - b[index]);
  }
  return 0;
}

export function validateMinimumSystemVersion(value) {
  if (compareSystemVersions(value, "14.0.0") < 0)
    throw new Error("Invalid minimum system version");
  return value;
}
