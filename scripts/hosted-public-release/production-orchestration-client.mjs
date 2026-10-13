import assert from "node:assert/strict";
import { createHash, createPublicKey, sign, verify } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";

export function runSyntheticPublicationClient(stateFile) {
  const state = JSON.parse(readFileSync(stateFile));
  const args = process.argv.slice(2);
  const command = basename(process.argv[1]);
  const output = (value) => process.stdout.write(JSON.stringify(value));
  const option = (name) => args[args.indexOf(name) + 1];
  const save = () => writeFileSync(stateFile, JSON.stringify(state));
  const checksum = (bytes) => createHash("sha256").update(bytes).digest("hex");
  const fail = (message) => {
    process.stderr.write(message);
    process.exitCode = 1;
  };
  if (command === "swift") {
    assert.equal(args[0], "scripts/extension-catalog-sign.swift");
    const key = createPublicKey({
      format: "jwk",
      key: {
        kty: "OKP",
        crv: "Ed25519",
        x: Buffer.from(state.publicKey, "base64").toString("base64url"),
      },
    });
    if (args[1] === "check-key") {
      assert.equal(args[2], state.publicKey);
      const bytes = Buffer.from("synthetic signing key match");
      assert(verify(null, bytes, key, sign(null, bytes, state.privateKey)));
    } else if (args[1] === "sign") {
      const bytes = readFileSync(args[2]);
      writeFileSync(
        args[3],
        JSON.stringify({
          payload: bytes.toString("base64"),
          signature: sign(null, bytes, state.privateKey).toString("base64"),
        }),
      );
    } else if (args[1] === "verify") {
      const envelope = JSON.parse(readFileSync(args[2]));
      const bytes = Buffer.from(envelope.payload, "base64");
      assert(
        verify(null, bytes, key, Buffer.from(envelope.signature, "base64")),
      );
      writeFileSync(args[3], bytes);
    } else assert.fail("Unknown synthetic signer operation");
    return;
  }
  if (command === "gh") {
    assert.equal(args[0], "api");
    const route = args.at(-1).replace(/^\/?repos\/pulkitxm\/edith/, "");
    if (route === "/git/ref/heads/main")
      output({
        ref: "refs/heads/main",
        object: { type: "commit", sha: state.source },
      });
    else if (route.startsWith("/releases/assets/")) {
      const bytes = state.bytes[route.split("/").at(-1)];
      assert(bytes);
      process.stdout.write(Buffer.from(bytes, "base64"));
    } else if (route.startsWith("/releases/tags/")) {
      const item = state.releases.find(
        ({ tag_name, draft }) =>
          tag_name === decodeURIComponent(route.split("/").at(-1)) && !draft,
      );
      if (item) output(item);
      else fail("gh: Not Found (HTTP 404)");
    } else if (route.startsWith("/releases?")) output(state.releases);
    else {
      assert(state.api[route], `Unknown synthetic API route ${route}`);
      output(state.api[route]);
    }
    return;
  }
  assert.equal(command, "pukbot");
  assert.equal(args[0], "release");
  assert.equal(option("--repo"), "pulkitxm/edith");
  if (args.includes("--dry-run")) {
    output({ ok: true });
    return;
  }
  if (args[1] === "create") {
    const tag = args[4];
    assert(!state.releases.some(({ tag_name }) => tag_name === tag));
    state.releases.push({
      id: state.next++,
      tag_name: tag,
      target_commitish: option("--target"),
      draft: args.includes("--draft"),
      prerelease: args.includes("--prerelease"),
      body: option("--body"),
      assets: [],
    });
    state.events.push({ kind: "created", tag });
  } else if (args[1] === "upload-asset") {
    const item = state.releases.find(({ id }) => id === Number(args[2]));
    assert(item);
    const name = option("--name");
    assert(!item.assets.some((asset) => asset.name === name));
    const bytes = readFileSync(args[3]);
    const id = state.next++;
    item.assets.push({
      id,
      name,
      size: bytes.length,
      digest: `sha256:${checksum(bytes)}`,
      state: "uploaded",
      browser_download_url: `https://github.com/pulkitxm/edith/releases/download/${encodeURIComponent(item.tag_name)}/${name}`,
    });
    state.bytes[id] = bytes.toString("base64");
    state.events.push({ kind: "uploaded", tag: item.tag_name, name });
  } else if (args[1] === "edit") {
    const item = state.releases.find(({ id }) => id === Number(args[4]));
    assert(item);
    if (args.includes("--draft")) item.draft = option("--draft") === "true";
    if (args.includes("--body")) {
      assert.equal(item.tag_name, "extension-catalog-v1");
      item.body = option("--body");
      state.promotions++;
      state.events.push({ kind: "promoted" });
    }
  } else assert.fail("Unknown synthetic publication mutation");
  save();
  output({ ok: true });
}
