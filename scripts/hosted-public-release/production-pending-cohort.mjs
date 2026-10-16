import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
import {
  admitHostBootstrapIntent,
  retireHostBootstrapIntent,
  verifiedHostBootstrapIntent,
} from "./production-bootstrap.mjs";

export async function preparePendingProductionCohort(text, remaining) {
  remaining();
  const pending = await admitHostBootstrapIntent(text, process.env);
  try {
    const intent = verifiedHostBootstrapIntent(pending);
    assert.equal(intent.role, "extensions");
    remaining();
    const inputs = await import("./production-inputs.mjs");
    assert.equal(typeof inputs.preparePreviousHostBootstrapInputs, "function");
    assert.equal(typeof inputs.verifiedPreviousHostBootstrapInputs, "function");
    const previous = await inputs.preparePreviousHostBootstrapInputs(pending);
    const value = inputs.verifiedPreviousHostBootstrapInputs(previous);
    await value.revalidate();
    remaining();
    return Object.freeze({ pending, previous });
  } catch (error) {
    retireHostBootstrapIntent(pending);
    throw error;
  }
}

export async function waitForCompletedHostBootstrap(pending, remaining) {
  const intent = verifiedHostBootstrapIntent(pending);
  assert.equal(intent.role, "extensions");
  while (true) {
    remaining();
    const state = await intent.hostState();
    remaining();
    if (state.status === "completed") {
      assert.equal(state.conclusion, "success");
      return;
    }
    await delay(Math.min(15000, remaining()));
  }
}

export async function completePendingProductionCohort(pending, remaining) {
  const intent = verifiedHostBootstrapIntent(pending);
  assert.equal(intent.role, "extensions");
  await waitForCompletedHostBootstrap(pending, remaining);
  remaining();
  const { prepareCompletedHostBootstrap, completedHostBootstrap } =
    await import("./production-completed-host.mjs");
  await intent.hostState();
  const completed = await prepareCompletedHostBootstrap(pending);
  await intent.hostState();
  const value = completedHostBootstrap(completed);
  await value.revalidate();
  remaining();
  assert.deepEqual(value.intent.template, intent.template);
  return Object.freeze({
    completed,
    template: Object.freeze({
      ...intent.template,
      schema: 1,
      hosts: Object.freeze({
        previous: intent.template.hosts.previous,
        current: value.host,
      }),
    }),
  });
}
