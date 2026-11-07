import {
  categories,
  categoryOf,
  featured,
  highlights,
  keycaps,
  surfaces,
  tile,
} from "./data.mjs";
import {
  brew,
  command,
  copyButton,
  dmg,
  escapeHtml,
  icon,
  repo,
  shot,
} from "./layout.mjs";

const facts = {
  extensions: 41,
  studioTools: 108,
  pdfTools: 37,
  dmg: "",
  version: "",
  dmgBefore: "36.9 MB",
  idleMemory: "22 MB",
};

export function setRelease(release, extensionCount) {
  facts.dmg = `${(release.dmgBytes / 1_000_000).toFixed(1)} MB`;
  facts.version = release.version;
  facts.extensions = extensionCount;
}

const dmgSize = () => `<span data-dmg-size>${facts.dmg}</span>`;

function eyebrow(text) {
  return `<p class="eyebrow">${text}</p>`;
}

function downloadButtons({ center = false } = {}) {
  return `<div class="cta-row${center ? " center" : ""}">
  <a class="btn btn-gold btn-lg" href="${dmg}">${icon("arrowDown")}<span>Download for macOS</span></a>
  <div class="command command-lg"><code><span class="prompt" aria-hidden="true">$</span>${escapeHtml(brew)}</code>${copyButton(brew)}</div>
</div>
<p class="cta-meta${center ? " center" : ""}">Free and open source · macOS 14 or later on Apple silicon · ${dmgSize()} download</p>`;
}

function extensionCard(extension, { compact = false } = {}) {
  const category = categoryOf(extension.category);
  const hotkey = extension.hotkeys[0]
    ? `<span class="keys">${keycaps(extension.hotkeys[0].shortcut)}</span>`
    : "";
  return `<a class="ext-card${compact ? " compact" : ""}" href="/extensions/${extension.id}.html" data-category="${extension.category}" data-search="${escapeHtml(`${extension.title} ${extension.id} ${extension.tagline} ${category.title}`.toLowerCase())}">
  ${tile(extension)}
  <span class="ext-card-body">
    <span class="ext-card-title">${escapeHtml(extension.title)}${extension.category === "labs" ? '<span class="pill pill-soft">Labs</span>' : ""}</span>
    <span class="ext-card-tagline">${escapeHtml(extension.tagline)}</span>
    ${compact || !hotkey ? "" : `<span class="ext-card-meta">${hotkey}</span>`}
  </span>
  ${icon("chevronRight", "icon chevron")}
</a>`;
}

const pillars = () => [
  {
    icon: "puzzle",
    title: "A marketplace, not a monolith",
    text: `The app ships small and you add what you use. ${facts.extensions} extensions install in seconds, update on their own and remove cleanly.`,
    href: "/extensions/",
  },
  {
    icon: "herdr",
    title: "Built for coding agents",
    text: "Claude Code, Codex and Cursor can drive Edith over MCP. Every command becomes a tool, and anything destructive waits for a confirm.",
    href: "/agents.html",
  },
  {
    icon: "usage",
    title: "Know what agents cost",
    text: "Tokens, cost and rate limits by day, model and project, read from files already on your Mac.",
    href: "/extensions/usage.html",
  },
  {
    icon: "studio",
    title: "Every file tool, offline",
    text: `Studio has ${facts.studioTools} tools for PDFs, images, video and audio. Merge, sign, redact, compress and convert without uploading anything.`,
    href: "/extensions/studio.html",
  },
  {
    icon: "downloads",
    title: "Save anything from a link",
    text: "Paste a YouTube, Instagram, TikTok, X or Reddit link and the file lands on your Mac.",
    href: "/extensions/downloads.html",
  },
  {
    icon: "attention",
    title: "See where your day went",
    text: "Attention tracks screen time by app and site, your focus, and how long your agents worked.",
    href: "/extensions/attention.html",
  },
  {
    icon: "notchShelf",
    title: "Your notch, finally useful",
    text: "Park files, glance at agents and music, and get alerts in the notch. Clipboard history is one shortcut away.",
    href: "/extensions/notchShelf.html",
  },
  {
    icon: "machines",
    title: "Your machines and terminals",
    text: "Watch servers and containers over SSH, open terminals, browse files, and run agents on every box.",
    href: "/extensions/machines.html",
  },
];

function pillarGrid() {
  return `<div class="pillars">${pillars()
    .map(
      (pillar) => `<a class="pillar reveal" href="${pillar.href}">
  <span class="pillar-icon">${icon(pillar.icon)}</span>
  <h3>${pillar.title}</h3>
  <p>${pillar.text}</p>
  <span class="link-arrow">Learn more ${icon("arrowRight")}</span>
</a>`,
    )
    .join("")}</div>`;
}

function spotlight({
  id,
  kicker,
  title,
  text,
  points,
  image,
  reverse = false,
  href,
}) {
  return `<section class="spotlight${reverse ? " reverse" : ""}" id="${id}">
  <div class="spotlight-copy reveal">
    ${eyebrow(kicker)}
    <h2>${title}</h2>
    <p class="lead">${text}</p>
    <ul class="checks">${points.map((point) => `<li>${icon("check")}<span>${point}</span></li>`).join("")}</ul>
    <a class="link-arrow" href="${href}">Explore ${escapeHtml(kicker)} ${icon("arrowRight")}</a>
  </div>
  <div class="spotlight-media reveal">${shot(image)}</div>
</section>`;
}

function categoryOverview(extensions) {
  return `<div class="suites">${categories
    .filter((category) => category.id !== "labs")
    .map((category) => {
      const members = extensions.filter(
        (extension) => extension.category === category.id,
      );
      return `<a class="suite reveal" href="/extensions/#${category.id}">
  <span class="suite-head"><span class="pillar-icon">${icon(category.icon)}</span><span class="suite-count">${members.length}</span></span>
  <h3>${category.title}</h3>
  <p>${category.subtitle}</p>
  <span class="suite-icons">${members
    .slice(0, 8)
    .map((extension) => tile(extension, "xs"))
    .join("")}</span>
</a>`;
    })
    .join("")}</div>`;
}

