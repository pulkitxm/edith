export const requiredEnvVars = [
  "DATABASE_URL",
  "GITHUB_TOKEN",
  "GITHUB_REPO",
  "LICENSE_SIGNING_PRIVATE_KEY",
  "LICENSE_KEY_LOOKUP_PEPPER",
  "LICENSE_ACCESS_TOKEN_SECRET",
] as const;

export function missingEnvVars(
  env: Record<string, string | undefined> = process.env,
): string[] {
  return requiredEnvVars.filter((name) => {
    const value = env[name];
    return value === undefined || value.trim() === "";
  });
}

export function assertRequiredEnv(
  env: Record<string, string | undefined> = process.env,
): void {
  const missing = missingEnvVars(env);

  if (missing.length > 0) {
    throw new Error(
      `missing required environment variables: ${missing.join(", ")}`,
    );
  }
}
