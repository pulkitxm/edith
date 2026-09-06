import { Database } from "bun:sqlite";
import {
  closeSync,
  constants,
  existsSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  readSync,
  writeSync,
} from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";

export const billingCollectorVersion = "20.0.19";

const nullFields = new Set([
  "id",
  "cwd",
  "model",
  "speed",
  "costUSD",
  "version",
  "sessionId",
  "requestId",
  "isApiErrorMessage",
  "cache_read_input_tokens",
  "cache_creation_input_tokens",
]);
const envelopeStrings = new Set([
  "timestamp",
  "version",
  "sessionId",
  "requestId",
]);
const usageNumbers = new Set([
  "input_tokens",
  "output_tokens",
  "cache_creation_input_tokens",
  "cache_read_input_tokens",
]);
const utf8 = new TextDecoder("utf-8", { fatal: true });

export function unsupportedNull(raw) {
  let offset = 0;
  while (true) {
    const index = raw.indexOf(":null", offset);
    if (index < 0) return false;
    const end = raw.lastIndexOf('"', index - 1);
    const start = raw.lastIndexOf('"', end - 1);
    if (end >= 0 && start >= 0 && nullFields.has(raw.slice(start + 1, end)))
      return true;
    offset = index + 5;
  }
}

function validatedText(input) {
  if (typeof input === "string") {
    JSON.parse(input);
    return input;
  }
  const bytes = Buffer.from(input);
  const lossy = bytes.toString("utf8");
  JSON.parse(lossy);
  try {
    return utf8.decode(bytes);
  } catch {}
  const parts = [];
  let start = 0;
  let index = 0;
  while (index < bytes.length) {
    if (bytes[index++] !== 34) continue;
    parts.push(bytes.subarray(start, index - 1).toString("utf8"));
    start = index - 1;
    while (index < bytes.length) {
      if (bytes[index] === 92) index += 2;
      else if (bytes[index++] === 34) break;
    }
    try {
      parts.push(utf8.decode(bytes.subarray(start, index)));
    } catch {
      parts.push('"\\ud800"');
    }
    start = index;
  }
  parts.push(bytes.subarray(start).toString("utf8"));
  return parts.join("");
}

