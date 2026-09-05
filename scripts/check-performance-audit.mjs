import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const allowedStatuses = new Set(["instrumented", "protected"]);
const requiredStructuralRules = new Set([
  "main-actor-blocking-io",
  "unowned-detached-task",
  "raw-process-launch",
  "unsafe-process-lifecycle",
  "unbounded-process-output",
  "unbounded-task-group",
  "stale-task-publication",
  "main-actor-projection-chain",
]);

const normalizeLine = (source, index) => {
  const start = source.lastIndexOf("\n", index - 1) + 1;
  const end = source.indexOf("\n", index);
  return source
    .slice(start, end < 0 ? source.length : end)
    .trim()
    .replaceAll(/\s+/g, " ");
};

const lineNumber = (source, index) => source.slice(0, index).split("\n").length;

const maskSwift = (source) => {
  const chars = source.split("");
  let index = 0;
  let blockDepth = 0;
  let quote = null;
  while (index < chars.length) {
    if (blockDepth > 0) {
      if (chars[index] === "/" && chars[index + 1] === "*") {
        chars[index] = " ";
        chars[index + 1] = " ";
        blockDepth += 1;
        index += 2;
      } else if (chars[index] === "*" && chars[index + 1] === "/") {
        chars[index] = " ";
        chars[index + 1] = " ";
        blockDepth -= 1;
        index += 2;
      } else {
        if (chars[index] !== "\n") chars[index] = " ";
        index += 1;
      }
      continue;
    }
    if (quote !== null) {
      const triple = quote === 3;
      const closes = triple
        ? chars[index] === '"' &&
          chars[index + 1] === '"' &&
          chars[index + 2] === '"'
        : chars[index] === '"' && chars[index - 1] !== "\\";
      if (closes) {
        const width = triple ? 3 : 1;
        for (let offset = 0; offset < width; offset += 1) {
          chars[index + offset] = " ";
        }
        quote = null;
        index += width;
      } else {
        if (chars[index] !== "\n") chars[index] = " ";
        index += 1;
      }
      continue;
    }
    if (chars[index] === "/" && chars[index + 1] === "/") {
      while (index < chars.length && chars[index] !== "\n") {
        chars[index] = " ";
        index += 1;
      }
      continue;
    }
    if (chars[index] === "/" && chars[index + 1] === "*") {
      chars[index] = " ";
      chars[index + 1] = " ";
      blockDepth = 1;
      index += 2;
      continue;
    }
    if (chars[index] === '"') {
      const triple = chars[index + 1] === '"' && chars[index + 2] === '"';
      const width = triple ? 3 : 1;
      for (let offset = 0; offset < width; offset += 1) {
        chars[index + offset] = " ";
      }
      quote = width;
      index += width;
      continue;
    }
    index += 1;
  }
  return chars.join("");
};

const closingBrace = (source, opening) => {
  let depth = 0;
  for (let index = opening; index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    if (source[index] === "}") depth -= 1;
    if (depth === 0) return index;
  }
  return source.length - 1;
};

const closingDelimiter = (source, opening, left, right) => {
  let depth = 0;
  for (let index = opening; index < source.length; index += 1) {
    if (source[index] === left) depth += 1;
    if (source[index] === right) depth -= 1;
    if (depth === 0) return index;
  }
  return source.length - 1;
};

const declarationRanges = (masked, prefix) => {
  const ranges = [];
  const declaration = new RegExp(
    `${prefix}\\s+(?:(?:@\\w+(?:\\([^)]*\\))?|public|package|internal|private|fileprivate|open|final|static|class|mutating|nonmutating)\\s+)*(?:class|struct|enum|actor|extension|func|init|subscript|var)\\b`,
    "g",
  );
  for (const match of masked.matchAll(declaration)) {
    const opening = masked.indexOf("{", match.index + match[0].length);
    if (opening < 0 || opening - match.index > 600) continue;
    ranges.push([opening, closingBrace(masked, opening)]);
  }
  return ranges;
};

