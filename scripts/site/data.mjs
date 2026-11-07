import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { escapeHtml, icon, iconExists } from "./layout.mjs";

export const categories = [
  {
    id: "agents",
    title: "Agents & Terminal",
    subtitle:
      "Run and review coding agents, track their limits, and reach your machines.",
    icon: "suiteAgents",
  },
  {
    id: "utilities",
    title: "Mac Utilities",
    subtitle:
      "Updates, disk cleanup, sleep control, menu bar stats and your calendar.",
    icon: "suiteUtilities",
  },
  {
    id: "desk",
    title: "Desk",
    subtitle:
      "Hotkey tools: the launcher, clipboard, pickers, the notch and focus.",
    icon: "suiteDesk",
  },
  {
    id: "media",
    title: "Media",
    subtitle:
      "Edit files, record your screen, style your camera, play and save media.",
    icon: "suiteMedia",
  },
  {
    id: "developer",
    title: "Developer & Data",
    subtitle:
      "Databases, code growth, site audits, LaTeX and where your time goes.",
    icon: "suiteDeveloper",
  },
  {
    id: "labs",
    title: "Labs",
    subtitle:
      "Experiments and visual toys. Hidden from the main list in the app.",
    icon: "suiteLabs",
  },
];

export const featured = [
  "usage",
  "herdr",
  "bifrost",
  "clipboard",
  "studio",
  "timeLapse",
  "music",
  "appMaintenance",
];

export const shots = {
  usage: {
    name: "usage",
    alt: "The Usage page showing tokens, cost and a daily activity heatmap for Claude Code and Codex",
  },
  studio: {
    name: "studio",
    alt: "Studio with its tool groups for PDFs, images, video and audio",
  },
  downloads: {
    name: "downloads",
    alt: "The Downloads page ready to save a link from YouTube, Instagram, TikTok, X or Reddit",
  },
  attention: {
    name: "attention",
    alt: "Attention showing where the day went by app, site and focus time",
  },
  extensions: {
    name: "extensions",
    alt: "The Extensions page in Edith, listing extensions by suite with Install buttons",
  },
};

export const highlights = {
  usage: [
    "Claude Code, Codex and pi activity attributed to the right machine, repository, worktree and chat.",
    "Claude, Codex and Cursor rate limits as live rings with countdowns and history.",
    "A menu bar readout with compact or roomy layouts and a time-aware risk tint.",
    "Threshold, ahead-of-pace, burning-hot, back-to-green and pre-reset alerts, all optional.",
    "A GitHub-style heatmap of daily spend across your whole history.",
    "Share cards for activity, tokens and milestones, from the dashboard or the CLI.",
    "Fleet usage: the same collector runs on your SSH machines and folds their agents in.",
  ],
  machines: [
    "Live CPU, memory, disks, temperatures, GPUs and processes for every host.",
    "Terminal tabs, file browsing and transfer, remote previews and saved split-pane workspaces.",
    "Docker Compose groups, resources, configuration and logs, with start, stop, restart and remove.",
    "Wake, restart or shut down hosts, and read fan speeds with automatic rollback for profile changes.",
  ],
  companion: [
    "Deploy the backend on this Mac or an SSH machine and reach it through a localhost tunnel.",
    "Give it notes, recordings, images, video and PDFs. Failed recordings wait in a local outbox.",
    "Ask questions over your own history, inspect citations, or ask three lenses for a second opinion.",
    "Export, import, erase single episodes or wipe everything, and move the deployment any time.",
  ],
  music: [
    "Your local music folder with thumbnails, drag-to-seek, fades and auto-advance.",
    "Media keys, the menu bar, the notch and the terminal all control playback.",
    "Also controls Spotify and Apple Music.",
  ],
  clipboard: [
    "Search, category chips, and Pinned, Today and Yesterday sections.",
    "Color swatches for copied colors and Command-1 to 9 quick picks.",
    "Pause capture any time, and paste straight into the app you were in.",
  ],
  studio: [
    "108 tools in one place, 37 of them for PDFs.",
    "Merge, split, sign, redact, compress and convert PDFs.",
    "Remove image backgrounds, resize, convert and compress images.",
    "Compress and convert video and audio, or cut a video on a timeline.",
    "Everything runs on this Mac. Nothing is uploaded.",
  ],
  downloads: [
    "YouTube, Instagram, TikTok, X and Reddit links.",
    "Video, audio, photos and whole posts.",
    "Runs in the background, so you can close the window and keep working.",
  ],
  attention: [
    "Time by app and by website, with focus time for the day.",
    "How much your AI agents worked while you did.",
    "Stays on this Mac unless you turn on iCloud backup.",
  ],
  notchShelf: [
    "Drag files toward the notch to park copies for later.",
    "Glance at agents, music and alerts without leaving your work.",
    "A small browser lives there too.",
  ],
  presenter: [
    "Blurs spend figures, track names, calendar entries and agents.",
    "Turns on by itself when it detects a screen share.",
  ],
  lidAwake: [
    "Timed or lid-cycle sessions.",
    "Battery floors that stop the session before the battery runs out.",
    "Normal sleep returns automatically when the session ends.",
  ],
};

