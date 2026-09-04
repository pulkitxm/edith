import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  findPerformanceViolations,
  validatePerformanceAudit,
  validatePerformanceChanges,
} from "./check-performance-audit.mjs";

const audit = JSON.parse(readFileSync("performance/audit.json", "utf8"));

test("the performance audit covers every required area with live evidence", () => {
  expect(validatePerformanceAudit(audit)).toEqual([]);
});

test("the performance audit rejects missing coverage", () => {
  const incomplete = {
    ...audit,
    scenarios: audit.scenarios.filter(({ area }) => area !== "slowNetwork"),
  };

  expect(validatePerformanceAudit(incomplete)).toContain(
    "slowNetwork: scenario is missing",
  );
});

test("hostile actor work and process capture are rejected", () => {
  const source = `
    @MainActor
    final class Model {
      func refresh() {
        let process = Process()
        process.waitUntilExit()
        let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/data"))
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        let windows = CGWindowListCopyWindowInfo([], 0)
      }
    }
  `;

  const rules = findPerformanceViolations(source).map(({ rule }) => rule);

  expect(rules).toContain("raw-process-launch");
  expect(rules).toContain("unsafe-process-lifecycle");
  expect(rules).toContain("unbounded-process-output");
  expect(
    rules.filter((rule) => rule === "main-actor-blocking-io"),
  ).toHaveLength(4);
});

test("bounded cancellation and group escalation satisfy process lifecycle analysis", () => {
  const source = `
    func run(timeout: Duration) async {
      let process = Process()
      await withTaskCancellationHandler {
        await wait(process, timeout: timeout)
      } onCancel: {
        process.terminate()
        kill(-process.processIdentifier, SIGKILL)
      }
    }
  `;

  const rules = findPerformanceViolations(source).map(({ rule }) => rule);

  expect(rules).toContain("raw-process-launch");
  expect(rules).not.toContain("unsafe-process-lifecycle");
});

test("awaited detached work keeps blocking input outside the actor", () => {
  const source = `
    @MainActor
    final class Model {
      func refresh() async throws {
        let value = try await Task.detached {
          try Data(contentsOf: URL(fileURLWithPath: "/tmp/data"))
        }.value
        rows = [value]
      }
    }
  `;

  const rules = findPerformanceViolations(source).map(({ rule }) => rule);

  expect(rules).not.toContain("main-actor-blocking-io");
  expect(rules).not.toContain("unowned-detached-task");
});

test("detached operation arguments do not absorb a later actor scope", () => {
  const source = `
    @MainActor
    final class Model {
      func calculate(operation: @escaping @Sendable () -> Int) async {
        value = await Task.detached(priority: .utility, operation: operation).value
        let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/data"))
      }
    }
  `;

  const rules = findPerformanceViolations(source).map(({ rule }) => rule);

  expect(rules).not.toContain("unowned-detached-task");
  expect(rules).toContain("main-actor-blocking-io");
});

test("fire-and-forget detached work needs ownership and cancellation", () => {
  const unsafe = `
    func start() {
      Task.detached { await poll() }
    }
  `;
  const owned = `
    var pollTask: Task<Void, Never>?
    func start() {
      pollTask?.cancel()
      pollTask = Task.detached { await poll() }
    }
  `;

  expect(findPerformanceViolations(unsafe).map(({ rule }) => rule)).toContain(
    "unowned-detached-task",
  );
  expect(
    findPerformanceViolations(owned).map(({ rule }) => rule),
  ).not.toContain("unowned-detached-task");
});

test("task-group fan-out requires a fixed set or rolling bound", () => {
  const unsafe = `
    await withTaskGroup(of: Item.self) { group in
      for item in remoteItems {
        group.addTask { await load(item) }
      }
    }
  `;
  const bounded = `
    await withTaskGroup(of: Item.self) { group in
      let initialCount = min(remoteLimit, remoteItems.count)
      for item in remoteItems.prefix(initialCount) {
        group.addTask { await load(item) }
      }
      while let result = await group.next() {
        consume(result)
      }
    }
  `;

  expect(findPerformanceViolations(unsafe).map(({ rule }) => rule)).toContain(
    "unbounded-task-group",
  );
  expect(
    findPerformanceViolations(bounded).map(({ rule }) => rule),
  ).not.toContain("unbounded-task-group");
});

test("a neighboring bounded group cannot excuse unbounded fan-out", () => {
  const source = `
    await withTaskGroup(of: Item.self) { group in
      let initialCount = min(remoteLimit, first.count)
      for item in first.prefix(initialCount) {
        group.addTask { await load(item) }
      }
      while let result = await group.next() { consume(result) }
    }
    await withTaskGroup(of: Item.self) { group in
      for item in second {
        group.addTask { await load(item) }
      }
    }
  `;

  expect(findPerformanceViolations(source).map(({ rule }) => rule)).toContain(
    "unbounded-task-group",
  );
});

test("replacement tasks guard state publication after suspension", () => {
  const unsafe = `
    @MainActor
    final class Model {
      var refreshTask: Task<Void, Never>?
      func refresh() {
        refreshTask = Task {
          let result = await load()
          self.rows = result
        }
      }
    }
  `;
  const guarded = `
    @MainActor
    final class Model {
      var refreshTask: Task<Void, Never>?
      func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
          let result = await load()
          guard !Task.isCancelled else { return }
          self.rows = result
        }
      }
    }
  `;

  expect(findPerformanceViolations(unsafe).map(({ rule }) => rule)).toContain(
    "stale-task-publication",
  );
  expect(
    findPerformanceViolations(guarded).map(({ rule }) => rule),
  ).not.toContain("stale-task-publication");
});