function projection(raw) {
  let index = 0;
  let maximumDepth = 1;
  let invalidUnicode = false;
  const space = () => {
    while (index < raw.length && /\s/.test(raw[index])) index++;
  };
  const string = () => {
    const start = index++;
    while (index < raw.length) {
      if (raw[index] === "\\") index += 2;
      else if (raw[index++] === '"') {
        const token = raw.slice(start, index);
        const decoded = JSON.parse(token);
        if (!decoded.isWellFormed()) invalidUnicode = true;
        return token;
      }
    }
    throw new Error("Incomplete billing JSON string.");
  };
  const discard = (depth) => {
    let open = 0;
    do {
      const byte = raw[index];
      if (byte === '"') string();
      else if (byte === "{" || byte === "[") {
        open++;
        index++;
        maximumDepth = Math.max(maximumDepth, depth + open);
      } else if (byte === "}" || byte === "]") {
        open--;
        index++;
      } else index++;
      if (maximumDepth > 4096)
        throw new Error("Billing JSON nesting admission limit reached.");
    } while (open > 0);
  };
  const nextKind = (kind, key) => {
    if (kind === "envelope")
      return envelopeStrings.has(key)
        ? "string"
        : key === "isSidechain" || key === "isApiErrorMessage"
          ? "boolean"
          : key === "costUSD"
            ? "number"
            : key === "message"
              ? "message"
              : key === "data"
                ? "wrapper"
                : null;
    if (kind === "wrapper") return key === "message" ? "envelope" : null;
    if (kind === "message")
      return key === "id" || key === "model"
        ? "string"
        : key === "usage"
          ? "usage"
          : null;
    if (kind === "usage" || kind === "iteration")
      return usageNumbers.has(key)
        ? "number"
        : key === "speed" ||
            (kind === "iteration" && (key === "type" || key === "model"))
          ? "string"
          : key === "cache_creation"
            ? "cache"
            : kind === "usage" && key === "iterations"
              ? "iterations"
              : null;
    if (kind === "cache")
      return key === "ephemeral_5m_input_tokens" ||
        key === "ephemeral_1h_input_tokens"
        ? "number"
        : null;
    return null;
  };
  const objectKinds = new Set([
    "envelope",
    "wrapper",
    "message",
    "usage",
    "iteration",
    "cache",
  ]);
  const value = (kind, depth = 0) => {
    space();
    const start = index;
    if (raw[index] === "{") {
      if (!objectKinds.has(kind)) {
        discard(depth);
        return "{}";
      }
      maximumDepth = Math.max(maximumDepth, depth + 1);
      index++;
      space();
      const fields = [];
      while (raw[index] !== "}") {
        const fieldStart = index;
        const token = string();
        const key = JSON.parse(token);
        space();
        index++;
        space();
        const separator = raw.slice(fieldStart, index);
        const childKind = nextKind(kind, key);
        const child = value(childKind, depth + 1);
        if (childKind !== null) fields.push(separator + child);
        else if (!key.isWellFormed()) fields.push(`${token}:null`);
        space();
        if (raw[index] === ",") {
          index++;
          space();
        } else break;
      }
      index++;
      return `{${fields.join(",")}}`;
    }
    if (raw[index] === "[") {
      if (kind !== "iterations") {
        discard(depth);
        return "[]";
      }
      maximumDepth = Math.max(maximumDepth, depth + 1);
      index++;
      space();
      const entries = [];
      while (raw[index] !== "]") {
        entries.push(value("iteration", depth + 1));
        space();
        if (raw[index] === ",") {
          index++;
          space();
        } else break;
      }
      index++;
      return `[${entries.join(",")}]`;
    }
    if (raw[index] === '"') {
      const token = string();
      return kind === "string" ? token : '""';
    }
    while (index < raw.length && !/[\s,}\]]/.test(raw[index])) index++;
    return raw.slice(start, index);
  };
  const output = value("envelope");
  const markers = ['{"usage":{}}'];
  if (raw.includes('"advisor_message"')) markers.push('"advisor_message"');
  const validation = invalidUnicode ? '"\\ud800"' : "null";
  return (
    output.slice(0, -1) +
    (output === "{}" ? "" : ",") +
    '"billingMarkers":[' +
    markers.join(",") +
    '],"billingValidation":' +
    "[".repeat(maximumDepth - 1) +
    validation +
    "]".repeat(maximumDepth - 1) +
    "}\n"
  );
}

export function billingEnvelope(input) {
  const original =
    typeof input === "string" ? input : Buffer.from(input).toString("utf8");
  if (!original.includes('"usage":{') || unsupportedNull(original)) return null;
  let raw;
  try {
    raw = validatedText(input);
  } catch {
    return null;
  }
  if (!raw.trimStart().startsWith("{")) return null;
  return projection(raw);
}

const digest = (value) =>
  new Bun.CryptoHasher("sha256").update(value).digest("hex");
const limit = (condition, message) => {
  if (!condition) throw new Error(message);
};
const canonical = (value) =>
  JSON.stringify(value, (_key, item) => {
    if (typeof item === "number")
      limit(
        Number.isFinite(item) && Math.abs(item) <= Number.MAX_SAFE_INTEGER,
        "Published billing values must preserve exact numeric representation.",
      );
    return item !== null && typeof item === "object" && !Array.isArray(item)
      ? Object.fromEntries(
          Object.keys(item)
            .sort()
            .map((key) => [key, item[key]]),
        )
      : item;
  });
const contentIdentity = (value) => {
  const ordered = (item, key) => {
    if (Array.isArray(item)) {
      const values = item.map((value) => ordered(value, ""));
      return key === "hours"
        ? values
        : values.sort((a, b) => canonical(a).localeCompare(canonical(b)));
    }
    if (item !== null && typeof item === "object")
      return Object.fromEntries(
        Object.keys(item)
          .sort()
          .map((key) => [key, ordered(item[key], key)]),
      );
    return item;
  };
  return canonical(ordered(value, ""));
};