const modifiers = { control: "⌃", option: "⌥", command: "⌘", shift: "⇧" };

export function keycaps(shortcut) {
  return shortcut
    .split("+")
    .map((part) => {
      const label =
        modifiers[part] ?? (part === "space" ? "Space" : part.toUpperCase());
      return `<kbd>${escapeHtml(label)}</kbd>`;
    })
    .join("");
}

export function loadExtensions(root) {
  const manifest = JSON.parse(
    readFileSync(join(root, "Extensions/manifest.json"), "utf8"),
  );
  return manifest.map(({ id, version }) => {
    const definition = JSON.parse(
      readFileSync(join(root, "Extensions", id, "package.json"), "utf8"),
    );
    const iconName = iconExists(id) ? id : definition.icon;
    if (!iconExists(iconName)) throw new Error(`no icon for ${id}`);
    const docs = (definition.commands ?? []).filter((name) =>
      existsSync(join(root, "docs/cli", name, "README.md")),
    );
    return {
      id,
      version,
      title: definition.title,
      category: definition.category,
      iconName,
      background: Boolean(definition.background),
      commands: definition.commands ?? [],
      docs,
      hotkeys: definition.hotkeys ?? [],
      hasPage: Boolean(definition.pages?.length),
      homeCards: definition.homeCards ?? [],
      notchCards: definition.notchCards ?? [],
      notchTabs: definition.notchTabs ?? [],
      tagline: definition.guide.tagline,
      summary: definition.guide.summary,
      steps: definition.guide.steps ?? [],
      examples: definition.guide.examples ?? [],
    };
  });
}

export function categoryOf(id) {
  return categories.find((category) => category.id === id);
}

export function tile(extension, size = "md") {
  return `<span class="tile tile-${size}" aria-hidden="true">${icon(extension.iconName)}</span>`;
}

export function surfaces(extension) {
  const list = [];
  if (extension.hasPage)
    list.push([
      "sidebarLeft",
      "Its own page",
      "Opens from the sidebar, and can detach into its own window.",
    ]);
  if (extension.homeCards.length)
    list.push([
      "home",
      "Home cards",
      "Adds cards you can place on Edith's Home screen.",
    ]);
  if (extension.notchTabs.length)
    list.push([
      "notchShelf",
      "A notch tab",
      "Shows up as a tab when you open the notch.",
    ]);
  else if (extension.notchCards.length)
    list.push([
      "notchShelf",
      "Notch cards",
      "Adds cards you can pin in the notch.",
    ]);
  if (extension.hotkeys.length)
    list.push([
      "keystrokeHighlight",
      "A global shortcut",
      "Works from any app, and you can record your own.",
    ]);
  if (extension.commands.length)
    list.push([
      "terminal",
      "Command line",
      `Scriptable with <code>ed ${escapeHtml(extension.commands[0])}</code>, with JSON output.`,
    ]);
  if (extension.commands.length)
    list.push([
      "herdr",
      "Agent tools",
      `Every command is an MCP tool such as <code>edith_${escapeHtml(extension.commands[0].replaceAll("-", "_"))}</code>.`,
    ]);
  list.push(
    extension.background
      ? [
          "bolt",
          "Starts with Edith",
          "Runs quietly in the background so it is ready when you are.",
        ]
      : [
          "pause",
          "Starts on demand",
          "Loads only when you open it, and stops when you are done.",
        ],
  );
  return list;
}