test("main-actor projection chains are rejected without flagging one bounded projection", () => {
  const unsafe = `
    @MainActor
    final class Model {
      func project(_ rows: [Row]) {
        visible = rows.filter { $0.visible }.sorted { $0.name < $1.name }
      }
    }
  `;
  const bounded = `
    @MainActor
    final class Model {
      func project(_ rows: [Row]) {
        visible = rows.prefix(80).map(\\.name)
      }
    }
  `;

  expect(findPerformanceViolations(unsafe).map(({ rule }) => rule)).toContain(
    "main-actor-projection-chain",
  );
  expect(
    findPerformanceViolations(bounded).map(({ rule }) => rule),
  ).not.toContain("main-actor-projection-chain");
});

test("main-actor sorting requires an explicit input bound", () => {
  const unsafe = `
    @MainActor
    final class Model {
      func project(_ rows: [Row]) {
        visible = rows.sorted { $0.name < $1.name }
      }
    }
  `;
  const bounded = `
    @MainActor
    final class Model {
      func project(_ rows: [Row]) {
        visible = rows.prefix(80).sorted { $0.name < $1.name }
      }
    }
  `;

  expect(findPerformanceViolations(unsafe).map(({ rule }) => rule)).toContain(
    "main-actor-projection-chain",
  );
  expect(
    findPerformanceViolations(bounded).map(({ rule }) => rule),
  ).not.toContain("main-actor-projection-chain");
});

test("source-like text in strings does not trigger structural rules", () => {
  const source = `
    let shell = "Task.detached { Process().waitUntilExit() }"
    let message = "Data(contentsOf: url).map { $0 }.sorted()"
  `;

  expect(findPerformanceViolations(source)).toEqual([]);
});

test("Unicode before a violation preserves its source location", () => {
  const source = `
    let glyph = "🎛️"
    let process = Process()
  `;

  const process = findPerformanceViolations(source).find(
    ({ rule }) => rule === "raw-process-launch",
  );

  expect(process?.line).toBe(3);
  expect(process?.source).toBe("let process = Process()");
});

test("the change ratchet permits existing debt and rejects an added occurrence", () => {
  const root = mkdtempSync(join(tmpdir(), "edith-performance-contract-"));
  try {
    execFileSync("git", ["init", "-q", root]);
    execFileSync("git", [
      "-C",
      root,
      "config",
      "user.name",
      "Performance Tests",
    ]);
    execFileSync("git", [
      "-C",
      root,
      "config",
      "user.email",
      "tests@example.com",
    ]);
    execFileSync("mkdir", [join(root, "Sources")]);
    const path = join(root, "Sources", "Runner.swift");
    writeFileSync(path, "func run() { let process = Process() }\n");
    execFileSync("git", ["-C", root, "add", "Sources/Runner.swift"]);
    execFileSync("git", ["-C", root, "commit", "-q", "-m", "fixture"]);
    const base = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], {
      encoding: "utf8",
    }).trim();
    const fixtureAudit = {
      structuralEnforcement: {
        sourceRoots: ["Sources"],
        rules: [...audit.structuralEnforcement.rules],
      },
    };

    expect(validatePerformanceChanges(fixtureAudit, { root, base })).toEqual(
      [],
    );

    writeFileSync(
      path,
      "func run() { let process = Process(); let second = Process() }\n",
    );
    const failures = validatePerformanceChanges(fixtureAudit, { root, base });

    expect(failures).toHaveLength(2);
    expect(
      failures.some((failure) => failure.includes("raw-process-launch")),
    ).toBeTrue();
    expect(
      failures.some((failure) => failure.includes("unsafe-process-lifecycle")),
    ).toBeTrue();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("indexed detached tasks require direct or collection cancellation", () => {
  const examples = [
    ["workers[id]?.cancel()", false],
    ["for worker in workers.values { worker.cancel() }", false],
    ["for other in unrelated.values { other.cancel() }", true],
    ["for worker in workers.values { observe(worker) }; other.cancel()", true],
    ["", true],
  ];
  for (const [cleanup, unsafe] of examples) {
    const source = `
      final class Service {
        func start(_ id: UUID) {
          workers[id] = Task.detached { await work() }
        }
        deinit { ${cleanup} }
      }
    `;
    expect(
      findPerformanceViolations(source).some(
        ({ rule }) => rule === "unowned-detached-task",
      ),
    ).toBe(unsafe);
  }
});

test("stream tasks check cancellation after their final suspension", () => {
  const createSource = (guardStatement) => `
    @MainActor final class Model {
      func observe() {
        limitsTask?.cancel()
        limitsTask = Task { [weak self] in
          for await snapshot in values() {
            guard let self, !Task.isCancelled else { break }
            await self.reload()
            ${guardStatement}
            self.failure = snapshot.failure
          }
        }
      }
    }
  `;
  expect(
    findPerformanceViolations(
      createSource("guard !Task.isCancelled else { break }"),
    ).map(({ rule }) => rule),
  ).not.toContain("stale-task-publication");
  expect(
    findPerformanceViolations(createSource("")).map(({ rule }) => rule),
  ).toContain("stale-task-publication");
});
