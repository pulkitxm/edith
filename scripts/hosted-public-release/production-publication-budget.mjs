import assert from "node:assert/strict";

export function productionPublicationBudget({
  now = () => performance.now(),
} = {}) {
  const started = now();
  assert(Number.isFinite(started) && started >= 0);
  let previous = started;
  let closed = false;
  return () => {
    try {
      assert(!closed, "The production publication budget is retired");
      const current = now();
      assert(Number.isFinite(current) && current >= previous);
      previous = current;
      const remaining = 180 * 60 * 1000 - (current - started);
      assert(remaining > 0, "The production publication budget expired");
      return remaining;
    } catch (error) {
      closed = true;
      throw error;
    }
  };
}