const callableRanges = (masked) => {
  const ranges = [];
  const callable =
    /(?:^|\n)\s*(?:(?:@\w+(?:\([^)]*\))?|public|package|internal|private|fileprivate|open|final|static|class|mutating|nonmutating|nonisolated|override)\s+)*(?:func\b|init\b|deinit\b)[^{]{0,1_000}\{/gm;
  for (const match of masked.matchAll(callable)) {
    const opening = masked.indexOf("{", match.index);
    ranges.push([opening, closingBrace(masked, opening)]);
  }
  return ranges;
};

const containsIndex = (ranges, index) =>
  ranges.some(([start, end]) => start < index && index < end);

const enclosingRange = (ranges, index) =>
  ranges
    .filter(([start, end]) => start < index && index < end)
    .sort(([left], [right]) => right - left)[0];

const closureRange = (masked, index, limit = 800) => {
  const opening = masked.indexOf("{", index);
  if (opening < 0 || opening - index > limit) return null;
  return [opening, closingBrace(masked, opening)];
};

const detachedExpression = (masked, index) => {
  let cursor = index + "Task.detached".length;
  while (/\s/.test(masked[cursor])) cursor += 1;
  if (masked[cursor] === "{") {
    const end = closingBrace(masked, cursor);
    return { closure: [cursor, end], end };
  }
  if (masked[cursor] !== "(") return { closure: null, end: cursor };
  const closing = closingDelimiter(masked, cursor, "(", ")");
  const opening = masked.indexOf("{", cursor);
  const inlineClosure = opening >= 0 && opening < closing;
  let after = closing + 1;
  while (/\s/.test(masked[after])) after += 1;
  if (inlineClosure)
    return { closure: [opening, closingBrace(masked, opening)], end: closing };
  if (masked[after] === "{") {
    const end = closingBrace(masked, after);
    return { closure: [after, end], end };
  }
  return { closure: null, end: closing };
};

const taskOwnerIsCancelled = (masked, owner, indexed) => {
  const subscript = indexed ? "\\s*\\[[^\\]\\n]+\\]" : "";
  if (
    new RegExp(`\\b${owner}${subscript}\\s*\\??\\.cancel\\s*\\(`).test(masked)
  )
    return true;
  if (!indexed) return false;
  const loops = new RegExp(
    `\\bfor\\s+(\\w+)\\s+in\\s+(?:self\\s*\\.\\s*)?${owner}\\.values\\s*\\{`,
    "g",
  );
  for (const match of masked.matchAll(loops)) {
    const opening = masked.indexOf("{", match.index);
    const body = masked.slice(opening + 1, closingBrace(masked, opening));
    if (new RegExp(`\\b${match[1]}\\s*\\.cancel\\s*\\(`).test(body))
      return true;
  }
  return false;
};

const addViolation = (violations, rule, path, source, index) => {
  violations.push({
    rule,
    path,
    line: lineNumber(source, index),
    source: normalizeLine(source, index),
  });
};

export function findPerformanceViolations(source, path = "fixture.swift") {
  const violations = [];
  const masked = maskSwift(source);
  const mainActorRanges = declarationRanges(masked, "@MainActor");
  const nonisolatedRanges = declarationRanges(masked, "nonisolated");
  const functionRanges = callableRanges(masked);
  const detachedRanges = [];

  for (const match of masked.matchAll(/\bTask\.detached\b/g)) {
    const expression = detachedExpression(masked, match.index);
    if (expression.closure) detachedRanges.push(expression.closure);
    const assignment = masked
      .slice(Math.max(0, match.index - 160), match.index)
      .match(
        /(?:let|var)?\s*([A-Za-z_]\w*)\s*(\[[^\]\n]+\])?\s*=\s*(?:try\s+)?(?:await\s+)?$/,
      );
    const awaited =
      /(?:try\s+)?await\s*$/.test(
        masked.slice(Math.max(0, match.index - 40), match.index),
      ) && /^\s*\.value\b/.test(masked.slice(expression.end + 1));
    const returned = /return\s+(?:try\s+)?(?:await\s+)?$/.test(
      masked.slice(Math.max(0, match.index - 40), match.index),
    );
    const owned =
      assignment &&
      taskOwnerIsCancelled(masked, assignment[1], Boolean(assignment[2]));
    if (!awaited && !returned && !owned) {
      addViolation(
        violations,
        "unowned-detached-task",
        path,
        source,
        match.index,
      );
    }
  }

  for (const match of masked.matchAll(/\bProcess\s*\(\s*\)/g)) {
    addViolation(violations, "raw-process-launch", path, source, match.index);
    const functionRange = enclosingRange(functionRanges, match.index);
    const start = functionRange?.[0] ?? Math.max(0, match.index - 3_000);
    const end =
      functionRange?.[1] ?? Math.min(masked.length, match.index + 3_000);
    const lifecycle = source.slice(start, end);
    const bounded =
      /\b(?:timeout|deadline|timeLimit)\b|\.asyncAfter\s*\(|wait\s*\(\s*timeout\s*:/i.test(
        lifecycle,
      );
    const cancellable =
      /withTaskCancellationHandler|Task\.isCancelled|\.terminate\s*\(|SIGTERM/.test(
        lifecycle,
      );
    const escalatesGroup =
      /SIGKILL|killpg|kill\s*\(\s*-\s*|kill -KILL -|processGroup/i.test(
        lifecycle,
      );
    if (!bounded || !cancellable || !escalatesGroup) {
      addViolation(
        violations,
        "unsafe-process-lifecycle",
        path,
        source,
        match.index,
      );
    }
  }

  for (const match of masked.matchAll(/\.readDataToEndOfFile\s*\(\s*\)/g)) {
    const line = normalizeLine(source, match.index);
    if (!line.includes("FileHandle.standardInput")) {
      addViolation(
        violations,
        "unbounded-process-output",
        path,
        source,
        match.index,
      );
    }
  }

  const blockingPatterns = [
    /\bData\s*\(\s*contentsOf\s*:/g,
    /\bString\s*\(\s*contentsOf\s*:/g,
    /\.contentsOfDirectory\s*\(/g,
    /\.attributesOfItem\s*\(/g,
    /\.readDataToEndOfFile\s*\(/g,
    /\.readData\s*\(\s*ofLength\s*:/g,
    /\.waitUntilExit\s*\(/g,
    /\.executeAndReturnError\s*\(/g,
    /\bCGWindowListCopyWindowInfo\s*\(/g,
  ];
  for (const pattern of blockingPatterns) {
    for (const match of masked.matchAll(pattern)) {
      if (
        containsIndex(mainActorRanges, match.index) &&
        !containsIndex(nonisolatedRanges, match.index) &&
        !containsIndex(detachedRanges, match.index)
      ) {
        addViolation(
          violations,
          "main-actor-blocking-io",
          path,
          source,
          match.index,
        );
      }
    }
  }

  const loopRanges = [];
  const taskGroupRanges = [];
  for (const match of masked.matchAll(/\bwith(?:Throwing)?TaskGroup\b/g)) {
    const range = closureRange(masked, match.index);
    if (range) taskGroupRanges.push(range);
  }
  for (const match of masked.matchAll(/\bfor\b[^{}]{0,500}\{/g)) {
    const opening = masked.indexOf("{", match.index);
    loopRanges.push([opening, closingBrace(masked, opening), match.index]);
  }
  for (const [opening, end, start] of loopRanges) {
    const body = masked.slice(opening, end);
    if (!/\bgroup\.addTask\s*[({]/.test(body)) continue;
    const taskGroup = enclosingRange(taskGroupRanges, start);
    const context = taskGroup
      ? masked.slice(taskGroup[0], taskGroup[1])
      : masked.slice(
          Math.max(0, start - 1_500),
          Math.min(masked.length, end + 1_500),
        );
    const fixedRange =
      /\bfor\b[^\n{]*\b(?:allCases|supportedShells|0\s*\.\.<\s*\d+)/.test(
        masked.slice(start, opening),
      );
    const boundedPrefix = /\bfor\b[^\n{]*\.prefix\s*\(/.test(
      masked.slice(start, opening),
    );
    const rollingWindow =
      /\bgroup\.next\s*\(/.test(context) &&
      /\b(?:limit|concurr|parallel|initialCount|max\w*Count|probeLimit)\b/i.test(
        context,
      );
    if (!fixedRange && !boundedPrefix && !rollingWindow) {
      addViolation(violations, "unbounded-task-group", path, source, start);
    }
  }

  for (const match of masked.matchAll(
    /\b([A-Za-z_]\w*Task)\s*=\s*Task\s*(?!\.detached)[^{]{0,300}\{/g,
  )) {
    const range = closureRange(masked, match.index);
    if (!range) continue;
    const [opening, end] = range;
    const body = masked.slice(opening + 1, end);
    if (!/\bawait\b/.test(body)) continue;
    const ownerRange = enclosingRange(functionRanges, match.index);
    const owner = ownerRange
      ? masked.slice(ownerRange[0], match.index)
      : masked.slice(Math.max(0, match.index - 2_000), match.index);
    const cancellation = new RegExp(
      `\\b${match[1]}\\s*\\??\\.cancel\\s*\\(`,
    ).test(owner);
    const lastAwait = body.lastIndexOf("await");
    const publication = body
      .slice(lastAwait)
      .match(/(?:self\s*\??\s*\.)?\b[A-Za-z_]\w*\s*=(?!=)\s*/);
    const guarded =
      /Task\.isCancelled|Task\.checkCancellation|\bgeneration\b\s*==|==\s*\w*Generation\b|CancellationError/.test(
        body.slice(
          lastAwait,
          publication ? lastAwait + publication.index : body.length,
        ),
      );
    const replacementGuard = owner.match(new RegExp(
      `\\bguard\\s+${match[1]}\\s*==\\s*nil\\s+else\\s*\\{[^{}]*\\breturn\\s*\\}`,
    ));
    const refusesReplacement = replacementGuard !== null
      && !/\bawait\b/.test(owner.slice(replacementGuard.index + replacementGuard[0].length));
    if (publication && ((!cancellation && !refusesReplacement) || !guarded)) {
      addViolation(
        violations,
        "stale-task-publication",
        path,
        source,
        match.index,
      );
    }
  }

  const projection = /\.(?:map|filter|compactMap|sorted|reduce)\b/g;
  for (const range of mainActorRanges) {
    const actorSource = masked.slice(range[0], range[1]);
    for (const match of actorSource.matchAll(projection)) {
      const index = range[0] + match.index;
      if (
        containsIndex(detachedRanges, index) ||
        containsIndex(nonisolatedRanges, index)
      )
        continue;
      const prefix = masked.slice(Math.max(range[0], index - 200), index);
      const window = masked.slice(index, Math.min(range[1], index + 500));
      const unboundedSort =
        match[0] === ".sorted" &&
        !/\.prefix\s*\([^)]*\)\s*$/.test(prefix) &&
        !/\.(?:allCases|supportedShells)\s*$/.test(prefix);
      if (unboundedSort || [...window.matchAll(projection)].length > 1) {
        addViolation(
          violations,
          "main-actor-projection-chain",
          path,
          source,
          index,
        );
      }
    }
  }

  return violations;
}

const git = (root, commandArguments) =>
  execFileSync("git", ["-C", root, ...commandArguments], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();

const gitResult = (root, commandArguments) => {
  try {
    return git(root, commandArguments);
  } catch {
    return null;
  }
};

const resolvePerformanceBase = (root, explicitBase) => {
  const candidates = [
    explicitBase,
    process.env.PERFORMANCE_BASE,
    process.env.GITHUB_BASE_REF
      ? `origin/${process.env.GITHUB_BASE_REF}`
      : null,
  ].filter((candidate) => candidate && !/^0+$/.test(candidate));
  for (const candidate of candidates) {
    if (gitResult(root, ["cat-file", "-e", `${candidate}^{commit}`]) !== null) {
      return candidate;
    }
  }
  const mainBase = gitResult(root, ["merge-base", "origin/main", "HEAD"]);
  if (mainBase) return mainBase;
  return gitResult(root, ["rev-parse", "HEAD"]);
};

const changedSwiftFiles = (root, base, roots) => {
  const records = new Map();
  const status = gitResult(root, [
    "diff",
    "--name-status",
    "--find-renames",
    base,
    "--",
    ...roots,
  ]);
  for (const line of status?.split("\n") ?? []) {
    if (!line) continue;
    const [kind, first, second] = line.split("\t");
    const path = second ?? first;
    if (!path?.endsWith(".swift") || kind.startsWith("D")) continue;
    records.set(path, {
      currentPath: path,
      basePath: kind.startsWith("R") ? first : path,
    });
  }
  const untracked = gitResult(root, [
    "ls-files",
    "--others",
    "--exclude-standard",
    "--",
    ...roots,
  ]);
  for (const path of untracked?.split("\n") ?? []) {
    if (path.endsWith(".swift"))
      records.set(path, { currentPath: path, basePath: null });
  }
  return [...records.values()];
};

const violationCounts = (violations) => {
  const counts = new Map();
  for (const violation of violations) {
    counts.set(violation.rule, (counts.get(violation.rule) ?? 0) + 1);
  }
  return counts;
};

export function validatePerformanceChanges(
  audit,
  { root = ".", base: explicitBase } = {},
) {
  const enforcement = audit.structuralEnforcement;
  if (!enforcement) return ["structuralEnforcement is required"];
  const base = resolvePerformanceBase(root, explicitBase);
  if (!base) return ["performance comparison base could not be resolved"];
  const failures = [];
  for (const { currentPath, basePath } of changedSwiftFiles(
    root,
    base,
    enforcement.sourceRoots,
  )) {
    const currentSource = readFileSync(`${root}/${currentPath}`, "utf8");
    const baseSource = basePath
      ? (gitResult(root, ["show", `${base}:${basePath}`]) ?? "")
      : "";
    const current = findPerformanceViolations(currentSource, currentPath);
    const previousCounts = violationCounts(
      findPerformanceViolations(baseSource, basePath ?? currentPath),
    );
    const currentCounts = violationCounts(current);
    for (const rule of requiredStructuralRules) {
      const previous = previousCounts.get(rule) ?? 0;
      const next = currentCounts.get(rule) ?? 0;
      if (next <= previous) continue;
      const remainingPrevious = new Map();
      for (const violation of findPerformanceViolations(
        baseSource,
        basePath ?? currentPath,
      )) {
        if (violation.rule !== rule) continue;
        remainingPrevious.set(
          violation.source,
          (remainingPrevious.get(violation.source) ?? 0) + 1,
        );
      }
      const examples = current
        .filter((violation) => violation.rule === rule)
        .filter((violation) => {
          const remaining = remainingPrevious.get(violation.source) ?? 0;
          if (remaining === 0) return true;
          remainingPrevious.set(violation.source, remaining - 1);
          return false;
        })
        .slice(0, next - previous);
      for (const violation of examples) {
        failures.push(
          `${violation.path}:${violation.line}: ${rule}: ${violation.source || "unsafe structural form"}`,
        );
      }
    }
  }
  return failures;
}

export function validatePerformanceAudit(audit, root = ".") {
  const failures = [];
  if (audit.schemaVersion !== 1) failures.push("schemaVersion must be 1");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(audit.capturedAt ?? "")) {
    failures.push("capturedAt must use YYYY-MM-DD");
  }
  const enforcement = audit.structuralEnforcement;
  if (
    !enforcement ||
    !Array.isArray(enforcement.sourceRoots) ||
    enforcement.sourceRoots.length === 0
  ) {
    failures.push("structuralEnforcement.sourceRoots is required");
  }
  const structuralRules = new Set(enforcement?.rules ?? []);
  for (const rule of requiredStructuralRules) {
    if (!structuralRules.has(rule))
      failures.push(`structural rule is missing: ${rule}`);
  }
  for (const rule of structuralRules) {
    if (!requiredStructuralRules.has(rule))
      failures.push(`structural rule is unknown: ${rule}`);
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
  const failures = [
    ...validatePerformanceAudit(audit),
    ...validatePerformanceChanges(audit),
  ];
  if (failures.length > 0) {
    for (const failure of failures) process.stderr.write(`${failure}\n`);
    process.exit(1);
  }
  process.stdout.write(
    `performance audit: ${audit.scenarios.length} areas verified\n`,
  );
}
