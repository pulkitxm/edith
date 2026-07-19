import { z } from "zod";

const githubAssetSchema = z.object({
  name: z.string(),
  url: z.string().url(),
});

const githubReleaseSchema = z.object({
  assets: z.array(githubAssetSchema),
});

const githubEnvironmentSchema = z.object({
  GITHUB_TOKEN: z.string().min(1),
  GITHUB_REPO: z.string().regex(/^[^/\s]+\/[^/\s]+$/),
});

export type GitHubAsset = z.infer<typeof githubAssetSchema>;

export class GitHubUpstreamError extends Error {
  constructor() {
    super("GitHub upstream request failed");
    this.name = "GitHubUpstreamError";
  }
}

function getGitHubEnvironment(): z.infer<typeof githubEnvironmentSchema> {
  const result = githubEnvironmentSchema.safeParse(process.env);

  if (!result.success) {
    throw new GitHubUpstreamError();
  }

  return result.data;
}

function githubHeaders(accept: string): HeadersInit {
  const environment = getGitHubEnvironment();

  return {
    Accept: accept,
    Authorization: `Bearer ${environment.GITHUB_TOKEN}`,
    "X-GitHub-Api-Version": "2022-11-28",
  };
}

export async function getLatestRelease(): Promise<
  z.infer<typeof githubReleaseSchema>
> {
  const environment = getGitHubEnvironment();
  const response = await fetch(
    `https://api.github.com/repos/${environment.GITHUB_REPO}/releases/latest`,
    {
      headers: githubHeaders("application/vnd.github+json"),
      cache: "no-store",
    },
  );

  if (!response.ok) {
    throw new GitHubUpstreamError();
  }

  const parsed = githubReleaseSchema.safeParse(await response.json());

  if (!parsed.success) {
    throw new GitHubUpstreamError();
  }

  return parsed.data;
}

export function findReleaseAsset(
  assets: GitHubAsset[],
  predicate: (name: string) => boolean,
): GitHubAsset | null {
  return assets.find((asset) => predicate(asset.name)) ?? null;
}

export async function fetchReleaseAsset(asset: GitHubAsset): Promise<Response> {
  const response = await fetch(asset.url, {
    headers: githubHeaders("application/octet-stream"),
    redirect: "follow",
    cache: "no-store",
  });

  if (!response.ok || !response.body) {
    throw new GitHubUpstreamError();
  }

  return response;
}

export function rewriteAppcastEnclosureUrls(
  appcast: string,
  downloadUrl = "https://edith.pulkit.page/api/v1/download/dmg",
): string {
  const enclosureUrl = /(<enclosure\b[^>]*?\burl\s*=\s*)(["'])[^"']*\2/gi;

  return appcast.replace(
    enclosureUrl,
    (_match: string, prefix: string, quote: string) =>
      `${prefix}${quote}${downloadUrl}${quote}`,
  );
}
