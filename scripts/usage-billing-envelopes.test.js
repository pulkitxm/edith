import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { billingEnvelope } from "../Packages/Edith/Sources/EdithKit/Resources/usage-billing-archive.mjs";

const binary = process.env.EDITH_NATIVE_CCUSAGE;
const cases = {
  "spaced-null":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId": null,"costUSD":1.5,"message":{"id":"message","model":"model","usage":{"input_tokens":10,"output_tokens":3}}}',
  "duplicate-known-field":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","usage":{"input_tokens":10,"input_tokens":20,"output_tokens":3}}}',
  "escaped-advisor-marker":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","usage":{"input_tokens":10,"output_tokens":3,"iterations":[{"type":"advisor\\u005fmessage","model":"advisor-model","input_tokens":31,"output_tokens":7}]}}}',
  "large-integer":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","usage":{"input_tokens":9007199254740993,"output_tokens":3}}}',
  "integer-exponent":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","usage":{"input_tokens":1e1,"output_tokens":3}}}',
  "unknown-advisor-marker":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","usage":{"input_tokens":10,"output_tokens":3,"iterations":[{"type":"advisor\\u005fmessage","model":"advisor-model","input_tokens":31,"output_tokens":7}]}},"unrelated":"advisor_message"}',
  "escaped-usage-with-unknown-marker":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","us\\u0061ge":{"input_tokens":10,"output_tokens":3}},"unrelated":{"usage":{}}}',
  "spaced-usage-with-unknown-marker":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","usage": {"input_tokens":10,"output_tokens":3}},"unrelated":{"usage":{}}}',
  "escaped-null-field":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","request\\u0049d":null,"costUSD":1.5,"message":{"id":"message","model":"model","usage":{"input_tokens":10,"output_tokens":3}}}',
  "duplicate-message":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","usage":{"input_tokens":10,"output_tokens":3}},"message":{"id":"other","model":"model","usage":{"input_tokens":20,"output_tokens":3}}}',
  "invalid-model-object":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":{"content":"PRIVATE_CONTENT_CANARY"},"usage":{"input_tokens":10,"output_tokens":3}}}',
  "invalid-input-string":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","usage":{"input_tokens":"PRIVATE_CONTENT_CANARY","output_tokens":3}}}',
  "invalid-usage-array":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","usage":[{"content":"PRIVATE_CONTENT_CANARY"}]},"unknown":{"usage":{}}}',
  "unknown-nesting-100":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","usage":{"input_tokens":10,"output_tokens":3}},"content":[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[0]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]}',
  "unknown-nesting-300":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","usage":{"input_tokens":10,"output_tokens":3}},"content":[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[0]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]}',
  "unknown-invalid-surrogate":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"model","usage":{"input_tokens":10,"output_tokens":3}},"content":"\\ud800"}',
  "known-invalid-surrogate":
    '{"timestamp":"2026-09-05T01:00:00Z","version":"1.2.3","sessionId":"session","requestId":"request","costUSD":1.5,"message":{"id":"message","model":"\\ud800","usage":{"input_tokens":10,"output_tokens":3}}}',
};
cases["invalid-utf8"] = Buffer.concat([
  Buffer.from(
    `${cases["unknown-invalid-surrogate"].split(',"content":')[0]},"content":"`,
  ),
  Buffer.from([255]),
  Buffer.from('"}'),
]);

for (const [name, raw] of Object.entries(cases)) {
  test(`minimal billing envelope removes prompt content from ${name}`, () => {
    const minimal = billingEnvelope(raw);
    expect(minimal).not.toBeNull();
    expect(minimal).not.toContain("PRIVATE_CONTENT_CANARY");
    expect(minimal).not.toContain('"content"');
  });
}

test("minimal envelopes preserve numeric spelling and duplicate billing fields", () => {
  expect(billingEnvelope(cases["large-integer"])).toContain("9007199254740993");
  expect(billingEnvelope(cases["integer-exponent"])).toContain("1e1");
  expect(billingEnvelope(cases["duplicate-known-field"])).toContain(
    '"input_tokens":10,"input_tokens":20',
  );
  expect(billingEnvelope(cases["spaced-null"])).toContain('"requestId": null');
});

test.skipIf(!binary)(
  "native collector daily and session acceptance matches every minimal edge envelope",
  () => {
    const root = mkdtempSync(join(tmpdir(), "edith-billing-acceptance-"));
    const env = {
      ...process.env,
      HOME: join(root, "home"),
      XDG_CONFIG_HOME: join(root, "config"),
    };
    delete env.CFFIXED_USER_HOME;
    try {
      for (const [name, raw] of Object.entries(cases)) {
        const outputs = [];
        for (const [label, contents] of [
          ["original", raw],
          ["minimal", billingEnvelope(raw)],
        ]) {
          const config = join(root, name, label);
          const projects = join(config, "projects/project");
          mkdirSync(projects, { recursive: true, mode: 0o700 });
          writeFileSync(join(projects, "session.jsonl"), contents);
          const modes = [];
          for (const mode of ["daily", "session"]) {
            const result = Bun.spawnSync(
              [
                binary,
                "claude",
                mode,
                "--json",
                "--offline",
                "--mode",
                "display",
                "--single-thread",
              ],
              {
                env: { ...env, CLAUDE_CONFIG_DIR: config },
                cwd: root,
                timeout: 10000,
              },
            );
            expect(result.exitCode).toBe(0);
            modes.push(JSON.parse(result.stdout.toString()));
          }
          outputs.push(modes);
        }
        expect(outputs[0]).toEqual(outputs[1]);
      }
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  },
);