const validBlock = (block) =>
  block !== null &&
  typeof block === "object" &&
  typeof block.period === "string" &&
  /^\d{4}-\d{2}-\d{2}$/.test(block.period) &&
  block.bySource !== null &&
  typeof block.bySource === "object" &&
  !Array.isArray(block.bySource) &&
  Object.keys(block.bySource).every((key) => key === "cli") &&
  Array.isArray(block.hours) &&
  block.hours.length === 24 &&
  Array.isArray(block.projects);
const defaultLimits = {
  files: 100_000,
  records: 2_000_000,
  bytes: 2_147_483_648,
  lineBytes: 33_554_432,
  baselineBlocks: 4096,
  aggregateCandidates: 8192,
  retainedBytes: 16_777_216,
};

function privateDirectory(path) {
  if (!existsSync(path)) mkdirSync(path, { recursive: true, mode: 0o700 });
  const value = lstatSync(path);
  limit(
    value.isDirectory() &&
      !value.isSymbolicLink() &&
      value.uid === process.getuid() &&
      (value.mode & 0o077) === 0,
    "Billing history directory must be owned and must not be a symbolic link.",
  );
}

function inputFiles(root, limits) {
  const paths = [];
  if (!existsSync(root)) return paths;
  limit(
    lstatSync(root).isDirectory() && !lstatSync(root).isSymbolicLink(),
    "Billing source root must be a directory without a symbolic link.",
  );
  const stack = [root];
  let inspected = 0;
  while (stack.length > 0) {
    const directory = stack.pop();
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      limit(
        ++inspected <= limits.files * 4,
        "Billing source entry limit reached.",
      );
      const path = join(directory, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) stack.push(path);
      else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        paths.push(path);
        limit(
          paths.length <= limits.files,
          "Billing source file limit reached.",
        );
      }
    }
  }
  return paths.sort();
}

function snapshot(path, previousBytes, firstOffset, limits) {
  const descriptor = openSync(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_CLOEXEC,
  );
  try {
    const initial = fstatSync(descriptor);
    limit(initial.isFile(), "Billing source must be a regular file.");
    const content = new Bun.CryptoHasher("sha256");
    const prefix = new Bun.CryptoHasher("sha256");
    const pending = Buffer.alloc(65_536);
    let tail = Buffer.alloc(0);
    let position = 0;
    let completeBytes = 0;
    const records = [];
    let payloadBytes = 0;
    const append = (bytes, offset, end) => {
      const payload = billingEnvelope(bytes);
      if (payload !== null && offset >= firstOffset) {
        payloadBytes += Buffer.byteLength(payload);
        limit(
          payloadBytes <= 33_554_432,
          "Billing file snapshot admission limit reached.",
        );
        records.push({ offset, payload });
      }
      completeBytes = end;
      limit(
        records.length <= limits.records,
        "Billing source record limit reached.",
      );
    };
    while (position < initial.size) {
      const count = readSync(
        descriptor,
        pending,
        0,
        Math.min(pending.length, initial.size - position),
        position,
      );
      limit(count > 0, "Billing source changed during its snapshot.");
      const bytes = pending.subarray(0, count);
      content.update(bytes);
      if (position < previousBytes)
        prefix.update(
          bytes.subarray(0, Math.min(count, previousBytes - position)),
        );
      const combined = Buffer.concat([tail, bytes]);
      const startOffset = position - tail.length;
      let start = 0;
      for (
        let index = combined.indexOf(10);
        index >= 0;
        index = combined.indexOf(10, start)
      ) {
        limit(
          index - start <= limits.lineBytes,
          "Billing source line limit reached.",
        );
        append(
          combined.subarray(start, index),
          startOffset + start,
          startOffset + index + 1,
        );
        start = index + 1;
      }
      tail = Buffer.from(combined.subarray(start));
      limit(
        tail.length <= limits.lineBytes,
        "Billing source line limit reached.",
      );
      position += count;
    }
    if (tail.length > 0 && billingEnvelope(tail) !== null) {
      append(tail, initial.size - tail.length, initial.size);
    }
    const final = fstatSync(descriptor);
    limit(
      final.ino === initial.ino &&
        final.size === initial.size &&
        final.mtimeMs === initial.mtimeMs,
      "Billing source was replaced while reading.",
    );
    return {
      size: initial.size,
      completeBytes,
      mtime: initial.mtimeMs,
      hash: content.digest("hex"),
      prefix: prefix.digest("hex"),
      records,
    };
  } finally {
    closeSync(descriptor);
  }
}