const stats = () => [
  [String(facts.extensions), "extensions to choose from"],
  [String(facts.studioTools), "Studio tools for your files"],
  [() => dmgSize(), `download, down from ${facts.dmgBefore}`],
  ["~0%", `CPU at idle, about ${facts.idleMemory} of memory`],
];

function statBand() {
  return `<section class="stats reveal" aria-label="Edith in numbers">${stats()
    .map(
      ([value, label]) =>
        `<div class="stat"><strong>${typeof value === "function" ? value() : value}</strong><span>${label}</span></div>`,
    )
    .join("")}</section>`;
}

export function home(extensions, screenshots) {
  const featuredCards = featured
    .map((id) => extensions.find((extension) => extension.id === id))
    .map((extension) => extensionCard(extension, { compact: true }))
    .join("");
  return `<section class="hero">
  <div class="hero-glow" aria-hidden="true"></div>
  <div class="wrap hero-inner">
    <a class="announce reveal" href="#film"><span class="pill pill-gold">New</span><span>Watch the launch film</span>${icon("arrowRight")}</a>
    <img class="hero-mark reveal" src="/app-icon-512.png" alt="" width="132" height="132" />
    <h1 class="reveal">Every tool your Mac is missing.<br /><span class="gold-text">One app.</span></h1>
    <p class="hero-lead reveal">Edith is a native control center for macOS. Pick from ${facts.extensions} extensions, let your coding agents drive it, and keep every byte on your Mac.</p>
    <div class="reveal">${downloadButtons({ center: true })}</div>
  </div>
  <div class="wrap hero-shot reveal">${shot(screenshots.usage, { className: "shot-hero", eager: true })}</div>
</section>
<div class="wrap">${statBand()}</div>
<section class="section wrap" id="film">
  <div class="section-head center reveal">
    ${eyebrow("The launch film")}
    <h2>Eighty seconds of Edith.</h2>
    <p class="lead">Real screens, real recordings. See the marketplace, agents working over MCP, Studio, Downloads and more.</p>
  </div>
  <div class="film reveal"><video data-player controls preload="none" playsinline poster="/media/edith-launch.jpg" width="1920" height="1080"><source src="/media/edith-launch.mp4" type="video/mp4" /></video></div>
</section>
<section class="section wrap">
  <div class="section-head reveal">
    ${eyebrow("Why Edith")}
    <h2>Replace a dock full of utilities.</h2>
    <p class="lead">Launchers, clipboard managers, PDF tools, screen time trackers, downloaders, server dashboards. Edith brings them into one app that idles at about ${facts.idleMemory}.</p>
  </div>
  ${pillarGrid()}
</section>
${spotlight({
  id: "usage",
  kicker: "Usage",
  title: "Know exactly what your coding agents cost.",
  text: "Usage reads the history Claude Code, Codex and pi already keep on your Mac and turns it into tokens, cost and limits by day, model, project and machine.",
  points: highlights.usage.slice(0, 4),
  image: screenshots.usage,
  href: "/extensions/usage.html",
})}
${spotlight({
  id: "studio",
  kicker: "Studio",
  title: "Every file tool. Offline.",
  text: `Stop uploading private documents to PDF websites. Studio has ${facts.studioTools} tools for PDFs, images, video and audio, and every one runs on your Mac.`,
  points: highlights.studio.slice(1, 5),
  image: screenshots.studio,
  reverse: true,
  href: "/extensions/studio.html",
})}
${spotlight({
  id: "downloads",
  kicker: "Downloads",
  title: "Paste a link. Keep the file.",
  text: "Save videos, audio, photos and posts from YouTube, Instagram, TikTok, X and Reddit. Downloads keep going in the background.",
  points: highlights.downloads,
  image: screenshots.downloads,
  href: "/extensions/downloads.html",
})}
${spotlight({
  id: "attention",
  kicker: "Attention",
  title: "Screen time that respects you.",
  text: "See which apps and sites get your hours, how much deep focus you had, and how long your agents worked while you did.",
  points: highlights.attention,
  image: screenshots.attention,
  reverse: true,
  href: "/extensions/attention.html",
})}
<section class="section wrap">
  <div class="agents-band reveal">
    <div>
      ${eyebrow("Agents and MCP")}
      <h2>Your agents can use Edith too.</h2>
      <p class="lead">One command connects Claude Code, Codex, Cursor and VS Code. Every <code>ed</code> command becomes an MCP tool, so an agent can check your limits, convert a file or restart a container for you.</p>
      <a class="btn btn-ghost" href="/agents.html">How agents use Edith ${icon("arrowRight")}</a>
    </div>
    <div class="terminal" role="img" aria-label="Terminal running ed mcp install">
      <div class="terminal-bar"><span></span><span></span><span></span></div>
      <pre><code><span class="t-prompt">$</span> ed mcp install --client all
<span class="t-ok">claude</span>  created   ~/.claude.json
<span class="t-ok">codex</span>   created   ~/.codex/config.toml
<span class="t-ok">cursor</span>  created   ~/.cursor/mcp.json
<span class="t-dim">Restart the client, then ask it to call edith_catalog.</span></code></pre>
    </div>
  </div>
</section>
<section class="section wrap">
  <div class="section-head reveal">
    ${eyebrow("Extensions")}
    <h2>${facts.extensions} extensions. Install only what you need.</h2>
    <p class="lead">Each one is signed, verified before it runs, and stops when you are not using it.</p>
  </div>
  ${categoryOverview(extensions)}
  <div class="featured reveal">
    <h3 class="featured-title">Popular right now</h3>
    <div class="ext-grid compact">${featuredCards}</div>
  </div>
  <div class="center-row reveal"><a class="btn btn-ghost" href="/extensions/">Browse all ${facts.extensions} extensions ${icon("arrowRight")}</a></div>
</section>
<section class="section wrap">
  <div class="trust reveal">
    <div class="trust-item">${icon("lock")}<h3>Local first</h3><p>No account and no telemetry. Your history, files and usage stay on your Mac.</p></div>
    <div class="trust-item">${icon("bolt")}<h3>Fast and native</h3><p>SwiftUI, not Electron. About 0% CPU and ${facts.idleMemory} of memory with the panel closed.</p></div>
    <div class="trust-item">${icon("code")}<h3>Open source</h3><p>GPL-3.0 on GitHub. Read every line, build it yourself, send a pull request.</p></div>
    <div class="trust-item">${icon("shield")}<h3>Signed and notarized</h3><p>Releases are signed with Developer ID and notarized by Apple. Extensions are verified before they run.</p></div>
  </div>
</section>
${finalCta()}`;
}

