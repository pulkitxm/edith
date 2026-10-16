import assert from "node:assert/strict";
import { AsyncLocalStorage } from "node:async_hooks";
import { productionReadonlyEnvironment } from "./production-catalog-channel.mjs";

const fixtures = new AsyncLocalStorage();

export const productionFixtureProcess = new Proxy(globalThis.process, {
  get(target, key) {
    if (key === "env") return fixtures.getStore()?.environment ?? target.env;
    return Reflect.get(target, key, target);
  },
});

export const productionFixtureGlobal = {
  get fetch() {
    return fixtures.getStore()?.fetch ?? globalThis.fetch;
  },
  set fetch(value) {
    const fixture = fixtures.getStore();
    assert(fixture && typeof value === "function");
    fixture.fetch = value;
  },
};

export const productionFixtureFetch = (...arguments_) =>
  productionFixtureGlobal.fetch(...arguments_);

export function withProductionFixtureRuntime(action, environment) {
  const fixture = {
    environment: { ...productionReadonlyEnvironment(environment) },
    fetch: productionFixtureGlobal.fetch,
  };
  return fixtures.run(fixture, action);
}
