import { readFileSync } from "node:fs";
import { join } from "node:path";

export const origin = "https://edith.pulkit.page";
export const repo = "https://github.com/pulkitxm/edith";
export const dmg = `${repo}/releases/latest/download/Edith.dmg`;
export const brew = "brew install --cask pulkitxm/tap/edith";

let iconRoot = "";
const iconCache = new Map();

export function setIconRoot(root) {
  iconRoot = root;
}

export function iconExists(name) {
  try {
    readFileSync(join(iconRoot, `${name}.20.svg`));
    return true;
  } catch {
    return false;
  }
}

export function icon(name, className = "icon") {
  if (!iconCache.has(name)) {
    const source = readFileSync(join(iconRoot, `${name}.20.svg`), "utf8")
      .replace(/<svg[^>]*>/, "")
      .replace("</svg>", "")
      .replace(/\s+id="(primary|secondary)"/g, ' class="$1"')
      .replace(/\n\s*/g, "")
      .trim();
    iconCache.set(name, source);
  }
  return `<svg class="${className}" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" focusable="false">${iconCache.get(name)}</svg>`;
}

export function escapeHtml(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

const nav = [
  ["features", "/features.html", "Features"],
  ["extensions", "/extensions/", "Extensions"],
  ["agents", "/agents.html", "Agents"],
  ["download", "/download.html", "Download"],
  ["faq", "/faq.html", "FAQ"],
];

export function copyButton(text, label = "Copy") {
  return `<button class="copy" type="button" data-copy="${escapeHtml(text)}" aria-label="Copy ${escapeHtml(text)}">${icon("copy")}<span>${label}</span></button>`;
}

export function command(text) {
  return `<div class="command"><code><span class="prompt" aria-hidden="true">$</span>${escapeHtml(text)}</code>${copyButton(text)}</div>`;
}

function header(active) {
  const links = nav
    .map(
      ([id, href, label]) =>
        `<a href="${href}"${id === active ? ' aria-current="page"' : ""}>${label}</a>`,
    )
    .join("");
  return `<header class="site-header">
  <div class="header-inner">
    <a href="/" class="brand" aria-label="Edith home">
      <img src="/app-icon-512.png" alt="" width="30" height="30" />
      <span class="brand-name">Edith</span>
    </a>
    <nav class="nav" id="site-nav" aria-label="Main">${links}<a class="nav-github" href="${repo}">GitHub</a></nav>
    <div class="header-actions">
      <button class="theme-toggle" type="button" data-theme-toggle aria-label="Switch between light and dark">${icon("sun", "icon icon-sun")}${icon("moon", "icon icon-moon")}</button>
      <a class="btn btn-gold btn-sm header-cta" href="/download.html">${icon("arrowDown")}<span>Download</span></a>
      <button class="menu-toggle" type="button" data-menu-toggle aria-controls="site-nav" aria-expanded="false" aria-label="Open menu">${icon("menu")}</button>
    </div>
  </div>
</header>`;
}

function footer() {
  const column = (title, links) =>
    `<div class="footer-col"><h2>${title}</h2>${links
      .map(([href, label]) => `<a href="${href}">${label}</a>`)
      .join("")}</div>`;
  return `<footer class="site-footer">
  <div class="footer-inner">
    <div class="footer-brand">
      <a href="/" class="brand"><img src="/app-icon-512.png" alt="" width="30" height="30" /><span class="brand-name">Edith</span></a>
      <p>Every tool your Mac is missing, in one native app. Free and open source under the GPL-3.0.</p>
      <a class="btn btn-ghost btn-sm" href="/download.html">${icon("arrowDown")}<span>Download Edith</span></a>
    </div>
    ${column("Product", [
      ["/features.html", "Features"],
      ["/extensions/", "Extensions"],
      ["/agents.html", "Agents and MCP"],
      ["/download.html", "Download"],
      ["/changelog/", "Changelog"],
      ["/faq.html", "FAQ"],
    ])}
    ${column("Resources", [
      [`${repo}/tree/main/docs/cli`, "CLI reference"],
      [`${repo}/wiki`, "Wiki"],
      [`${repo}/releases`, "Releases"],
      [`${repo}/blob/main/SUPPORT.md`, "Support"],
    ])}
    ${column("Project", [
      [repo, "GitHub"],
      [`${repo}/blob/main/CONTRIBUTING.md`, "Contributing"],
      [`${repo}/blob/main/SECURITY.md`, "Security"],
      ["https://www.gnu.org/licenses/gpl-3.0.html", "Licence"],
    ])}
    ${column("Legal", [
      ["/privacy.html", "Privacy"],
      ["/terms.html", "Terms"],
    ])}
  </div>
  <div class="footer-base"><span>Made on a Mac, for Macs.</span><span>macOS 14+ on Apple silicon</span></div>
</footer>`;
}

export function shot(image, { className = "", eager = false } = {}) {
  const variant = (theme) => {
    const base = `/shots/${theme}/${image.name}`;
    const primary = theme === "dark";
    return `<img class="shot-${theme}" src="${base}.webp" srcset="${base}-1200.webp 1200w, ${base}.webp 2400w" sizes="(max-width: 1240px) 100vw, 1200px" alt="${primary ? escapeHtml(image.alt) : ""}"${primary ? "" : ' aria-hidden="true"'} width="2400" height="1500"${eager && primary ? ' fetchpriority="high"' : ' loading="lazy"'} decoding="async" />`;
  };
  return `<figure class="shot ${className}"><div class="shot-frame">${variant("dark")}${variant("light")}</div></figure>`;
}

export function page({
  path,
  title,
  description,
  active = "",
  image,
  imageAlt,
  body,
  video = false,
  bodyClass = "",
  jsonLd = [],
}) {
  const url = `${origin}${path}`;
  const fullTitle =
    title === "Edith"
      ? "Edith: every tool your Mac is missing"
      : `${title} · Edith`;
  const videoMeta = video
    ? `
    <meta property="og:video" content="${origin}/media/edith-launch.mp4" />
    <meta property="og:video:type" content="video/mp4" />
    <meta property="og:video:width" content="1920" />
    <meta property="og:video:height" content="1080" />`
    : "";
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="color-scheme" content="dark light" />
    <meta name="theme-color" content="#070a12" />
    <title>${escapeHtml(fullTitle)}</title>
    <meta name="description" content="${escapeHtml(description)}" />
    <link rel="canonical" href="${url}" />
    <link rel="icon" type="image/png" href="/favicon-180.png" />
    <link rel="apple-touch-icon" href="/favicon-180.png" />
    <link rel="stylesheet" href="/styles.css" />${video ? '\n    <link rel="stylesheet" href="/lib/plyr/plyr.css" />' : ""}
    <script>try{var t=localStorage.getItem("edith-theme");if(t==="light"||t==="dark")document.documentElement.dataset.theme=t}catch(e){}</script>
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="Edith" />
    <meta property="og:title" content="${escapeHtml(fullTitle)}" />
    <meta property="og:description" content="${escapeHtml(description)}" />
    <meta property="og:url" content="${url}" />
    <meta property="og:image" content="${origin}${image}" />
    <meta property="og:image:type" content="image/jpeg" />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta property="og:image:alt" content="${escapeHtml(imageAlt ?? fullTitle)}" />${videoMeta}
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="${escapeHtml(fullTitle)}" />
    <meta name="twitter:description" content="${escapeHtml(description)}" />
    <meta name="twitter:image" content="${origin}${image}" />
    <meta name="twitter:image:alt" content="${escapeHtml(imageAlt ?? fullTitle)}" />
    <meta name="author" content="Pulkit" />
    <meta name="application-name" content="Edith" />${jsonLd
      .map(
        (data) =>
          `\n    <script type="application/ld+json">${JSON.stringify(data).replaceAll("<", "\\u003c")}</script>`,
      )
      .join("")}
    <script type="module" src="/main.js"></script>
  </head>
  <body${bodyClass ? ` class="${bodyClass}"` : ""}>
    <a class="skip" href="#main">Skip to content</a>
    ${header(active)}
    <main id="main">
${body}
    </main>
    ${footer()}
  </body>
</html>
`;
}
