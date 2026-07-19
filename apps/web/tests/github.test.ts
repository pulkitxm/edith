import { describe, expect, test } from "bun:test";
import { findReleaseAsset, rewriteAppcastEnclosureUrls } from "@/lib/github";

describe("appcast enclosure rewriting", () => {
  test("rewrites every enclosure URL and preserves non-enclosure URLs", () => {
    const input = `<rss><channel><item><enclosure url="https://github.com/pulkitxm/edith/releases/download/v1.2.3/Edith-v1.2.3.dmg" length="12" /></item><item><enclosure url='https://www.github.com/pulkitxm/edith/releases/download/v1.2.2/Edith-v1.2.2.dmg' /></item><link>https://github.com/pulkitxm/edith</link><enclosure url="https://cdn.example.com/Edith.dmg" /></channel></rss>`;

    const result = rewriteAppcastEnclosureUrls(input);

    expect(result).toContain(
      `url="https://edith.pulkit.page/api/v1/download/dmg" length="12"`,
    );
    expect(result).toContain(
      `url='https://edith.pulkit.page/api/v1/download/dmg'`,
    );
    expect(result).toContain("<link>https://github.com/pulkitxm/edith</link>");
    expect(result).not.toContain("cdn.example.com");
  });

  test("rewrites bare-filename and feed-relative enclosure URLs", () => {
    const input = `<rss><channel><item><enclosure url="Edith-v0.0.2.dmg" length="8215056" sparkle:edSignature="sig" /></item><item><enclosure url="https://edith.pulkit.page/api/v1/Edith-v0.0.2.dmg" /></item></channel></rss>`;

    const result = rewriteAppcastEnclosureUrls(input);

    expect(result).toContain(
      `url="https://edith.pulkit.page/api/v1/download/dmg" length="8215056" sparkle:edSignature="sig"`,
    );
    expect(result).not.toContain("api/v1/Edith-v0.0.2.dmg");
  });
});

describe("findReleaseAsset", () => {
  const assets = [
    { name: "Edith-v1.2.3.dmg.sig", url: "https://api.example.com/assets/1" },
    { name: "Edith-v1.2.3.dmg", url: "https://api.example.com/assets/2" },
    { name: "EdithInstaller.dmg", url: "https://api.example.com/assets/3" },
  ];

  test("returns the first asset whose name matches the predicate", () => {
    const asset = findReleaseAsset(assets, (name) => name.endsWith(".dmg"));
    expect(asset).toEqual(assets[1]);
  });

  test("matches by exact name", () => {
    const asset = findReleaseAsset(
      assets,
      (name) => name === "EdithInstaller.dmg",
    );
    expect(asset).toEqual(assets[2]);
  });

  test("returns null when nothing matches", () => {
    expect(findReleaseAsset(assets, (name) => name === "missing.dmg")).toBe(
      null,
    );
    expect(findReleaseAsset([], () => true)).toBe(null);
  });
});