function providerIdentity(payload) {
  const value = JSON.parse(payload);
  const envelope = value.message ? value : value.data?.message;
  const messageID = envelope?.message?.id;
  if (typeof messageID !== "string" || messageID.length === 0) return null;
  return JSON.stringify([
    messageID,
    envelope.requestId ?? null,
    envelope.isSidechain ?? null,
  ]);
}

export class BillingArchive {
  constructor(root, limits = defaultLimits) {
    this.limits = { ...defaultLimits, ...limits };
    this.root = resolve(root);
    privateDirectory(this.root);
    const file = join(this.root, "billing.sqlite");
    const descriptor = openSync(
      file,
      constants.O_CREAT |
        constants.O_RDWR |
        constants.O_NOFOLLOW |
        constants.O_CLOEXEC,
      0o600,
    );
    const attributes = fstatSync(descriptor);
    closeSync(descriptor);
    limit(
      attributes.isFile() &&
        attributes.uid === process.getuid() &&
        (attributes.mode & 0o077) === 0,
      "Billing history file must be private and owned.",
    );
    this.database = new Database(file, { create: true, strict: true });
    try {
      this.database.exec(
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=1000;",
      );
      const version = this.database
        .query("PRAGMA user_version")
        .get().user_version;
      limit(
        version === 0 || version === 1,
        "Billing history schema is unsupported.",
      );
      this.database.exec(`
      CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY,size INTEGER NOT NULL,
        complete_bytes INTEGER NOT NULL,mtime REAL NOT NULL,hash TEXT NOT NULL,generation INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS records(sequence INTEGER PRIMARY KEY,path TEXT NOT NULL,
        identity TEXT NOT NULL,hash TEXT NOT NULL,payload TEXT NOT NULL,
        UNIQUE(path,identity,hash));
      CREATE INDEX IF NOT EXISTS records_path ON records(path,sequence);
      CREATE TABLE IF NOT EXISTS candidates(path TEXT NOT NULL,identity TEXT NOT NULL,hash TEXT NOT NULL,payload TEXT NOT NULL,
        PRIMARY KEY(path,identity,hash));
      CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS baselines(period TEXT PRIMARY KEY,payload TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS aggregate_candidates(period TEXT NOT NULL,hash TEXT NOT NULL,payload TEXT NOT NULL,
        PRIMARY KEY(period,hash));
      CREATE TABLE IF NOT EXISTS capacity(singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        files INTEGER NOT NULL,records INTEGER NOT NULL,bytes INTEGER NOT NULL);
      INSERT OR IGNORE INTO capacity(singleton,files,records,bytes) VALUES(1,0,0,0);
      CREATE TRIGGER IF NOT EXISTS file_capacity AFTER INSERT ON files BEGIN
        UPDATE capacity SET files=files+1 WHERE singleton=1; END;
      CREATE TRIGGER IF NOT EXISTS record_capacity AFTER INSERT ON records BEGIN
        UPDATE capacity SET records=records+1,bytes=bytes+length(CAST(NEW.payload AS BLOB)) WHERE singleton=1; END;
      CREATE TRIGGER IF NOT EXISTS candidate_capacity AFTER INSERT ON candidates BEGIN
        UPDATE capacity SET records=records+1,bytes=bytes+length(CAST(NEW.payload AS BLOB)) WHERE singleton=1; END;
      CREATE TRIGGER IF NOT EXISTS baseline_capacity AFTER INSERT ON baselines BEGIN
        UPDATE capacity SET bytes=bytes+length(CAST(NEW.payload AS BLOB)) WHERE singleton=1; END;
      CREATE TRIGGER IF NOT EXISTS aggregate_candidate_capacity AFTER INSERT ON aggregate_candidates BEGIN
        UPDATE capacity SET bytes=bytes+length(CAST(NEW.payload AS BLOB)) WHERE singleton=1; END;
      PRAGMA user_version=1;`);
      this.database
        .transaction(() => {
          const collector = this.database
            .query("SELECT value FROM metadata WHERE key=?")
            .get("collector");
          limit(
            collector === null || collector.value === billingCollectorVersion,
            "Billing history requires its original pinned collector version.",
          );
          this.database
            .query("INSERT OR IGNORE INTO metadata(key,value) VALUES(?,?)")
            .run("collector", billingCollectorVersion);
        })
        .immediate();
    } catch (error) {
      this.database.close();
      throw error;
    }
  }

