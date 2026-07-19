import {
  fetchReleaseAsset,
  findReleaseAsset,
  getLatestRelease,
  rewriteAppcastEnclosureUrls,
} from "@/lib/github";
import { apiHeaders, apiJson } from "@/lib/http";
import {
  authFailureResponse,
  ipGuard,
  isDownloadAuthorized,
} from "@/lib/v2-api";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const route = "/api/v1/appcast";

export async function GET(request: Request): Promise<Response> {
  const guard = await ipGuard(request.headers, route);

  if (guard) {
    return guard;
  }

  let licensed: boolean;

  try {
    licensed = await isDownloadAuthorized(request.headers, "appcast");
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
    const asset = findReleaseAsset(
      release.assets,
      (name) => name === "appcast.xml",
    );

    if (!asset) {
      return apiJson({ error: "upstream" }, 502);
    }

    const upstream = await fetchReleaseAsset(asset);
    const appcast = rewriteAppcastEnclosureUrls(await upstream.text());

    return new Response(appcast, {
      status: 200,
      headers: apiHeaders({ "content-type": "text/xml; charset=utf-8" }),
    });
  } catch {
    return apiJson({ error: "upstream" }, 502);
  }
}
