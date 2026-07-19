import {
  fetchReleaseAsset,
  findReleaseAsset,
  getLatestRelease,
} from "@/lib/github";
import { apiHeaders, apiJson, attachmentHeader } from "@/lib/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(): Promise<Response> {
  try {
    const release = await getLatestRelease();
    const asset = findReleaseAsset(
      release.assets,
      (name) => name === "EdithInstaller.dmg",
    );

    if (!asset) {
      return new Response(
        "<!doctype html><meta charset=\"utf-8\"><title>Edith</title><body style=\"margin:0;display:grid;place-items:center;min-height:100vh;background:#0d0c0b;color:#efe9df;font-family:-apple-system,system-ui,sans-serif\"><div style=\"text-align:center;padding:24px\"><p style=\"font-size:22px;margin:0\">The Edith installer is almost ready.</p><p style=\"color:#8a8177;margin-top:10px\">Downloads open shortly. <a href=\"/\" style=\"color:#d97757\">Back to edith.pulkit.page</a></p></div>",
        {
          status: 503,
          headers: apiHeaders({
            "content-type": "text/html; charset=utf-8",
            "retry-after": "3600",
          }),
        },
      );
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