  bootstrap({ generatedAt, blocks }) {
    limit(
      typeof generatedAt === "string" &&
        Number.isFinite(Date.parse(generatedAt)) &&
        Array.isArray(blocks) &&
        blocks.length <= this.limits.baselineBlocks,
      "Published billing baseline is invalid.",
    );
    let baselineBytes = 0;
    const encoded = blocks.map((block) => {
      limit(
        validBlock(block) && Array.isArray(block.bySource.cli),
        "Published billing baseline is invalid.",
      );
      const payload = canonical(block);
      baselineBytes += Buffer.byteLength(payload);
      limit(
        baselineBytes <= 67_108_864,
        "Published billing baseline admission limit reached.",
      );
      return { period: block.period, payload };
    });
    limit(
      new Set(encoded.map((block) => block.period)).size === encoded.length,
      "Published billing baseline repeats a day.",
    );
    this.database
      .transaction(() => {
        if (
          this.database
            .query("SELECT value FROM metadata WHERE key=?")
            .get("baseline") !== null
        )
          return;
        limit(
          this.database.query("SELECT records FROM capacity").get().records ===
            0,
          "Published billing baseline must precede the first source scan.",
        );
        const insert = this.database.query(
          "INSERT INTO baselines(period,payload) VALUES(?,?)",
        );
        for (const block of encoded) insert.run(block.period, block.payload);
        limit(
          this.database.query("SELECT bytes FROM capacity").get().bytes <=
            this.limits.bytes,
          "Billing history capacity reached; baseline was not admitted.",
        );
        this.database.query("INSERT INTO metadata(key,value) VALUES(?,?)").run(
          "baseline",
          canonical({
            version: 1,
            generatedAt,
            kind: "published-aggregate",
          }),
        );
      })
      .immediate();
  }

  reconcile(blocks) {
    limit(
      Array.isArray(blocks) &&
        blocks.length <= this.limits.baselineBlocks &&
        blocks.every(validBlock),
      "Fresh billing blocks are invalid.",
    );
    const fresh = new Map(
      blocks.map((block) => [block.period, canonical(block)]),
    );
    limit(fresh.size === blocks.length, "Fresh billing blocks repeat a day.");
    const marker = this.database
      .query("SELECT value FROM metadata WHERE key=?")
      .get("baseline");
    limit(
      marker !== null,
      "Published billing baseline is required before reconciliation.",
    );
    return this.database
      .transaction(() => {
        const insert = this.database.query(
          "INSERT OR IGNORE INTO aggregate_candidates(period,hash,payload) VALUES(?,?,?)",
        );
        for (const baseline of this.database
          .query("SELECT period,payload FROM baselines ORDER BY period")
          .iterate()) {
          const incoming =
            fresh.get(baseline.period) ??
            canonical({
              period: baseline.period,
              bySource: {},
              hours: Array.from({ length: 24 }, () => ({
                tokens: 0,
                cost: 0,
                bySource: {},
                byPath: {},
              })),
              projects: [],
            });
          const identity = contentIdentity(JSON.parse(incoming));
          if (identity !== contentIdentity(JSON.parse(baseline.payload)))
            insert.run(baseline.period, digest(identity), incoming);
        }
        const admission = this.database
          .query(`SELECT COUNT(*) AS count,
        COALESCE(SUM(length(CAST(payload AS BLOB))),0) AS bytes FROM aggregate_candidates`)
          .get();
        limit(
          admission.count <= this.limits.aggregateCandidates &&
            admission.bytes <= this.limits.retainedBytes,
          "Billing history capacity reached; historical candidates were not admitted.",
        );
        const retained = [];
        const provenance = JSON.parse(marker.value);
        for (const baseline of this.database
          .query("SELECT period,payload FROM baselines ORDER BY period")
          .iterate()) {
          const candidates = this.database
            .query(
              "SELECT payload FROM aggregate_candidates WHERE period=? ORDER BY hash",
            )
            .all(baseline.period)
            .map((row) => JSON.parse(row.payload));
          if (candidates.length === 0) continue;
          retained.push({
            period: baseline.period,
            source: "cli",
            state: "partial-overlap",
            provenance: {
              kind: provenance.kind,
              generatedAt: provenance.generatedAt,
            },
            baseline: JSON.parse(baseline.payload),
            candidates,
          });
        }
        limit(
          this.database
            .query("SELECT COUNT(*) AS count FROM aggregate_candidates")
            .get().count <= this.limits.aggregateCandidates &&
            Buffer.byteLength(canonical({ blocks: retained })) <=
              this.limits.retainedBytes &&
            this.database.query("SELECT bytes FROM capacity").get().bytes <=
              this.limits.bytes,
          "Billing history capacity reached; historical candidates were not admitted.",
        );
        return { version: 1, blocks: retained };
      })
      .immediate();
  }

