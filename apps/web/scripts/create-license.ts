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
  name: z.string().trim().min(1).max(200).optional(),
  email: z.string().trim().email().max(320).optional(),
  phone: z.string().trim().min(1).max(50).optional(),
});

function readArguments(values: string[]): z.infer<typeof argumentsSchema> {
  const parsed: Partial<Record<"machines" | "label" | "name" | "email" | "phone", string>> = {};
  const flags = ["machines", "label", "name", "email", "phone"] as const;

  for (let index = 0; index < values.length; index += 1) {
    const argument = values[index];
    const value = values[index + 1];
    const flag = flags.find((candidate) => argument === `--${candidate}`);

    if (flag && value) {
      parsed[flag] = value;
      index += 1;
      continue;
    }

    throw new Error(
      "Usage: bun scripts/create-license.ts --machines N --label label --name name --email email --phone phone",
    );
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
        name: input.name ?? null,
        email: input.email ?? null,
        phone: input.phone ?? null,
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