function finalCta() {
  return `<section class="section wrap">
  <div class="final reveal">
    <img src="/app-icon-512.png" alt="" width="96" height="96" />
    <h2>Get Edith.</h2>
    <p class="lead">Free forever. No account. One app instead of twelve.</p>
    ${downloadButtons({ center: true })}
  </div>
</section>`;
}

function pageHero({ kicker, title, lead, extra = "" }) {
  return `<section class="page-hero">
  <div class="hero-glow small" aria-hidden="true"></div>
  <div class="wrap">
    ${eyebrow(kicker)}
    <h1>${title}</h1>
    ${lead ? `<p class="hero-lead">${lead}</p>` : ""}
    ${extra}
  </div>
</section>`;
}

const featureGroups = () => [
  {
    id: "platform",
    kicker: "Platform",
    title: "One small app that grows with you.",
    items: [
      [
        "puzzle",
        "Extension marketplace",
        `Browse ${facts.extensions} extensions by suite, install with one click, and remove them without leftovers. The base download is ${facts.dmg}, down from ${facts.dmgBefore}.`,
      ],
      [
        "shield",
        "Verified packages",
        "Every extension is signed by the same team as the app and checked before it runs. The catalog itself is signed.",
      ],
      [
        "sync",
        "Automatic updates",
        "The app updates itself through Sparkle, and extensions update in the background.",
      ],
      [
        "bolt",
        "Work stops when unseen",
        "Extensions start on demand, and closing a page tears down its timers and jobs. Per-frame UI only redraws while it is visible.",
      ],
      [
        "home",
        "Home and notch you arrange",
        "Pick which cards show on Home and in the notch, and in what order.",
      ],
      [
        "palette",
        "Themes",
        "Light, dark and accent themes that every extension follows.",
      ],
    ],
  },
  {
    id: "agents",
    kicker: "Agents",
    title: "Made for the way you code now.",
    items: [
      [
        "herdr",
        "MCP server",
        "ed mcp serves every Edith command to Claude Code, Codex, Cursor and VS Code. Destructive actions preview first and need confirm.",
      ],
      [
        "usage",
        "Usage and limits",
        "Tokens, cost and rate limits across Claude, Codex, Cursor and pi, with alerts and a menu bar readout.",
      ],
      [
        "columns",
        "Agent board",
        "Every coding agent in Herdr on this Mac and your SSH machines, grouped by what it is doing. Get told when one is blocked.",
      ],
      [
        "quinjet",
        "Code review",
        "Read pull requests and follow live changes in a focused terminal workspace.",
      ],
      [
        "plugins",
        "Skills for agents",
        "One-click skills that teach agents how to drive Edith.",
      ],
      [
        "companion",
        "Private memory",
        "Notes, voice memos and files in a store on a machine you choose, with cited answers.",
      ],
    ],
  },
  {
    id: "desk",
    kicker: "Desk",
    title: "Hotkey tools for every minute of the day.",
    items: [
      [
        "bifrost",
        "Launcher",
        "Open apps, do math and unit conversions, and search files, clipboard history, snippets and quicklinks from one bar.",
      ],
      [
        "clipboard",
        "Clipboard history",
        "Everything you copy, searchable, with pins and quick picks. Password managers are ignored by default.",
      ],
      [
        "notchShelf",
        "Notch shelf",
        "Park files, glance at agents and music, browse the web and get alerts in the notch.",
      ],
      [
        "colorPicker",
        "Color picker",
        "A magnifier for any pixel, copied as hex, RGB, HSL or code.",
      ],
      [
        "emoji",
        "Emoji picker",
        "Every emoji your Mac can draw, typed where your cursor is.",
      ],
      [
        "focusDim",
        "Focus dim",
        "Darken everything except the window you are working in.",
      ],
    ],
  },
  {
    id: "media",
    kicker: "Media",
    title: "Files, recordings and calls, handled.",
    items: [
      [
        "studio",
        "Studio",
        `${facts.studioTools} offline tools, including ${facts.pdfTools} for PDFs. Merge, sign, redact, remove backgrounds, compress and edit video on a timeline.`,
      ],
      [
        "downloads",
        "Downloads",
        "Save from YouTube, Instagram, TikTok, X and Reddit in the background.",
      ],
      [
        "timeLapse",
        "Screen recorder",
        "Record a display or windows, or speed a long session into a time-lapse.",
      ],
      [
        "virtualCamera",
        "Virtual camera",
        "One camera for Zoom, Meet and FaceTime with framing, looks, backgrounds and away cards.",
      ],
      [
        "music",
        "Music",
        "Your music folder, YouTube audio, Spotify and Apple Music, controlled from anywhere.",
      ],
      [
        "socialManager",
        "Social manager",
        "Every social account signed in side by side, grouped by person, brand or client.",
      ],
    ],
  },
  {
    id: "developer",
    kicker: "Developer and data",
    title: "The tools you would otherwise keep in a browser tab.",
    items: [
      [
        "database",
        "Database",
        "PostgreSQL, MySQL, SQLite, MongoDB, Redis and more, with previews before risky changes.",
      ],
      [
        "machines",
        "Machines",
        "CPU, memory, disks, terminals, files and Docker for every machine you reach over SSH.",
      ],
      [
        "attention",
        "Attention",
        "Screen time by app and site, focus time, and how long your agents worked.",
      ],
      [
        "codeStats",
        "Code stats",
        "Commits, lines, streaks and languages across every repository you own.",
      ],
      [
        "seoAudit",
        "Site audit",
        "Titles, descriptions, headings, share cards and Lighthouse scores, page by page.",
      ],
      [
        "latex",
        "LaTeX",
        "Write .tex with a live PDF preview, locally or through GitHub.",
      ],
    ],
  },
  {
    id: "utilities",
    kicker: "Mac utilities",
    title: "Housekeeping, without the extra apps.",
    items: [
      [
        "appMaintenance",
        "App updates",
        "Check apps and Homebrew for updates, install verified disk images and uninstall cleanly.",
      ],
      [
        "cleaner",
        "Cleaner",
        "Find build caches, package downloads and old Xcode data. Everything goes to the Trash first.",
      ],
      [
        "blitztree",
        "Disk map",
        "See what uses your disk as blocks you can click into.",
      ],
      [
        "lidAwake",
        "Lid awake",
        "Keep working with the lid closed, with timers and battery floors.",
      ],
      [
        "micMute",
        "Mic mute",
        "Mute every microphone with one shortcut, from any app.",
      ],
      [
        "presenter",
        "Presenter",
        "Blur costs, music and calendar entries automatically while you share your screen.",
      ],
    ],
  },
];

