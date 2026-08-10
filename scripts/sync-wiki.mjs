import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

const SECTIONS = [{ dir: "docs/cli", prefix: "CLI", label: "CLI reference" }];

const READING_ORDER = [
  "getting-started",
  "conventions",
  "config",
  "app",
  "extensions",
  "permissions",
  "usage",
  "system",
  "music",
  "calendar",
  "clipboard",
  "color",
  "download",
  "apps",
  "tools",
  "shelf",
  "cleaner",
  "machines",
  "machines-remote",
  "machines-docker",
  "machines-files",
  "machines-power",
  "machines-workspace",
];

const SMALL = new Set([
  "a",
  "an",
  "the",
  "of",
  "to",
  "and",
  "in",
  "on",
  "for",
  "with",
  "vs",
]);

function cap(word) {
  return word ? word[0].toUpperCase() + word.slice(1) : word;
}

function slugSuffix(name) {
  return name
    .split("-")
    .map((seg, i) => (i > 0 && SMALL.has(seg) ? seg : cap(seg)))
    .join("-");
}

function displayTitle(name) {
  return slugSuffix(name).replaceAll("-", " ");
}

function orderOf(name) {
  const index = READING_ORDER.indexOf(name);
  return index < 0 ? READING_ORDER.length : index;
}

function ownerRepo() {
  try {
    const url = execFileSync("git", ["remote", "get-url", "origin"], {
      cwd: repoRoot,
    })
      .toString()
      .trim();
    const match = url.match(/github\.com[:/]+([^/]+)\/(.+?)(?:\.git)?$/);
    if (match) return { owner: match[1], repo: match[2] };
  } catch {}
  return { owner: "pulkitxm", repo: "edith" };
}

function isReadme(file) {
  return file.toLowerCase() === "readme.md";
}

function childOrder(root, groupDir, names) {
  const readme = path.join(root, groupDir, "README.md");
  if (!existsSync(readme)) return names;
  const text = readFileSync(readme, "utf8");
  const cited = [];
  for (const m of text.matchAll(/\]\(\.\/([A-Za-z0-9._-]+)\.md\)/g)) {
    if (!cited.includes(m[1])) cited.push(m[1]);
  }
  const known = cited.filter((n) => names.includes(n));
  return [...known, ...names.filter((n) => !known.includes(n))];
}

export function collect(root = repoRoot) {
  const docs = [];
  for (const section of SECTIONS) {
    const abs = path.join(root, section.dir);
    if (!existsSync(abs)) continue;
    const entries = readdirSync(abs, { withFileTypes: true });

    for (const entry of entries.filter((e) => e.isFile())) {
      if (!entry.name.endsWith(".md")) continue;
      const name = entry.name.replace(/\.md$/, "");
      const src = `${section.dir}/${entry.name}`;
      docs.push(
        isReadme(entry.name)
          ? {
              src,
              slug: section.prefix,
              title: "Overview",
              section: section.label,
              order: -1,
              depth: 0,
              isIndex: true,
            }
          : {
              src,
              slug: `${section.prefix}-${slugSuffix(name)}`,
              title: displayTitle(name),
              section: section.label,
              order: orderOf(name),
              depth: 0,
              isIndex: false,
            },
      );
    }

    for (const dir of entries.filter((e) => e.isDirectory())) {
      const groupDir = `${section.dir}/${dir.name}`;
      const groupSlug = `${section.prefix}-${slugSuffix(dir.name)}`;
      const files = readdirSync(path.join(root, groupDir))
        .filter((f) => f.endsWith(".md"))
        .sort();
      if (files.some(isReadme)) {
        docs.push({
          src: `${groupDir}/README.md`,
          slug: groupSlug,
          title: displayTitle(dir.name),
          section: section.label,
          order: orderOf(dir.name),
          depth: 0,
          isIndex: false,
          isGroup: true,
        });
      }
      const leaves = files
        .filter((f) => !isReadme(f))
        .map((f) => f.replace(/\.md$/, ""));
      for (const [index, leaf] of childOrder(
        root,
        groupDir,
        leaves,
      ).entries()) {
        docs.push({
          src: `${groupDir}/${leaf}.md`,
          slug: `${groupSlug}-${slugSuffix(leaf)}`,
          title: displayTitle(leaf),
          section: section.label,
          order: orderOf(dir.name),
          childOrder: index,
          depth: 1,
          parent: groupSlug,
          isIndex: false,
        });
      }
    }
  }
  return docs;
}

