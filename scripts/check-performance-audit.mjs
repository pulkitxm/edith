import { existsSync, readFileSync } from "node:fs";

const allowedStatuses = new Set(["instrumented", "protected"]);

export function validatePerformanceAudit(audit, root = ".") {
  const failures = [];
  if (audit.schemaVersion !== 1) failures.push("schemaVersion must be 1");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(audit.capturedAt ?? "")) {
    failures.push("capturedAt must use YYYY-MM-DD");
  }
  const required = new Set(audit.requiredAreas ?? []);
  const scenarios = audit.scenarios ?? [];
  const seen = new Set();
  for (const scenario of scenarios) {
    const prefix = scenario.area || "unnamed";
    if (!required.has(scenario.area))
      failures.push(`${prefix}: area is not required`);
    if (seen.has(scenario.area)) failures.push(`${prefix}: duplicate scenario`);
    seen.add(scenario.area);
    if (!allowedStatuses.has(scenario.status))
      failures.push(`${prefix}: invalid status`);
    for (const field of ["finding", "measurement", "regressionProperty"]) {
      if (
        typeof scenario[field] !== "string" ||
        scenario[field].trim() === ""
      ) {
        failures.push(`${prefix}: ${field} is required`);
      }
    }
    if (!Array.isArray(scenario.evidence) || scenario.evidence.length === 0) {
      failures.push(`${prefix}: evidence is required`);
      continue;
    }
    for (const evidence of scenario.evidence) {
      const path = `${root}/${evidence.path}`;
      if (!existsSync(path)) {
        failures.push(`${prefix}: missing evidence file ${evidence.path}`);
        continue;
      }
      if (!readFileSync(path, "utf8").includes(evidence.contains)) {
        failures.push(`${prefix}: evidence not found in ${evidence.path}`);
      }
    }
  }
  for (const area of required) {
    if (!seen.has(area)) failures.push(`${area}: scenario is missing`);
  }
  if (seen.size !== required.size)
    failures.push("scenario and required area counts differ");
  return failures;
}

if (import.meta.main) {
  const audit = JSON.parse(readFileSync("performance/audit.json", "utf8"));
  const failures = validatePerformanceAudit(audit);
  if (failures.length > 0) {
    for (const failure of failures) process.stderr.write(`${failure}\n`);
    process.exit(1);
  }
  process.stdout.write(
    `performance audit: ${audit.scenarios.length} areas verified\n`,
  );
}