export function features(extensions, screenshots) {
  const byIcon = (name) =>
    extensions.find((extension) => extension.iconName === name);
  const groups = featureGroups()
    .map(
      (group) => `<section class="section wrap feature-group" id="${group.id}">
  <div class="section-head reveal">${eyebrow(group.kicker)}<h2>${group.title}</h2></div>
  <div class="feature-grid">${group.items
    .map(([name, title, text]) => {
      const extension = byIcon(name);
      const href = extension ? `/extensions/${extension.id}.html` : "";
      const inner = `<span class="pillar-icon">${icon(name)}</span><h3>${title}</h3><p>${escapeHtml(text).replace("ed mcp", "<code>ed mcp</code>")}</p>`;
      return href
        ? `<a class="feature reveal" href="${href}">${inner}</a>`
        : `<div class="feature reveal">${inner}</div>`;
    })
    .join("")}</div>
</section>`,
    )
    .join("");
  const jump = featureGroups()
    .map((group) => `<a href="#${group.id}">${group.kicker}</a>`)
    .join("");
  return `${pageHero({
    kicker: "Features",
    title:
      'Everything Edith does, <span class="gold-text">in one place.</span>',
    lead: `A native Mac app with ${facts.extensions} extensions across agents, desk tools, media, developer tools and Mac housekeeping.`,
    extra: `<nav class="jump" aria-label="Feature groups">${jump}</nav>`,
  })}
<div class="wrap">${shot(screenshots.extensions, { className: "shot-wide reveal", eager: true })}</div>
${groups}
<section class="section wrap" id="performance">
  <div class="section-head reveal">${eyebrow("Performance")}<h2>Built to live in your menu bar forever.</h2><p class="lead">Native SwiftUI, not Electron. Measured on Apple M4 Pro, CPU as a share of one core and memory as physical footprint.</p></div>
  <div class="table-wrap reveal"><table class="perf">
    <thead><tr><th scope="col">State</th><th scope="col">CPU</th><th scope="col">Memory</th></tr></thead>
    <tbody>
      <tr><th scope="row">Idle, panel closed</th><td>~0%</td><td>~22 MB</td></tr>
      <tr><th scope="row">Music playing, panel closed</th><td>~1%</td><td>~40 MB</td></tr>
      <tr><th scope="row">Music paused</th><td>&lt;1%</td><td>~40 MB</td></tr>
    </tbody>
  </table></div>
</section>
<section class="section wrap" id="privacy">
  <div class="trust reveal">
    <div class="trust-item">${icon("lock")}<h3>No account, no telemetry</h3><p>Edith never phones home. Rate-limit checks go straight from your Mac to your provider.</p></div>
    <div class="trust-item">${icon("eyeOff")}<h3>Presenter mode</h3><p>Blurs spend, music and calendar entries while you share your screen, and turns on by itself.</p></div>
    <div class="trust-item">${icon("cloud")}<h3>Optional iCloud backup</h3><p>Merge selected app data across your own Macs, and nowhere else.</p></div>
    <div class="trust-item">${icon("code")}<h3>GPL-3.0</h3><p>Every line is on GitHub. No paid tier, no licence key.</p></div>
  </div>
</section>
${finalCta()}`;
}

