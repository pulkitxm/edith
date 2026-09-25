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
  let title = "Fixture";
  let audibleTabs = [];
  let expectedVersion = "2.0.0";
  let reloads = 0;
  const health = [];
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
      for (const entry of Array.isArray(key) ? key : [key]) delete state[entry];
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
        health.push(now);
        if (offline) throw new Error("Offline fixture");
        return {
          ok: true,
          json: async () => ({ status: "ok", extension: expectedVersion }),
        };
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
        query: async (query) =>
          query?.audible ? audibleTabs : [{ id: 1, url, title }],
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
        getManifest: () => ({ version: "2.0.0" }),
        reload: () => {
          reloads += 1;
        },
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
    session,
    sent,
    health,
    reload,
    reloads: () => reloads,
    message: (message, tabId = 1) =>
      listeners.message(message, { tab: { id: tabId } }),
    title(value) {
      title = value;
    },
    audible(value) {
      audibleTabs = value;
    },
    version(value) {
      expectedVersion = value;
    },
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
  expect(f.sent[1].id).toBe(failed.id);
  expect(f.sent[1].timestamp).toBe(failed.timestamp);
  expect(f.sent[1].duration).toBe(60);
  expect(f.local.attentionQueue).toHaveLength(0);
});

test("an unchanged tab extends one segment instead of adding intervals", async () => {
  const f = fixture();
  await f.tick();
  f.advance(30);
  await f.tick();
  f.advance(30);
  await f.tick();
  expect(f.sent).toHaveLength(2);
  expect(f.sent[0].id).toBe(f.sent[1].id);
  expect(f.sent[1].duration).toBe(60);
  f.title("Another page");
  f.advance(30);
  await f.tick();
  expect(f.sent[2].id).toBe(f.sent[1].id);
  expect(f.sent[2].duration).toBe(90);
  f.advance(10);
  await f.tick();
  expect(f.sent[3].id).not.toBe(f.sent[2].id);
  expect(f.sent[3].title).toBe("Another page");
  expect(f.sent[3].duration).toBe(10);
});

test("urls become repository, video and search tags", async () => {
  const f = fixture();
  f.tab("https://github.com/Pulkit/Edith/pull/12?diff=split");
  await f.tick();
  f.tab("https://www.youtube.com/watch?v=abc123&t=4");
  f.advance(5);
  await f.tick();
  f.tab("https://www.google.com/search?q=swift+charts");
  f.advance(5);
  await f.tick();
  f.advance(5);
  await f.tick();
  expect(f.sent[0].tags).toEqual({ repo: "pulkit/edith", section: "pull" });
  expect(f.sent[1].tags).toEqual({ video: "abc123", section: "watch" });
  expect(f.sent[2].tags.search).toBe("swift charts");
});

test("page signals and media from the content script are credited to the tab", async () => {
  const f = fixture();
  await f.tick();
  await f.message({
    type: "edith-page",
    media: [
      { title: "Talk", kind: "video", playing: true, service: "first.example" },
    ],
    tags: { channel: "Swift" },
    signals: { keys: 4, clicks: 2, scrolls: 7 },
  });
  f.advance(20);
  await f.tick();
  f.advance(20);
  f.idle("idle");
  await f.tick();
  f.advance(20);
  await f.tick();
  expect(f.sent[0].signals).toEqual({
    keys: 4,
    clicks: 2,
    scrolls: 7,
    tabs: 1,
  });
  const watching = f.sent.at(-1);
  expect(watching.presence).toBe("active");
  expect(watching.tags.passive).toBe("video");
  expect(watching.tags.channel).toBe("Swift");
});

test("background audible tabs are reported as their own segments", async () => {
  const f = fixture();
  f.audible([
    {
      id: 7,
      url: "https://music.youtube.com/watch?v=1",
      title: "Lofi",
      audible: true,
    },
  ]);
  await f.tick();
  f.advance(30);
  await f.tick();
  f.advance(30);
  await f.tick();
  const first = f.sent[0].audible[0];
  const second = f.sent[1].audible[0];
  expect(first.id).toBe(second.id);
  expect(second.duration).toBe(60);
  expect(second.domain).toBe("music.youtube.com");
});

test("a newer bundled version reloads the extension", async () => {
  const f = fixture();
  f.version("2.1.0");
  await f.tick();
  expect(f.reloads()).toBe(1);
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

test("the app announces the same extension version the manifest ships", () => {
  const manifest = JSON.parse(
    readFileSync(
      "Packages/Edith/Sources/EdithKit/ChromeExtension/manifest.json",
      "utf8",
    ),
  );
  const installer = readFileSync(
    "Packages/Edith/Sources/EdithKit/Features/Attention/Services/AttentionExtensionInstaller.swift",
    "utf8",
  );
  expect(installer).toContain(
    `public static let version = "${manifest.version}"`,
  );
});