  ingest(config) {
    limit(
      this.database
        .query("SELECT value FROM metadata WHERE key=?")
        .get("baseline") !== null,
      "Published billing baseline is required before the first source scan.",
    );
    const projects = join(resolve(config), "projects");
    const source = digest(resolve(config));
    const limits = this.limits;
    this.database
      .transaction(() => {
        const savedSource = this.database
          .query("SELECT value FROM metadata WHERE key=?")
          .get("source");
        limit(
          savedSource === null || savedSource.value === source,
          "Billing source identity changed.",
        );
        this.database
          .query("INSERT OR IGNORE INTO metadata(key,value) VALUES(?,?)")
          .run("source", source);
      })
      .immediate();
    const files = inputFiles(projects, limits);
    let rawFilesRead = 0;
    let rawBytesRead = 0;
    const seen = new Set(files.map((path) => relative(projects, path)));
    const known = this.database.query("SELECT * FROM files WHERE path=?");
    const insert = this.database.query(
      "INSERT OR IGNORE INTO records(path,identity,hash,payload) VALUES(?,?,?,?)",
    );
    const conflict = this.database.query(
      "INSERT OR IGNORE INTO candidates(path,identity,hash,payload) VALUES(?,?,?,?)",
    );
    const update =
      this.database.query(`INSERT INTO files(path,size,complete_bytes,mtime,hash,generation)
      VALUES(?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET size=excluded.size,
      complete_bytes=excluded.complete_bytes,mtime=excluded.mtime,hash=excluded.hash,generation=excluded.generation`);
    for (const path of files) {
      const key = relative(projects, path);
      const current = lstatSync(path);
      const previous = known.get(key);
      if (
        previous?.size === current.size &&
        previous?.mtime === current.mtimeMs
      )
        continue;
      let captured = snapshot(
        path,
        previous?.size ?? 0,
        previous?.complete_bytes ?? 0,
        limits,
      );
      rawFilesRead++;
      rawBytesRead += captured.size;
      const appended =
        !previous ||
        (captured.size >= previous.size && captured.prefix === previous.hash);
      if (!appended) {
        captured = snapshot(path, 0, 0, limits);
        rawFilesRead++;
        rawBytesRead += captured.size;
      }
      this.database
        .transaction(() => {
          const latest = known.get(key);
          limit(
            (latest?.hash ?? null) === (previous?.hash ?? null) &&
              (latest?.generation ?? null) === (previous?.generation ?? null),
            "Billing history changed before input admission.",
          );
          const generation =
            (previous?.generation ?? 0) + (previous && !appended ? 1 : 0);
          for (const record of captured.records) {
            if (appended && previous && record.offset < previous.complete_bytes)
              continue;
            const identity = providerIdentity(record.payload);
            const hash = digest(record.payload);
            if (previous && !appended && identity === null) {
              conflict.run(
                key,
                `${captured.hash}:${record.offset}`,
                hash,
                record.payload,
              );
            } else {
              insert.run(
                key,
                identity ?? `${generation}:${record.offset}`,
                hash,
                record.payload,
              );
            }
          }
          update.run(
            key,
            captured.size,
            captured.completeBytes,
            captured.mtime,
            captured.hash,
            generation,
          );
          const counts = this.database
            .query("SELECT files,records,bytes FROM capacity WHERE singleton=1")
            .get();
          limit(
            counts.files <= limits.files &&
              counts.records <= limits.records &&
              counts.bytes <= limits.bytes,
            "Billing history capacity reached; new records were not admitted.",
          );
        })
        .immediate();
    }
    const retained = this.database
      .query("SELECT path FROM files ORDER BY path")
      .all()
      .filter((value) => !seen.has(value.path)).length;
    const candidates = this.database
      .query("SELECT COUNT(*) AS count FROM candidates")
      .get().count;
    return {
      version: 1,
      collectorVersion: billingCollectorVersion,
      retainedFiles: retained,
      unresolvedCandidates: candidates,
      rawFilesRead,
      rawBytesRead,
    };
  }

