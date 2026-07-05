#!/usr/bin/env bun
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const root = import.meta.dir;
const p = (f) => `${root}/${f}`;

const tmpl = readFileSync(p("dashboard.template.html"), "utf8");
const css = readFileSync(p("css/styles.css"), "utf8");

const out = await Bun.build({
  entrypoints: [p("js/app.js")],
  target: "browser",
  format: "iife",
  minify: false,
});
if (!out.success) {
  console.error("bundle failed:\n" + out.logs.join("\n"));
  process.exit(1);
}
const js = (await out.outputs[0].text()).replace(/<\/script>/g, "<\\/script>");

let html = tmpl
  .replace(
    '<link rel="stylesheet" href="css/styles.css">',
    `<style>\n${css}</style>`,
  )
  .replace(
    '<script type="module" src="js/app.js"></script>',
    `<script>\n${js}\n</script>`,
  );

if (existsSync(p("dashboard.html"))) {
  const prev = readFileSync(p("dashboard.html"), "utf8");
  for (const id of ["usage-data", "limits-data"]) {
    const re = new RegExp(
      `<script id="${id}" type="application\\/json">[\\s\\S]*?<\\/script>`,
    );
    const m = prev.match(re);
    if (m) html = html.replace(re, m[0]);
  }
}

writeFileSync(p("dashboard.html"), html);
console.log(
  `built dashboard.html - self-contained (${(html.length / 1024).toFixed(0)} KB)`,
);
