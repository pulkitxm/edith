import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";

const source = readFileSync(
  "Packages/Edith/Sources/EdithKit/ChromeExtension/service-worker.js",
  "utf8",
);

function fixture() {
  let now = 1_800_000_000_000;
  let focused = true;
  let url = "https://first.example/";
  let presence = "active";
  let offline = false;
  let sequence = 0;
  const local = { token: "fixture-token" };
  const session = {};
  const sent = [];
  const listeners = {};
  const listener = (name) => ({
    addListener(callback) {
      listeners[name] = callback;
    },
  });
  const storage = (state) => ({
    async get(keys) {
      if (typeof keys === "string")
        return structuredClone({ [keys]: state[keys] });
      return structuredClone({ ...keys, ...state });
    },
    async set(values) {
      Object.assign(state, structuredClone(values));
    },
    async remove(key) {
      delete state[key];
    },
  });
  const context = createContext({
    Date: class extends Date {
      constructor(...args) {
        super(...(args.length ? args : [now]));
      }
      static now() {
        return now;
      }
    },
    URL,
    AbortSignal,
    TextEncoder,
    crypto: { randomUUID: () => `fixture-${++sequence}` },
    navigator: { userAgent: "Chrome/" },
    fetch: async (_url, options) => {
      if (!options.body) {
        if (offline) throw new Error("Offline fixture");
        return { ok: true };
      }
      const event = JSON.parse(options.body);
      sent.push(event);
      if (offline) throw new Error("Offline fixture");
      return { ok: true };
    },
    chrome: {
      storage: { local: storage(local), session: storage(session) },
      windows: {
        getLastFocused: async () => ({ id: 1, focused }),
        WINDOW_ID_NONE: -1,
        onFocusChanged: listener("focus"),
      },
      tabs: {
        query: async () => [{ id: 1, url, title: "Fixture" }],
        onActivated: listener("tab"),
        onUpdated: listener("updated"),
        onRemoved: listener("removed"),
      },
      idle: {
        queryState: async () => presence,
        onStateChanged: listener("idle"),
      },
      alarms: { get() {}, onAlarm: listener("alarm") },
      runtime: {
        onInstalled: listener("installed"),
        onStartup: listener("startup"),
        onMessage: listener("message"),
      },
    },
  });
  const reload = () =>
    runInContext(`{${source}\nglobalThis.tick = heartbeat}`, context);
  reload();
  return {
    local,
    sent,
    reload,
    tick: () => context.tick(),
    advance(seconds) {
      now += seconds * 1000;
    },
    focus(value) {
      focused = value;
    },
    tab(value) {
      url = value;
    },
    idle(value) {
      presence = value;
    },
    offline(value) {
      offline = value;
    },
  };
}

test("tab changes credit the preceding interval to the preceding tab", async () => {
  const f = fixture();
  await f.tick();
  expect(f.sent).toHaveLength(0);
  f.advance(5);
  f.tab("https://second.example/");
  await f.tick();
  expect(f.sent[0].domain).toBe("first.example");
  expect(f.sent[0].duration).toBe(5);
  f.advance(10);
  await f.tick();
  expect(f.sent[1].domain).toBe("second.example");
  expect(f.sent[1].duration).toBe(10);
});

test("time outside the browser is never credited on returning", async () => {
  const f = fixture();
  await f.tick();
  f.advance(5);
  f.focus(false);
  await f.tick();
  f.advance(150);
  await f.tick();
  f.focus(true);
  f.tab("https://second.example/");
  await f.tick();
  expect(f.sent).toHaveLength(1);
  expect(f.sent[0].duration).toBe(5);
  f.advance(10);
  await f.tick();
  expect(f.sent[1].duration).toBe(10);
});

test("idle transitions retain the previous presence and long sleep gaps are discarded", async () => {
  const f = fixture();
  await f.tick();
  f.advance(30);
  f.idle("idle");
  await f.tick();
  expect(f.sent[0].presence).toBe("active");
  f.advance(30);
  f.idle("active");
  await f.tick();
  expect(f.sent[1].presence).toBe("idle");
  f.advance(3600);
  await f.tick();
  expect(f.sent).toHaveLength(2);
});

test("failed intervals survive worker restart and replay with the same identity", async () => {
  const f = fixture();
  await f.tick();
  f.advance(30);
  f.offline(true);
  await f.tick();
  expect(f.local.attentionQueue).toHaveLength(1);
  const failed = f.sent[0];
  f.reload();
  f.offline(false);
  f.advance(30);
  await f.tick();
  expect(f.sent[1]).toEqual(failed);
  expect(f.sent[2].duration).toBe(30);
  expect(f.local.attentionQueue).toHaveLength(0);
});

test("rapid events do not invent one-second intervals", async () => {
  const f = fixture();
  await f.tick();
  await f.tick();
  expect(f.sent).toHaveLength(0);
  f.advance(0.1);
  await f.tick();
  expect(f.sent[0].duration).toBe(0.1);
});

test("a full queue still drains and reports dropped intervals", async () => {
  const f = fixture();
  await f.tick();
  f.local.attentionQueue = Array.from({ length: 4096 }, (_, id) => ({ id }));
  f.advance(30);
  await f.tick();
  expect(f.local.attentionQueue).toHaveLength(4064);
  expect(f.local.attentionDroppedEvents).toBe(1);
  expect(f.local.lastError).toContain("1 intervals were not retained");
});

test("disabling tracking resets the interval boundary", async () => {
  const f = fixture();
  await f.tick();
  f.local.enabled = false;
  f.advance(10);
  await f.tick();
  f.local.enabled = true;
  f.advance(10);
  await f.tick();
  expect(f.sent).toHaveLength(0);
  f.advance(10);
  await f.tick();
  expect(f.sent[0].duration).toBe(10);
});

test("an empty queue cannot report a stopped daemon as connected", async () => {
  const f = fixture();
  f.offline(true);
  await f.tick();
  expect(f.local.connectionStatus).toBe("offline");
  expect(f.sent).toHaveLength(0);
});