export function agents(extensions) {
  const agentExtensions = extensions.filter(
    (extension) => extension.category === "agents",
  );
  const clients = [
    [
      "Claude Code",
      "claude mcp add --scope user edith -- /Applications/Edith.app/Contents/MacOS/ed mcp",
    ],
    [
      "Codex",
      "codex mcp add edith -- /Applications/Edith.app/Contents/MacOS/ed mcp",
    ],
    ["Cursor", "ed mcp install --client cursor"],
    ["VS Code", "ed mcp install --client vscode"],
  ];
  return `${pageHero({
    kicker: "Agents and MCP",
    title:
      'Give your coding agents <span class="gold-text">a whole Mac toolkit.</span>',
    lead: "Edith speaks MCP. Connect Claude Code, Codex, Cursor or VS Code once, and every Edith command becomes a tool your agent can call, with the same safety rules as the command line.",
    extra: `<div class="cta-row">${command("ed mcp install --client all")}</div>`,
  })}
<section class="section wrap">
  <div class="steps-row">
    <div class="step-card reveal"><span class="step-num">1</span><h3>Connect</h3><p>Run <code>ed mcp install --client all</code>, or press Connect all in Settings, then Agents. Edith finds every client on your Mac.</p></div>
    <div class="step-card reveal"><span class="step-num">2</span><h3>Discover</h3><p>The agent calls <code>edith_catalog</code> to see each extension, whether it is installed, and example commands.</p></div>
    <div class="step-card reveal"><span class="step-num">3</span><h3>Act</h3><p>It calls tools like <code>edith_usage_limits</code> or <code>edith_studio_pdf_merge</code> and gets the command's JSON back.</p></div>
  </div>
</section>
<section class="section wrap">
  <div class="agents-band reveal">
    <div>
      ${eyebrow("Safe by default")}
      <h2>Agents preview before they change anything.</h2>
      <p class="lead">Commands that change or remove something return a preview until the call passes <code>confirm</code>. A call that slips <code>--yes</code> into its arguments is refused, so confirm is the only way to apply.</p>
      <ul class="checks">
        <li>${icon("check")}<span>Tools exist only for extensions you have enabled.</span></li>
        <li>${icon("check")}<span>Installing an extension asks first, then the tool list refreshes.</span></li>
        <li>${icon("check")}<span>Every tool returns the same JSON as <code>ed ... --json</code>.</span></li>
      </ul>
    </div>
    <div class="terminal" role="img" aria-label="An agent calling Edith tools">
      <div class="terminal-bar"><span></span><span></span><span></span></div>
      <pre><code><span class="t-dim">agent</span>  edith_catalog {"query": "pdf"}
<span class="t-ok">edith</span>  studio · installed · 108 tools
<span class="t-dim">agent</span>  edith_studio_pdf_merge {"arguments": ["a.pdf", "b.pdf"]}
<span class="t-ok">edith</span>  {"output": "merged.pdf", "pages": 14}
<span class="t-dim">agent</span>  edith_usage_limits {"arguments": ["--refresh"]}
<span class="t-ok">edith</span>  {"claude": {"session": 0.42, "weekly": 0.18}}</code></pre>
    </div>
  </div>
</section>
<section class="section wrap">
  <div class="section-head reveal">${eyebrow("Clients")}<h2>Works with the agents you already use.</h2><p class="lead">Use the one-step installer, or register Edith yourself.</p></div>
  <div class="client-grid">${clients
    .map(
      ([name, line]) =>
        `<div class="client reveal"><h3>${name}</h3>${command(line)}</div>`,
    )
    .join("")}</div>
</section>
<section class="section wrap">
  <div class="section-head reveal">${eyebrow("Agents & Terminal")}<h2>Extensions built around agents.</h2></div>
  <div class="ext-grid">${agentExtensions.map((extension) => extensionCard(extension)).join("")}</div>
</section>
<section class="section wrap">
  <div class="section-head reveal">${eyebrow("Command line")}<h2>Everything is scriptable.</h2><p class="lead">The bundled <code>ed</code> command talks to the running app. Results are JSON, errors are JSON on stderr, and exit codes are stable.</p></div>
  <div class="terminal reveal wide">
    <div class="terminal-bar"><span></span><span></span><span></span></div>
    <pre><code><span class="t-prompt">$</span> ed extensions install clipboard
<span class="t-prompt">$</span> ed clipboard ls --category link --limit 5
<span class="t-prompt">$</span> ed usage summary --json
<span class="t-prompt">$</span> ed machines ls
<span class="t-prompt">$</span> ed studio edit render cut.openscreen --output delivery.mp4</code></pre>
  </div>
  <div class="center-row reveal"><a class="btn btn-ghost" href="${repo}/tree/main/docs/cli">Read the full CLI reference ${icon("external")}</a></div>
</section>
${finalCta()}`;
}

export function download() {
  return `${pageHero({
    kicker: "Download",
    title: 'Get <span class="gold-text">Edith.</span>',
    lead: `Free and open source. ${facts.dmg} to download, then add the extensions you want.`,
  })}
<section class="section wrap">
  <div class="download-grid">
    <div class="download-card reveal">
      <span class="pillar-icon">${icon("appDownload")}</span>
      <h2>Disk image</h2>
      <p>Open the DMG and drag Edith into Applications.</p>
      <a class="btn btn-gold btn-lg" href="${dmg}">${icon("arrowDown")}<span>Download Edith.dmg</span></a>
      <p class="fine">Version <span data-version>${facts.version}</span> · ${dmgSize()} · Signed with Developer ID and notarized by Apple.</p>
    </div>
    <div class="download-card reveal">
      <span class="pillar-icon">${icon("homebrew")}</span>
      <h2>Homebrew</h2>
      <p>Taps, installs the app and puts <code>ed</code> and <code>edith</code> on your PATH.</p>
      ${command(brew)}
      <p class="fine">Edith updates itself. To force Homebrew, run <code>brew upgrade --cask --greedy edith</code>.</p>
    </div>
  </div>
</section>
<section class="section wrap">
  <div class="section-head reveal">${eyebrow("Requirements")}<h2>What you need.</h2></div>
  <div class="steps-row">
    <div class="step-card reveal">${icon("laptop")}<h3>macOS 14 or later</h3><p>Sonoma, Sequoia and newer. Audio Mixer needs macOS 14.4.</p></div>
    <div class="step-card reveal">${icon("cpu")}<h3>Apple silicon</h3><p>M1 or newer. Intel Macs are not supported.</p></div>
    <div class="step-card reveal">${icon("folder")}<h3>A little space</h3><p>The app is small. Extensions download only when you install them.</p></div>
  </div>
</section>
<section class="section wrap">
  <div class="section-head reveal">${eyebrow("First launch")}<h2>Up and running in a minute.</h2></div>
  <ol class="timeline">
    <li class="reveal"><span class="step-num">1</span><div><h3>Open Edith</h3><p>It lives in your menu bar. Press <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> to open the panel from anywhere.</p></div></li>
    <li class="reveal"><span class="step-num">2</span><div><h3>Pick your extensions</h3><p>Onboarding suggests a starter set. Add or remove any of them later from Extensions.</p></div></li>
    <li class="reveal"><span class="step-num">3</span><div><h3>Grant only what you use</h3><p>macOS asks for permissions such as Screen Recording or Accessibility only when an extension needs them.</p></div></li>
    <li class="reveal"><span class="step-num">4</span><div><h3>Connect your agents</h3><p>Optional. Run <code>ed mcp install --client all</code> or use Settings, then Agents.</p></div></li>
  </ol>
</section>
<section class="section wrap">
  <div class="section-head reveal">${eyebrow("Uninstall")}<h2>Leaving is easy too.</h2><p class="lead">Quit Edith and move it to the Trash, or remove it with Homebrew. <code>ed uninstall</code> also removes the command line tools it installed.</p></div>
  ${command("brew uninstall --cask edith")}
</section>`;
}