  materialize(config) {
    const output = resolve(config);
    limit(
      !existsSync(output),
      "Billing input snapshot must use a new private directory.",
    );
    privateDirectory(output);
    const projects = join(output, "projects");
    privateDirectory(projects);
    const rows = this.database.query(
      "SELECT payload FROM records WHERE path=? ORDER BY sequence",
    );
    this.database.transaction(() => {
      for (const { path } of this.database
        .query("SELECT path FROM files ORDER BY path")
        .iterate()) {
        const target = resolve(projects, path);
        limit(
          target.startsWith(projects + sep),
          "Billing history path escapes its snapshot.",
        );
        privateDirectory(dirname(target));
        const descriptor = openSync(
          target,
          constants.O_CREAT |
            constants.O_EXCL |
            constants.O_WRONLY |
            constants.O_NOFOLLOW |
            constants.O_CLOEXEC,
          0o600,
        );
        try {
          for (const { payload } of rows.iterate(path)) {
            const bytes = Buffer.from(payload);
            let offset = 0;
            while (offset < bytes.length) {
              const written = writeSync(descriptor, bytes, offset);
              limit(
                written > 0,
                "Billing input snapshot could not be written.",
              );
              offset += written;
            }
          }
        } finally {
          closeSync(descriptor);
        }
      }
    })();
  }

  close() {
    this.database.close();
  }
}

function inputJSON(path) {
  const descriptor = openSync(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_CLOEXEC,
  );
  try {
    const before = fstatSync(descriptor);
    limit(
      before.isFile() && before.size <= 67_108_864,
      "Billing input document exceeds its admission limit.",
    );
    const content = readFileSync(descriptor);
    const after = fstatSync(descriptor);
    limit(
      content.length === before.size &&
        before.size === after.size &&
        before.mtimeMs === after.mtimeMs,
      "Billing input document changed during admission.",
    );
    return JSON.parse(content.toString("utf8"));
  } finally {
    closeSync(descriptor);
  }
}

if (import.meta.main) {
  let archive;
  try {
    const [operation, root, ...arguments_] = process.argv.slice(2);
    limit(
      root && (operation === "prepare" || operation === "reconcile"),
      "Billing archive operation is invalid.",
    );
    archive = new BillingArchive(root);
    if (operation === "prepare") {
      limit(
        arguments_.length === 3,
        "Billing archive preparation arguments are invalid.",
      );
      const [source, baseline, output] = arguments_;
      archive.bootstrap(inputJSON(baseline));
      const receipt = archive.ingest(source);
      archive.materialize(output);
      process.stdout.write(`${JSON.stringify(receipt)}\n`);
    } else {
      limit(
        arguments_.length === 1,
        "Billing archive reconciliation arguments are invalid.",
      );
      process.stdout.write(
        `${JSON.stringify(archive.reconcile(inputJSON(arguments_[0]).blocks))}\n`,
      );
    }
  } catch (error) {
    process.stderr.write(
      `Billing history preserved: ${error instanceof Error ? error.message : "archive operation failed"}\n`,
    );
    process.exitCode = 1;
  } finally {
    archive?.close();
  }
}
