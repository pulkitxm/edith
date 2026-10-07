import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const root = new URL(".", import.meta.url);
const output = new URL("../../Packages/Edith/Sources/EdithKit/LaTeXEditor/editor.js", root);
const result = await build({
  absWorkingDir: fileURLToPath(root),
  entryPoints: ["src/editor.js"],
  outfile: fileURLToPath(output),
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari17",
  legalComments: "inline",
  write: false,
});
const contents = result.outputFiles[0].contents;
if (process.argv.includes("--check")) {
  if (!Buffer.from(contents).equals(await readFile(output))) {
    throw new Error("The bundled LaTeX editor is stale. Run bun run build in tools/latex-editor.");
  }
} else {
  await writeFile(output, contents);
}
