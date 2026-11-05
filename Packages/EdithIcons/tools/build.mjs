import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { bake, svg } from "./geo.mjs";
import { ICONS } from "./icons.mjs";

const root = join(dirname(new URL(import.meta.url).pathname), "..");
const target = process.argv[2] ?? join(root, "svg");
const secondaryOpacity = 0.45;

rmSync(target, { recursive: true, force: true });
mkdirSync(target, { recursive: true });
for (const [name, cuts] of Object.entries(ICONS)) {
  for (const grid of [16, 20]) {
    writeFileSync(join(target, `${name}.${grid}.svg`), svg(bake(cuts[grid]()), grid, secondaryOpacity));
  }
}
console.log(`${Object.keys(ICONS).length} icons`);
