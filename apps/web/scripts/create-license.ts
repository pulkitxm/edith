import { z } from "zod";
import { closeDatabase, getDb } from "@/lib/db";
import {
  displaySuffix,
  generateLicenseKey,
  keyLookupDigest,
} from "@/lib/license-key";
import { licenses } from "@/lib/schema";

const argumentsSchema = z.object({
  machines: z.coerce.number().int().min(1).max(1_000).default(1),
  label: z.string().trim().min(1).max(200).optional(),
});

function readArguments(values: string[]): z.infer<typeof argumentsSchema> {
  const parsed: { machines?: string; label?: string } = {};

  for (let index = 0; index < values.length; index += 1) {
    const argument = values[index];
    const value = values[index + 1];

    if (argument === "--machines" && value) {
      parsed.machines = value;
      index += 1;
      continue;
    }

    if (argument === "--label" && value) {
      parsed.label = value;
      index += 1;
      continue;
    }

    throw new Error("Usage: bun scripts/create-license.ts --machines N --label name");
  }

  return argumentsSchema.parse(parsed);
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    error.code === "23505"
  );
}

async function createLicense(): Promise<string> {
  const input = readArguments(process.argv.slice(2));

  for (let attempt = 0; attempt < 5; attempt += 1) {
    const key = generateLicenseKey();

    try {
      await getDb().insert(licenses).values({
        key,
        keyDigest: keyLookupDigest(key),
        keyLast4: displaySuffix(key),
        label: input.label ?? null,
        maxMachines: input.machines,
      });
      return key;
    } catch (error) {
      if (!isUniqueViolation(error)) {
        throw error;
      }
    }
  }

  throw new Error("Unable to create a unique license key");
}

try {
  const key = await createLicense();
  process.stdout.write(`${key}\n`);
} catch (error) {
  const message = error instanceof Error ? error.message : "License creation failed";
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
} finally {
  await closeDatabase();
}
