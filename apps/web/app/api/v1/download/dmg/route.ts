import {
  fetchReleaseAsset,
  findReleaseAsset,
  getLatestRelease,
} from "@/lib/github";
import { apiHeaders, apiJson, attachmentHeader } from "@/lib/http";
import {
  authFailureResponse,
  ipGuard,
  isDownloadAuthorized,
} from "@/lib/v2-api";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const route = "/api/v1/download/dmg";

export async function GET(request: Request): Promise<Response> {
  const guard = await ipGuard(request.headers, route);

  if (guard) {
    return guard;
  }

  let licensed: boolean;

  try {
    licensed = await isDownloadAuthorized(request.headers, "download");
  } catch {
    return apiJson({ error: "internal" }, 500);
  }

  if (!licensed) {
    return authFailureResponse(request.headers, route, {
      error: "unlicensed",
    });
  }

  try {
    const release = await getLatestRelease();
    const asset = findReleaseAsset(release.assets, (name) =>
      /^Edith-v[^/]+\.dmg$/.test(name),
    );

    if (!asset) {
      return apiJson({ error: "upstream" }, 502);
    }

    const upstream = await fetchReleaseAsset(asset);

    return new Response(upstream.body, {
      status: 200,
      headers: apiHeaders({
        "content-type": "application/octet-stream",
        "content-disposition": attachmentHeader(asset.name),
      }),
    });
  } catch {
    return apiJson({ error: "upstream" }, 502);
  }
}