const faqGroups = () => [
  {
    title: "The basics",
    items: [
      [
        "What is Edith?",
        `A native macOS app that replaces a shelf of single-purpose utilities. It is built from ${facts.extensions} extensions, from clipboard history and a launcher to agent usage tracking, PDF tools and server dashboards. You install only the ones you want.`,
      ],
      [
        "How much does it cost?",
        `Nothing. Edith is free and open source under the <a href="https://www.gnu.org/licenses/gpl-3.0.html">GPL-3.0 licence</a>, with no paid tier, no licence key and no account.`,
      ],
      [
        "Which Macs does it run on?",
        "macOS 14 or later on Apple silicon. Intel Macs are not supported.",
      ],
      [
        "What changed recently?",
        `A redesigned app with a new logo, an extension marketplace that keeps the download small, an MCP server for coding agents, and new extensions such as Studio, Downloads and Attention. Every release is in the <a href="/changelog/">changelog</a>.`,
      ],
    ],
  },
  {
    title: "Extensions",
    items: [
      [
        "What is an extension?",
        "A feature you can add to Edith, such as Clipboard or Studio. Each one runs in its own process, starts when you need it and stops when you do not.",
      ],
      [
        "How do I install one?",
        "Open Extensions in the app and press Install, or run <code>ed extensions install &lt;id&gt;</code>. Updates arrive automatically.",
      ],
      [
        "Are extensions safe?",
        "They are published by the Edith project, signed by the same team as the app, and checked before they run. The catalog they come from is signed too.",
      ],
      [
        "Do more extensions slow my Mac down?",
        "Not while you are not using them. Extensions start on demand, and closing a page stops its timers and background jobs.",
      ],
      [
        "What are Labs extensions?",
        "Experiments and visual toys, such as Hinge and Window Sweaters. They are hidden from the main list in the app.",
      ],
    ],
  },
  {
    title: "Agents",
    items: [
      [
        "Which coding agents work with Edith?",
        "Claude Code, Codex, Cursor and VS Code, through MCP. Usage also reads Claude Code, Codex and pi history, and limits cover Claude, Codex and Cursor.",
      ],
      [
        "Can an agent change things without asking?",
        "No. Commands that change or remove something return a preview until the call passes confirm, and tools exist only for extensions you have enabled.",
      ],
      [
        "Does Usage read my prompts or code?",
        "No. It reads token counts, models and timestamps from the history your agents keep on your Mac. Nothing is uploaded.",
      ],
    ],
  },
  {
    title: "Privacy",
    items: [
      [
        "Does Edith send my data anywhere?",
        "No. There is no account and no telemetry. Rate-limit checks go directly from your Mac to your provider. Optional iCloud backup merges data across your own Macs only.",
      ],
      [
        "What about screen sharing?",
        "Presenter mode blurs spend, music and calendar entries while you share, and can turn on by itself when it sees a share.",
      ],
      [
        "Where does Memory store my notes?",
        "On a Mac or SSH machine you choose. Edith runs no data service in between.",
      ],
    ],
  },
  {
    title: "Install and updates",
    items: [
      [
        "How does macOS verify Edith?",
        "Releases are signed with Developer ID and notarized by Apple, so Gatekeeper checks them before first launch. Always download from the official GitHub release or Homebrew tap.",
      ],
      [
        "How do updates work?",
        "Edith updates itself through Sparkle, and extensions update in the background. With Homebrew, <code>brew upgrade --cask --greedy edith</code> forces a check.",
      ],
      [
        "How do I uninstall it?",
        "Quit Edith and move it to the Trash, or run <code>brew uninstall --cask edith</code>.",
      ],
      [
        "Can I contribute?",
        `Yes. Issues and pull requests are welcome on <a href="${repo}">GitHub</a>, and the contributing guide covers building from source.`,
      ],
    ],
  },
];

export function faq() {
  return `${pageHero({
    kicker: "FAQ",
    title: 'Questions, <span class="gold-text">answered.</span>',
    lead: `Still stuck? Open an issue on <a href="${repo}/issues">GitHub</a>.`,
  })}
<section class="section wrap faq-layout">
  <nav class="faq-nav" aria-label="FAQ topics">${faqGroups()
    .map((group, index) => `<a href="#faq-${index}">${group.title}</a>`)
    .join("")}</nav>
  <div class="faq-groups">${faqGroups()
    .map(
      (group, index) =>
        `<div class="faq-group" id="faq-${index}"><h2>${group.title}</h2>${group.items
          .map(
            ([question, answer]) =>
              `<details class="faq-item"><summary>${question}${icon("chevronDown")}</summary><div class="faq-answer"><p>${answer}</p></div></details>`,
          )
          .join("")}</div>`,
    )
    .join("")}</div>
</section>
${finalCta()}`;
}

export function faqStructuredData() {
  return {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: faqGroups().flatMap((group) =>
      group.items.map(([question, answer]) => ({
        "@type": "Question",
        name: question,
        acceptedAnswer: {
          "@type": "Answer",
          text: answer.replace(/<[^>]+>/g, ""),
        },
      })),
    ),
  };
}

