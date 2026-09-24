import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

export const languages = [
  "apache",
  "applescript",
  "awk",
  "bash",
  "c",
  "clojure",
  "cmake",
  "cpp",
  "csharp",
  "css",
  "dart",
  "diff",
  "dockerfile",
  "dos",
  "elixir",
  "elm",
  "erlang",
  "fsharp",
  "go",
  "gradle",
  "graphql",
  "groovy",
  "haskell",
  "http",
  "ini",
  "java",
  "javascript",
  "json",
  "julia",
  "kotlin",
  "latex",
  "less",
  "lua",
  "makefile",
  "markdown",
  "nginx",
  "nix",
  "objectivec",
  "ocaml",
  "perl",
  "php",
  "php-template",
  "plaintext",
  "powershell",
  "properties",
  "protobuf",
  "python",
  "python-repl",
  "r",
  "ruby",
  "rust",
  "scala",
  "scss",
  "shell",
  "sql",
  "swift",
  "typescript",
  "vbnet",
  "vim",
  "wasm",
  "xml",
  "yaml",
];

export function entrySource(packageDirectory) {
  const module = (path) => JSON.stringify(join(packageDirectory, "lib", path));
  return [
    `import hljs from ${module("core.js")};`,
    ...languages.map(
      (name, index) =>
        `import language${index} from ${module(`languages/${name}.js`)};`,
    ),
    ...languages.map(
      (name, index) =>
        `hljs.registerLanguage(${JSON.stringify(name)}, language${index});`,
    ),
    "globalThis.hljs = hljs;",
  ].join("\n");
}

export function licenseHeader(version) {
  return [
    "/*!",
    `  Highlight.js v${version} with ${languages.length} languages`,
    "  (c) 2006-2025 Josh Goebel <hello@joshgoebel.com> and other contributors",
    "  License: BSD-3-Clause",
    " */",
    "",
  ].join("\n");
}

if (import.meta.main) {
  const packageDirectory = resolve(process.argv[2] ?? "");
  const { version } = JSON.parse(
    readFileSync(join(packageDirectory, "package.json"), "utf8"),
  );
  const workspace = mkdtempSync(join(tmpdir(), "edith-highlight-"));
  const entry = join(workspace, "entry.js");
  writeFileSync(entry, entrySource(packageDirectory));
  const result = await Bun.build({
    entrypoints: [entry],
    format: "iife",
    minify: true,
  });
  rmSync(workspace, { recursive: true, force: true });
  if (!result.success) {
    console.error(result.logs.join("\n"));
    process.exit(1);
  }
  const destination = resolve(
    import.meta.dir,
    "../Packages/Edith/Vendor/Highlighter/Resources/highlight.min.js",
  );
  writeFileSync(
    destination,
    licenseHeader(version) + (await result.outputs[0].text()),
  );
  console.log(`wrote ${destination}`);
}