const { owner, repo } = ownerRepo();
const blobBase = `https://github.com/${owner}/${repo}/blob/main`;
const treeBase = `https://github.com/${owner}/${repo}/tree/main`;
const wikiDisplay = `https://github.com/${owner}/${repo}.wiki.git`;

const docs = collect();
const slugMap = new Map(docs.map((d) => [d.src, d.slug]));
const dirMap = new Map(SECTIONS.map((s) => [s.dir, s.prefix]));
for (const doc of docs) {
  if (doc.isGroup) dirMap.set(path.posix.dirname(doc.src), doc.slug);
}

export function mapTarget(target, fileDir, options = {}) {
  const root = options.root || repoRoot;
  const slugs = options.slugMap || slugMap;
  const dirs = options.dirMap || dirMap;
  const blob = options.blobBase || blobBase;
  const parts = target.split(/\s+/);
  const url = parts[0];
  const titleRest = parts.length > 1 ? ` ${parts.slice(1).join(" ")}` : "";
  if (url === "" || /^(https?:|mailto:|#)/i.test(url)) return null;
  const hash = url.indexOf("#");
  const pathPart = hash >= 0 ? url.slice(0, hash) : url;
  const anchor = hash >= 0 ? url.slice(hash) : "";
  if (pathPart === "") return null;
  const resolved = path.posix
    .normalize(path.posix.join(fileDir, pathPart))
    .replace(/\/$/, "");
  if (dirs.has(resolved)) return `${dirs.get(resolved)}${anchor}${titleRest}`;
  if (slugs.has(resolved)) return `${slugs.get(resolved)}${anchor}${titleRest}`;
  if (existsSync(path.join(root, resolved)))
    return `${blob}/${resolved}${anchor}${titleRest}`;
  return null;
}

export function rewriteLinks(content, fileDir, options = {}) {
  let inFence = false;
  return content
    .split("\n")
    .map((line) => {
      const trimmed = line.trimStart();
      if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
        inFence = !inFence;
        return line;
      }
      if (inFence) return line;
      return line.replace(/\]\(([^)]+)\)/g, (whole, target) => {
        const mapped = mapTarget(target, fileDir, options);
        return mapped === null ? whole : `](${mapped})`;
      });
    })
    .join("\n");
}

function sectionDocs(label) {
  const inSection = docs.filter((d) => d.section === label);
  const index = inSection.filter((d) => d.isIndex);
  const tops = inSection
    .filter((d) => !d.isIndex && d.depth === 0)
    .sort((a, b) => a.order - b.order || a.title.localeCompare(b.title));
  const ordered = [];
  for (const top of tops) {
    ordered.push(top);
    if (!top.isGroup) continue;
    const kids = inSection
      .filter((d) => d.parent === top.slug)
      .sort((a, b) => a.childOrder - b.childOrder);
    ordered.push(...kids);
  }
  return [...index, ...ordered];
}

function endWithNewline(text) {
  return `${text.replace(/\s*$/, "")}\n`;
}

function buildHome() {
  const lines = [
    "Reference documentation for the **Edith** command line, auto-generated from the `docs/` directory of the main repository. Edit the docs in the repo, these pages are overwritten on every push to `main`.",
    "",
    "`ed`, `edh` and `edith` are the same binary. The built-in manual is `ed guide`.",
    "",
  ];
  for (const section of SECTIONS) {
    lines.push(`## ${section.label}`, "");
    for (const doc of sectionDocs(section.label))
      lines.push(`${doc.depth ? "  " : ""}- [${doc.title}](${doc.slug})`);
    lines.push("");
  }
  return endWithNewline(lines.join("\n"));
}