export function extensionsIndex(extensions) {
  const chips = [
    `<button type="button" class="chip" data-filter="all" aria-pressed="true">All <span>${extensions.length}</span></button>`,
  ]
    .concat(
      categories.map(
        (category) =>
          `<button type="button" class="chip" data-filter="${category.id}" aria-pressed="false">${category.title} <span>${extensions.filter((extension) => extension.category === category.id).length}</span></button>`,
      ),
    )
    .join("");
  const sections = categories
    .map((category) => {
      const members = extensions.filter(
        (extension) => extension.category === category.id,
      );
      return `<section class="ext-section" id="${category.id}" data-section="${category.id}">
  <div class="ext-section-head"><span class="pillar-icon">${icon(category.icon)}</span><div><h2>${category.title}</h2><p>${category.subtitle}</p></div></div>
  <div class="ext-grid">${members.map((extension) => extensionCard(extension)).join("")}</div>
</section>`;
    })
    .join("");
  return `${pageHero({
    kicker: "Extensions",
    title: `${extensions.length} extensions. <span class="gold-text">Pick yours.</span>`,
    lead: "Every extension installs in seconds, is verified before it runs, and stops when you are not using it. Open one to see what it does, how it works and how to drive it from the terminal.",
  })}
<section class="section wrap ext-browser">
  <div class="ext-tools">
    <label class="search">${icon("search")}<input type="search" placeholder="Search extensions" aria-label="Search extensions" data-ext-search /></label>
    <div class="chips" role="group" aria-label="Filter by suite">${chips}</div>
  </div>
  <p class="empty" data-ext-empty hidden>No extension matches that search.</p>
  ${sections}
</section>`;
}

export function extensionPage(extension, extensions, screenshot) {
  const category = categoryOf(extension.category);
  const siblings = extensions.filter(
    (other) =>
      other.category === extension.category && other.id !== extension.id,
  );
  const index = extensions.indexOf(extension);
  const previous =
    extensions[(index - 1 + extensions.length) % extensions.length];
  const next = extensions[(index + 1) % extensions.length];
  const points = highlights[extension.id];
  const steps = extension.steps
    .map(
      (step, number) =>
        `<li class="reveal"><span class="step-num">${number + 1}</span><div><h3>${escapeHtml(step.title)}</h3><p>${escapeHtml(step.detail)}</p></div></li>`,
    )
    .join("");
  const hotkeys = extension.hotkeys
    .map(
      (hotkey) =>
        `<div class="hotkey"><span class="keys">${keycaps(hotkey.shortcut)}</span><div><strong>${escapeHtml(hotkey.title)}</strong><span>${escapeHtml(hotkey.subtitle)}</span></div></div>`,
    )
    .join("");
  const where = surfaces(extension)
    .map(
      ([name, title, text]) =>
        `<div class="surface">${icon(name)}<div><strong>${title}</strong><span>${text}</span></div></div>`,
    )
    .join("");
  const examples = extension.examples.length
    ? `<section class="detail-block reveal"><h2>From the terminal</h2><p class="muted">Every example returns JSON with <code>--json</code>, and agents can call the same thing over MCP.</p><div class="terminal"><div class="terminal-bar"><span></span><span></span><span></span></div><pre><code>${extension.examples
        .map((line) => `<span class="t-prompt">$</span> ${escapeHtml(line)}`)
        .join("\n")}</code></pre></div>${extension.docs
        .map(
          (name) =>
            `<a class="link-arrow" href="${repo}/blob/main/docs/cli/${name}/README.md">ed ${escapeHtml(name)} reference ${icon("external")}</a>`,
        )
        .join("")}</section>`
    : "";
  const media = screenshot
    ? `<section class="detail-shot reveal">${shot(screenshot)}</section>`
    : "";
  return `<section class="page-hero ext-hero">
  <div class="hero-glow small" aria-hidden="true"></div>
  <div class="wrap">
    <nav class="crumbs" aria-label="Breadcrumb"><a href="/extensions/">Extensions</a>${icon("chevronRight")}<a href="/extensions/#${category.id}">${category.title}</a>${icon("chevronRight")}<span aria-current="page">${escapeHtml(extension.title)}</span></nav>
    <div class="ext-hero-row">
      ${tile(extension, "xl")}
      <div>
        <h1>${escapeHtml(extension.title)}</h1>
        <p class="hero-lead">${escapeHtml(extension.tagline)}</p>
        <div class="ext-tags"><span class="pill">${category.title}</span>${extension.category === "labs" ? '<span class="pill pill-soft">Labs</span>' : ""}${extension.hotkeys[0] ? `<span class="keys">${keycaps(extension.hotkeys[0].shortcut)}</span>` : ""}</div>
      </div>
    </div>
    <div class="install-row">${command(`ed extensions install ${extension.id}`)}<a class="btn btn-gold" href="/download.html">${icon("arrowDown")}<span>Get Edith</span></a></div>
  </div>
</section>
<div class="wrap detail">
  ${media}
  <div class="detail-grid">
    <div class="detail-main">
      <section class="detail-block reveal"><h2>Overview</h2><p class="lead">${escapeHtml(extension.summary)}</p>${
        points
          ? `<ul class="checks">${points.map((point) => `<li>${icon("check")}<span>${escapeHtml(point)}</span></li>`).join("")}</ul>`
          : ""
      }</section>
      <section class="detail-block"><h2 class="reveal">How it works</h2><ol class="timeline">${steps}</ol></section>
      ${examples}
    </div>
    <aside class="detail-side">
      ${hotkeys ? `<section class="side-card reveal"><h2>Shortcut</h2>${hotkeys}</section>` : ""}
      <section class="side-card reveal"><h2>Where it shows up</h2>${where}</section>
      <section class="side-card reveal"><h2>Details</h2><dl class="facts">
        <div><dt>Suite</dt><dd>${category.title}</dd></div>
        <div><dt>ID</dt><dd><code>${extension.id}</code></dd></div>
        <div><dt>Source</dt><dd><a href="${repo}/tree/main/Extensions/${extension.id}">GitHub</a></dd></div>
      </dl></section>
    </aside>
  </div>
  ${
    siblings.length
      ? `<section class="section"><div class="section-head reveal"><h2>More in ${category.title}</h2></div><div class="ext-grid">${siblings
          .map((sibling) => extensionCard(sibling))
          .join("")}</div></section>`
      : ""
  }
  <nav class="pager" aria-label="More extensions">
    <a href="/extensions/${previous.id}.html" class="pager-link">${icon("arrowLeft")}<span><small>Previous</small>${escapeHtml(previous.title)}</span></a>
    <a href="/extensions/${next.id}.html" class="pager-link next"><span><small>Next</small>${escapeHtml(next.title)}</span>${icon("arrowRight")}</a>
  </nav>
</div>`;
}

