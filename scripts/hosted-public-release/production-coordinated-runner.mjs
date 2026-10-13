import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  inheritedProductionCatalogChannel,
  productionCatalogMessage,
  validateProductionCatalogMessage,
} from "./production-catalog-channel.mjs";
import { executeProductionUpdate } from "./production-update.mjs";

assert.equal(process.argv.length, 2);
assert.equal(process.env.GH_TOKEN, undefined);
assert.equal(process.env.EXTENSION_CATALOG_PRIVATE_KEY, undefined);
const binding = JSON.parse(process.env.PUBLIC_HOST_CATALOG_BINDING);
assert.equal(
  createHash("sha256")
    .update(process.env.PUBLIC_HOST_UPDATE_REQUEST)
    .digest("hex"),
  binding.requestSHA256,
);
const channel = inheritedProductionCatalogChannel();
try {
  await executeProductionUpdate(process.env.PUBLIC_HOST_UPDATE_REQUEST, {
    promoteCatalog: async (request) => {
      assert.equal(request.source, binding.source);
      await channel.write(productionCatalogMessage("host-restored", binding));
      validateProductionCatalogMessage(
        await channel.read(),
        "catalog-promoted",
        binding,
      );
    },
  });
} finally {
  channel.close();
}
