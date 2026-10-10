import assert from "node:assert/strict";
import { spawn } from "node:child_process";

export function runOwnedJourneyCommand(
  executable,
  args,
  { timeoutMs = 900_000, terminateGraceMs = 5_000, ...options } = {},
) {
  assert(Number.isInteger(timeoutMs) && timeoutMs > 0 && timeoutMs <= 900_000);
  assert(
    Number.isInteger(terminateGraceMs) &&
      terminateGraceMs > 0 &&
      terminateGraceMs <= 10_000,
  );
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, options);
    let timeout;
    let escalation;
    let timedOut = false;
    let launchError;
    const clear = () => {
      clearTimeout(timeout);
      clearTimeout(escalation);
    };
    child.once("error", (error) => {
      launchError = error;
      if (!child.pid) {
        clear();
        reject(error);
      }
    });
    child.once("exit", (code, signal) => {
      clear();
      if (timedOut)
        reject(
          Error("Owned hosted UI test command timed out after confirmed exit"),
        );
      else if (launchError) reject(launchError);
      else if (code === 0 && signal === null) resolve();
      else
        reject(Error(`Owned hosted UI test command failed: ${code ?? signal}`));
    });
    timeout = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      escalation = setTimeout(() => {
        if (child.exitCode === null && child.signalCode === null)
          child.kill("SIGKILL");
      }, terminateGraceMs);
    }, timeoutMs);
  });
}