function buildSidebar() {
  const lines = ["- [Home](Home)", ""];
  for (const section of SECTIONS) {
    lines.push(`**${section.label}**`, "");
    for (const doc of sectionDocs(section.label))
      lines.push(`${doc.depth ? "  " : ""}- [${doc.title}](${doc.slug})`);
    lines.push("");
  }
  return endWithNewline(lines.join("\n"));
}

function buildFooter() {
  return endWithNewline(
    `_Auto-generated from [\`docs/\`](${treeBase}/docs), edit the docs in the repo, not the wiki._`,
  );
}

export function buildPages() {
  const pages = new Map();
  for (const doc of docs) {
    const raw = readFileSync(path.join(repoRoot, doc.src), "utf8");
    const body = rewriteLinks(raw, path.posix.dirname(doc.src));
    pages.set(`${doc.slug}.md`, endWithNewline(body));
  }
  pages.set("Home.md", buildHome());
  pages.set("_Sidebar.md", buildSidebar());
  pages.set("_Footer.md", buildFooter());
  return pages;
}

function clearMarkdown(dir) {
  for (const entry of readdirSync(dir)) {
    if (entry === ".git") continue;
    if (entry.endsWith(".md")) rmSync(path.join(dir, entry), { force: true });
  }
}

function writePages(dir, pages) {
  mkdirSync(dir, { recursive: true });
  clearMarkdown(dir);
  for (const [name, content] of pages)
    writeFileSync(path.join(dir, name), content);
}

function configIdentity(dir) {
  const name = process.env.GIT_AUTHOR_NAME || "wiki-sync";
  const email =
    process.env.GIT_AUTHOR_EMAIL || "wiki-sync@users.noreply.github.com";
  execFileSync("git", ["config", "user.name", name], { cwd: dir });
  execFileSync("git", ["config", "user.email", email], { cwd: dir });
}

function pushPages(pages) {
  const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN || "";
  const auth = token ? `x-access-token:${token}@` : "";
  const wikiUrl = `https://${auth}github.com/${owner}/${repo}.wiki.git`;
  const dir = path.join(repoRoot, ".wiki-clone");
  rmSync(dir, { recursive: true, force: true });
  let cloned = false;
  try {
    execFileSync("git", ["clone", "--depth", "1", wikiUrl, dir], {
      stdio: "inherit",
    });
    cloned = true;
  } catch {
    console.log(`Wiki not initialized; bootstrapping ${wikiDisplay}`);
  }
  if (!cloned) {
    mkdirSync(dir, { recursive: true });
    execFileSync("git", ["init", "-b", "master"], {
      cwd: dir,
      stdio: "inherit",
    });
    execFileSync("git", ["remote", "add", "origin", wikiUrl], {
      cwd: dir,
      stdio: "inherit",
    });
  }
  configIdentity(dir);
  writePages(dir, pages);
  execFileSync("git", ["add", "-A"], { cwd: dir, stdio: "inherit" });
  const status = execFileSync("git", ["status", "--porcelain"], { cwd: dir })
    .toString()
    .trim();
  if (!status) {
    console.log("Wiki already up to date.");
    return;
  }
  execFileSync("git", ["commit", "-m", "docs: sync wiki from docs/"], {
    cwd: dir,
    stdio: "inherit",
  });
  execFileSync("git", ["push", "origin", "HEAD"], {
    cwd: dir,
    stdio: "inherit",
  });
  console.log(`Pushed ${pages.size} pages to ${wikiDisplay}`);
}

function main() {
  const args = process.argv.slice(2);
  const pages = buildPages();
  if (args.includes("--push")) {
    pushPages(pages);
    return;
  }
  const outIndex = args.indexOf("--out");
  const outDir =
    outIndex >= 0
      ? path.resolve(args[outIndex + 1])
      : path.join(repoRoot, ".wiki-build");
  writePages(outDir, pages);
  console.log(
    `Wrote ${pages.size} pages to ${path.relative(repoRoot, outDir) || outDir}`,
  );
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  main();
}
