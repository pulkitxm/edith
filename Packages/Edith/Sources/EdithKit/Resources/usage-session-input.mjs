import { createReadStream } from "node:fs";
import { mkdir, open, readdir, rename, symlink, unlink } from "node:fs/promises";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";

const metadataTypes = new Set([
  "session_meta",
  "turn_context",
  "inter_agent_communication",
  "inter_agent_communication_metadata",
]);
const eventTypes = new Set(["task_started", "thread_settings_applied"]);
const tokenFields = [
  "input_tokens",
  "cached_input_tokens",
  "cache_write_input_tokens",
  "output_tokens",
  "reasoning_output_tokens",
  "total_tokens",
];

export async function prepareSessionFile(source, destination) {
  await mkdir(dirname(destination), { recursive: true, mode: 0o700 });
  const temporary = `${destination}.pending`;
  const output = await open(temporary, "wx", 0o600);
  const seen = new Set();
  let thread;
  let modern = false;
  let records = 0;
  const lines = createInterface({
    input: createReadStream(source),
    crlfDelay: Infinity,
  });
  try {
    for await (const line of lines) {
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        continue;
      }
      const payload = event?.payload;
      if (event?.type === "session_meta") thread = payload?.id;
      if (event?.type === "token_usage_record") {
        modern = true;
        if (thread && payload?.thread_id && thread !== payload.thread_id)
          continue;
        const usage = payload?.usage;
        if (
          !usage ||
          !payload.response_id ||
          !event.timestamp ||
          tokenFields.some(
            (key) =>
              usage[key] !== undefined &&
              (!Number.isSafeInteger(usage[key]) || usage[key] < 0),
          ) ||
          !Number.isSafeInteger(usage.input_tokens) ||
          !Number.isSafeInteger(usage.output_tokens)
        )
          throw new Error("Invalid per-request usage record.");
        const identity = JSON.stringify([
          payload.thread_id ?? thread,
          payload.session_id,
          payload.response_id,
        ]);
        if (seen.has(identity)) continue;
        seen.add(identity);
        event = {
          type: "event_msg",
          timestamp: event.timestamp,
          payload: {
            type: "token_count",
            info: { last_token_usage: usage },
          },
        };
        records++;
      } else if (
        !metadataTypes.has(event?.type) &&
        !(
          event?.type === "event_msg" &&
          (eventTypes.has(payload?.type) || (!modern && payload?.type === "token_count"))
        )
      ) {
        continue;
      }
      await output.write(`${JSON.stringify(event)}\n`);
    }
  } finally {
    lines.close();
    await output.close();
  }
  if (modern) await rename(temporary, destination);
  else {
    await unlink(temporary);
    await symlink(source, destination);
  }
  return { modern, records };
}

export async function prepareSessionUsage(source, destination) {
  const result = { files: 0, modernFiles: 0, records: 0 };
  async function walk(input, output) {
    let entries;
    try {
      entries = await readdir(input, { withFileTypes: true });
    } catch (error) {
      if (error.code === "ENOENT") return;
      throw error;
    }
    for (const entry of entries) {
      const from = join(input, entry.name);
      const to = join(output, entry.name);
      if (entry.isDirectory()) await walk(from, to);
      else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        const file = await prepareSessionFile(from, to);
        result.files++;
        result.modernFiles += Number(file.modern);
        result.records += file.records;
      }
    }
  }
  for (const directory of ["sessions", "archived_sessions"])
    await walk(join(source, directory), join(destination, directory));
  return result;
}

if (import.meta.main) {
  const [source, destination] = process.argv.slice(2);
  if (!source || !destination) throw new Error("Source and destination required.");
  console.log(JSON.stringify(await prepareSessionUsage(source, destination)));
}
