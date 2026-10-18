import { run } from "./verify.mjs";

try {
  await run({ scope: "shipping" });
} catch (error) {
  process.stderr.write(
    `Shipping public release verification rejected: ${error.message}\n`,
  );
  process.exitCode = 1;
}
