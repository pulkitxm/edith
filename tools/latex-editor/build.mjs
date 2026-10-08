import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const root = new URL(".", import.meta.url);
const directory = new URL("../../Packages/Edith/Sources/EdithKit/LaTeXEditor/", root);
const result = await build({
  absWorkingDir: fileURLToPath(root),
  entryPoints: ["src/editor.js", "src/review.js"],
  outdir: fileURLToPath(directory),
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari17",
  legalComments: "inline",
  write: false,
});
for (const file of result.outputFiles) {
  if (process.argv.includes("--check")) {
    if (!Buffer.from(file.contents).equals(await readFile(file.path))) {
      throw new Error("The bundled LaTeX workspace is stale. Run bun run build in tools/latex-editor.");
    }
  } else {
    await writeFile(file.path, file.contents);
  }
}
