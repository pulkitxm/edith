import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

export function checkDatabaseSizes(files, budget) {
  return files.flatMap(({ path, text }) => {
    const lines = text.trimEnd().split("\n").length;
    const limit = budget.exceptions[path] ?? budget.maxLines;
    return lines > limit ? [`${path}: ${lines} lines exceeds ${limit}`] : [];
  });
}

function sourceFiles(root, directory = root) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return sourceFiles(root, path);
    return entry.name.endsWith(".swift")
      ? [{ path: relative(root, path), text: readFileSync(path, "utf8") }]
      : [];
  });
}

if (import.meta.main) {
  const budget = JSON.parse(
    readFileSync("performance/baselines/database-source.json", "utf8"),
  );
  const files = sourceFiles("Packages/Edith/Sources/Edith/Features/Database");
  const failures = checkDatabaseSizes(files, budget);
  if (failures.length) {
    console.error(failures.join("\n"));
    process.exitCode = 1;
  } else {
    console.log(`database source budget: ${files.length} files verified`);
  }
}
