import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { categoryOf, loadExtensions, shots } from "./data.mjs";
import { dmg, escapeHtml, origin, page, repo, setIconRoot } from "./layout.mjs";
import {
  agents,
  changelog,
  changelogPath,
  download,
  extensionPage,
  extensionsIndex,
  faq,
  faqStructuredData,
  features,
  home,
  legal,
  notFound,
  publicReleases,
  releasesPerPage,
  setRelease,
} from "./pages.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const site = join(root, "apps/site");

setIconRoot(join(root, "Packages/EdithIcons/svg"));

const extensions = loadExtensions(root);
const allReleases = JSON.parse(
  readFileSync(join(here, "changelog.json"), "utf8"),
);
const releases = publicReleases(allReleases);
const release = JSON.parse(readFileSync(join(here, "release.json"), "utf8"));
setRelease(release, extensions.length);

function extensionShot(extension) {
  const name = `ext-${extension.id}`;
  if (existsSync(join(site, "shots/dark", `${name}.webp`))) {
    return { name, alt: `${extension.title} in Edith` };
  }
  return shots[extension.id];
}

const software = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "Edith",
  applicationCategory: "UtilitiesApplication",
  operatingSystem: "macOS 14 or later",
  softwareVersion: release.version,
  fileSize: `${(release.dmgBytes / 1_048_576).toFixed(1)} MB`,
  downloadUrl: dmg,
  url: `${origin}/`,
  image: `${origin}/app-icon-512.png`,
  license: "https://www.gnu.org/licenses/gpl-3.0.html",
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  description: `A native macOS control center with ${extensions.length} extensions, an MCP server for coding agents, and everything kept on your Mac.`,
};
const website = {
  "@context": "https://schema.org",
  "@type": "WebSite",
  name: "Edith",
  url: `${origin}/`,
};
const organization = {
  "@context": "https://schema.org",
  "@type": "Organization",
  name: "Edith",
  url: `${origin}/`,
  logo: `${origin}/app-icon-512.png`,
  sameAs: [repo],
};
const breadcrumbs = (items) => ({
  "@context": "https://schema.org",
  "@type": "BreadcrumbList",
  itemListElement: items.map(([name, path], index) => ({
    "@type": "ListItem",
    position: index + 1,
    name,
    item: `${origin}${path}`,
  })),
});

const outputs = new Map();
const ogPages = [];
const emit = (path, html) => outputs.set(path, html);
const render = (path, file, options) => {
  const slug = options.og;
  ogPages.push({ slug, ...options.ogData });
  emit(
    file,
    page({
      ...options,
      path,
      image: `/og/${slug}.jpg`,
      imageAlt: `${options.ogData.title}. ${options.ogData.subtitle}`,
    }),
  );
};

render("/", "index.html", {
  title: "Edith",
  description: `Edith is a native macOS control center with ${extensions.length} extensions, an MCP server for coding agents, and everything kept on your Mac. Free and open source.`,
  body: home(extensions, shots),
  video: true,
  bodyClass: "home",
  jsonLd: [website, organization, software],
  og: "home",
  ogData: {
    kicker: "Native for macOS",
    title: "Every tool your Mac is missing.",
    subtitle: "One app.",
    icon: "home",
    mark: true,
  },
});
render("/features.html", "features.html", {
  title: "Features",
  description:
    "Everything Edith does: the extension marketplace, MCP for coding agents, agent usage, Studio, Downloads, Attention, the notch, clipboard and more.",
  active: "features",
  body: features(extensions, shots),
  jsonLd: [
    breadcrumbs([
      ["Edith", "/"],
      ["Features", "/features.html"],
    ]),
  ],
  og: "features",
  ogData: {
    kicker: "Features",
    title: "Everything Edith does.",
    subtitle: "Agents, files, media, desk tools and Mac housekeeping.",
    icon: "grid",
  },
});
render("/agents.html", "agents.html", {
  title: "Agents and MCP",
  description:
    "Connect Claude Code, Codex, Cursor or VS Code to Edith over MCP. Every Edith command becomes a tool, and destructive actions preview first.",
  active: "agents",
  body: agents(extensions),
  jsonLd: [
    breadcrumbs([
      ["Edith", "/"],
      ["Agents and MCP", "/agents.html"],
    ]),
  ],
  og: "agents",
  ogData: {
    kicker: "Agents and MCP",
    title: "Your agents can use Edith.",
    subtitle: "Claude Code, Codex, Cursor and VS Code over MCP.",
    icon: "herdr",
  },
});
render("/download.html", "download.html", {
  title: "Download",
  description:
    "Download Edith for macOS 14 or later on Apple silicon, or install it with Homebrew. Free and open source.",
  active: "download",
  body: download(),
  jsonLd: [
    software,
    breadcrumbs([
      ["Edith", "/"],
      ["Download", "/download.html"],
    ]),
  ],
  og: "download",
  ogData: {
    kicker: "Download",
    title: "Get Edith.",
    subtitle: "Free and open source for macOS 14 on Apple silicon.",
    icon: "arrowDown",
  },
});
render("/faq.html", "faq.html", {
  title: "FAQ",
  description:
    "Answers about Edith: pricing, extensions, agents and MCP, privacy, installing and updating.",
  active: "faq",
  body: faq(),
  jsonLd: [
    faqStructuredData(),
    breadcrumbs([
      ["Edith", "/"],
      ["FAQ", "/faq.html"],
    ]),
  ],
  og: "faq",
  ogData: {
    kicker: "FAQ",
    title: "Questions, answered.",
    subtitle: "Pricing, extensions, agents, privacy and updates.",
    icon: "help",
  },
});