const typeLabels = {
  feat: "New",
  fix: "Fixed",
  perf: "Faster",
  revert: "Reverted",
  docs: "Docs",
  style: "Polish",
};
const visibleTypes = new Set(["feat", "fix", "perf", "revert", "style"]);
export const releasesPerPage = 25;

function parseChange(title) {
  const match = /^(\w+)(?:\(([^)]+)\))?!?:\s*(.+)$/.exec(title);
  if (!match) return { type: "other", scope: "", text: title };
  const [, type, scope = "", text] = match;
  return { type, scope, text: text.charAt(0).toUpperCase() + text.slice(1) };
}

const dayName = (date) =>
  new Date(`${date}T00:00:00Z`).toLocaleDateString("en-GB", {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  });

export function publicReleases(releases) {
  return releases
    .map((release) => ({
      ...release,
      changes: release.changes
        .map((change) => ({ ...change, ...parseChange(change.title) }))
        .filter((change) => visibleTypes.has(change.type)),
    }))
    .filter((release) => release.changes.length > 0);
}

export function changelogPath(page) {
  return page === 1 ? "/changelog/" : `/changelog/${page}.html`;
}

function changelogPager(page, pages) {
  if (pages < 2) return "";
  const windowed = [...new Set([1, page - 1, page, page + 1, pages])]
    .filter((n) => n >= 1 && n <= pages)
    .sort((a, b) => a - b);
  const links = [];
  windowed.forEach((n, index) => {
    if (index && n - windowed[index - 1] > 1)
      links.push('<span class="gap" aria-hidden="true">…</span>');
    links.push(
      n === page
        ? `<span class="current" aria-current="page">${n}</span>`
        : `<a href="${changelogPath(n)}">${n}</a>`,
    );
  });
  const previous =
    page > 1
      ? `<a class="step" href="${changelogPath(page - 1)}" rel="prev">${icon("arrowLeft")}<span>Newer</span></a>`
      : '<span class="step disabled">' +
        icon("arrowLeft") +
        "<span>Newer</span></span>";
  const next =
    page < pages
      ? `<a class="step" href="${changelogPath(page + 1)}" rel="next"><span>Older</span>${icon("arrowRight")}</a>`
      : '<span class="step disabled"><span>Older</span>' +
        icon("arrowRight") +
        "</span>";
  return `<nav class="log-pager" aria-label="Changelog pages">${previous}<div class="pages">${links.join("")}</div>${next}</nav>`;
}

export function changelog(releases, page) {
  const pages = Math.ceil(releases.length / releasesPerPage);
  const slice = releases.slice(
    (page - 1) * releasesPerPage,
    page * releasesPerPage,
  );
  const entries = slice
    .map((release) => {
      const items = release.changes
        .map(
          (change) =>
            `<li data-type="${change.type}"><span class="change-type type-${change.type}">${typeLabels[change.type]}</span><span class="change-text">${change.scope ? `<span class="scope">${escapeHtml(change.scope)}</span>` : ""}${escapeHtml(change.text)}</span><a class="pr" href="${repo}/pull/${change.pr}">#${change.pr}</a></li>`,
        )
        .join("");
      return `<article class="release" id="v${release.version}">
  <header><a class="release-version" href="${repo}/releases/tag/v${release.version}">v${release.version}</a><time datetime="${release.date}">${dayName(release.date)}</time></header>
  <ul>${items}</ul>
</article>`;
    })
    .join("");
  const first = slice[0];
  const last = slice.at(-1);
  const latest = releases[0];
  const intro =
    page === 1
      ? `<article class="latest-card reveal">
    <div class="latest-badge">${icon("sync")}</div>
    <div>
      <p class="eyebrow">Latest release</p>
      <h2>Edith <span data-version>${facts.version}</span></h2>
      <p class="lead">Released ${dayName(latest.date)}. Edith updates itself, so you are always on the newest version.</p>
      <div class="cta-row"><a class="btn btn-gold" href="${dmg}">${icon("arrowDown")}<span>Download <span data-dmg-size>${facts.dmg}</span></span></a><a class="btn btn-ghost" href="${repo}/releases">All releases on GitHub ${icon("external")}</a></div>
    </div>
  </article>`
      : "";
  return `${pageHero({
    kicker: page === 1 ? "Changelog" : `Changelog · page ${page} of ${pages}`,
    title: 'Every release, <span class="gold-text">in the open.</span>',
    lead:
      page === 1
        ? `Every user-facing change since ${dayName(releases.at(-1).date)}. Edith ships as soon as a change lands on main.`
        : `Releases v${last.version} to v${first.version}, from ${dayName(last.date)} to ${dayName(first.date)}.`,
  })}
<section class="section wrap log-section">
  ${intro}
  <div class="log-tools">
    <div class="chips" role="group" aria-label="Filter changes">
      <button type="button" class="chip" data-log-filter="all" aria-pressed="true">Everything</button>
      <button type="button" class="chip" data-log-filter="feat" aria-pressed="false">New</button>
      <button type="button" class="chip" data-log-filter="fix" aria-pressed="false">Fixed</button>
      <button type="button" class="chip" data-log-filter="perf" aria-pressed="false">Faster</button>
    </div>
  </div>
  <div class="changelog" data-changelog>${entries}</div>
  <p class="empty" data-log-empty hidden>No changes of this kind on this page. Try another page or filter.</p>
  ${changelogPager(page, pages)}
</section>`;
}

export function legal(content) {
  return `<section class="wrap prose">${content}</section>`;
}

export function notFound() {
  return `<section class="page-hero not-found">
  <div class="hero-glow small" aria-hidden="true"></div>
  <div class="wrap">
    <p class="eyebrow">404</p>
    <h1>This page is <span class="gold-text">not here.</span></h1>
    <p class="hero-lead">It may have moved in the redesign. Try one of these instead.</p>
    <div class="cta-row center"><a class="btn btn-gold" href="/">Home</a><a class="btn btn-ghost" href="/extensions/">Extensions</a><a class="btn btn-ghost" href="/faq.html">FAQ</a></div>
  </div>
</section>`;
}