const pages = Math.ceil(releases.length / releasesPerPage);
for (let number = 1; number <= pages; number += 1) {
  const path = changelogPath(number);
  render(
    path,
    number === 1 ? "changelog/index.html" : `changelog/${number}.html`,
    {
      title: number === 1 ? "Changelog" : `Changelog, page ${number}`,
      description:
        number === 1
          ? `Every Edith release with the features, fixes and speedups in each. ${releases.length} releases so far.`
          : `Edith releases, page ${number} of ${pages}: features, fixes and speedups.`,
      body: changelog(releases, number),
      jsonLd: [
        breadcrumbs([
          ["Edith", "/"],
          ["Changelog", "/changelog/"],
        ]),
      ],
      og: "changelog",
      ogData: {
        kicker: "Changelog",
        title: "Every release, in the open.",
        subtitle: `${allReleases.length} releases and counting.`,
        icon: "history",
      },
    },
  );
}

render("/extensions/", "extensions/index.html", {
  title: "Extensions",
  description: `Browse all ${extensions.length} Edith extensions: agents, desk tools, media, developer tools and Mac utilities.`,
  active: "extensions",
  body: extensionsIndex(extensions),
  jsonLd: [
    breadcrumbs([
      ["Edith", "/"],
      ["Extensions", "/extensions/"],
    ]),
  ],
  og: "extensions",
  ogData: {
    kicker: "Extensions",
    title: `${extensions.length} extensions.`,
    subtitle: "Install only what you need.",
    icon: "puzzle",
  },
});
for (const extension of extensions) {
  const category = categoryOf(extension.category);
  render(
    `/extensions/${extension.id}.html`,
    `extensions/${extension.id}.html`,
    {
      title: `${extension.title} extension`,
      description: `${extension.tagline} ${extension.summary}`,
      active: "extensions",
      body: extensionPage(extension, extensions, extensionShot(extension)),
      jsonLd: [
        breadcrumbs([
          ["Edith", "/"],
          ["Extensions", "/extensions/"],
          [category.title, `/extensions/#${category.id}`],
          [extension.title, `/extensions/${extension.id}.html`],
        ]),
      ],
      og: `ext-${extension.id}`,
      ogData: {
        kicker: category.title,
        title: extension.title,
        subtitle: extension.tagline,
        icon: extension.iconName,
        extension: true,
      },
    },
  );
}
for (const [name, title, description, icon] of [
  [
    "privacy",
    "Privacy Policy",
    "Edith's privacy policy. Local-first by design: no accounts, no telemetry, and explicit controls for optional self-hosted Companion data.",
    "lock",
  ],
  [
    "terms",
    "Terms of Use",
    "The terms for using Edith, a free and open source macOS app licensed under the GPL-3.0.",
    "doc",
  ],
]) {
  render(`/${name}.html`, `${name}.html`, {
    title,
    description,
    body: legal(readFileSync(join(here, "content", `${name}.html`), "utf8")),
    og: name,
    ogData: {
      kicker: "Edith",
      title,
      subtitle:
        name === "privacy"
          ? "No account. No telemetry. Your data stays on your Mac."
          : "Free and open source under the GPL-3.0.",
      icon,
    },
  });
}
render("/404.html", "404.html", {
  title: "Page not found",
  description: "This page is not on edith.pulkit.page.",
  body: notFound(),
  og: "home",
  ogData: {
    kicker: "Native for macOS",
    title: "Every tool your Mac is missing.",
    subtitle: "One app.",
    icon: "home",
    mark: true,
  },
});

const sitemapPaths = [...outputs.keys()]
  .filter((path) => path !== "404.html")
  .map((path) => `/${path.replace(/index\.html$/, "")}`);
emit(
  "sitemap.xml",
  `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${sitemapPaths.map((path) => `  <url><loc>${escapeHtml(origin + path)}</loc><lastmod>${releases[0].date}</lastmod></url>`).join("\n")}
</urlset>
`,
);

for (const directory of ["extensions", "changelog"])
  rmSync(join(site, directory), { recursive: true, force: true });
rmSync(join(site, "changelog.html"), { force: true });
for (const [path, html] of outputs) {
  const target = join(site, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, html);
}
const unique = [
  ...new Map(ogPages.map((entry) => [entry.slug, entry])).values(),
];
writeFileSync(
  join(here, "og-pages.json"),
  `${JSON.stringify(unique, null, 2)}\n`,
);
console.log(
  `wrote ${outputs.size} files and ${unique.length} social card specs`,
);
