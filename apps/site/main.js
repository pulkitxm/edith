import { currentDesktopPlatform } from "./platform.js";

const tracks = [
  {
    title: "Weightless",
    artist: "Marconi Union",
    from: "var(--color-art-coral)",
    to: "var(--color-art-rust)",
  },
  {
    title: "Nightcall",
    artist: "Kavinsky",
    from: "var(--color-art-blue)",
    to: "var(--color-art-navy)",
  },
  {
    title: "Strobe",
    artist: "deadmau5",
    from: "var(--color-art-green)",
    to: "var(--color-art-forest)",
  },
  {
    title: "Teardrop",
    artist: "Massive Attack",
    from: "var(--color-art-purple)",
    to: "var(--color-art-plum)",
  },
  {
    title: "Intro",
    artist: "The xx",
    from: "var(--color-track-gold)",
    to: "var(--color-track-ochre)",
  },
];

const sparkHeights = [
  18, 22, 20, 26, 30, 28, 34, 40, 37, 44, 48, 46, 53, 58, 55, 61, 66, 64, 68,
];

function level(index) {
  const random = Math.abs(Math.sin(index * 12.9898 + 4.1) * 43758.5453) % 1;
  return random < 0.06 ? 0 : Math.min(4, 1 + Math.floor(random * 4.2));
}

function buildHeatmaps() {
  for (const element of document.querySelectorAll("[data-rows][data-cols]")) {
    const rows = Number(element.dataset.rows) || 7;
    const columns = Number(element.dataset.cols) || 16;
    const fragment = document.createDocumentFragment();
    for (let column = 0; column < columns; column += 1) {
      for (let row = 0; row < rows; row += 1) {
        const cell = document.createElement("i");
        cell.className = `heat-${level(column * rows + row)}`;
        fragment.appendChild(cell);
      }
    }
    element.appendChild(fragment);
  }
}

function buildSparks() {
  for (const element of document.querySelectorAll("[data-spark]")) {
    for (const height of sparkHeights) {
      const bar = document.createElement("i");
      bar.style.height = `${height}%`;
      element.appendChild(bar);
    }
  }
}

function startNowPlaying() {
  const titleElement = document.querySelector("[data-title]");
  const artistElement = document.querySelector("[data-artist]");
  const artElement = document.querySelector("[data-art]");
  const progressElement = document.querySelector("[data-progress]");
  if (!titleElement || !artistElement || !artElement || !progressElement) {
    return;
  }
  let trackIndex = 0;
  let progress = 18;
  const paint = () => {
    const track = tracks[trackIndex];
    titleElement.textContent = track.title;
    artistElement.textContent = track.artist;
    artElement.style.background = `linear-gradient(145deg, ${track.from}, ${track.to})`;
  };
  paint();
  window.setInterval(() => {
    progress += 100 / 60;
    if (progress >= 100) {
      progress = 0;
      trackIndex = (trackIndex + 1) % tracks.length;
      paint();
    }
    progressElement.style.width = `${progress}%`;
  }, 100);
}

function startReveals() {
  const targets = document.querySelectorAll(
    "[data-reveal-item], [data-reveal-group] > *",
  );
  if (!("IntersectionObserver" in window) || !targets.length) {
    return;
  }
  const groups = new Map();
  for (const element of targets) {
    const parent = element.parentElement;
    const index = groups.get(parent) ?? 0;
    groups.set(parent, index + 1);
    element.dataset.reveal = "pending";
    element.style.setProperty(
      "--reveal-delay",
      `${Math.min(index * 0.07, 0.42)}s`,
    );
  }
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.dataset.reveal = "visible";
          observer.unobserve(entry.target);
        }
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.15 },
  );
  for (const element of targets) {
    observer.observe(element);
  }
}

function startPresenterDemo() {
  const demo = document.querySelector("[data-presenter-demo]");
  if (!demo) {
    return;
  }
  const badge = demo.querySelector("[data-pbadge]");
  const note = demo.querySelector("[data-pnote]");
  if (!badge || !note) {
    return;
  }
  const flip = () => {
    const enabled = demo.dataset.presenterState !== "on";
    demo.dataset.presenterState = enabled ? "on" : "off";
    badge.textContent = enabled ? "Presenter on" : "Presenter off";
    badge.style.opacity = enabled ? "1" : "0.5";
    note.textContent = enabled
      ? "Spend and track names hidden for the room."
      : "Everything visible to you.";
  };
  demo.dataset.presenterState = "off";
  flip();
  window.setInterval(flip, 2200);
}

function startPlatformDownload() {
  const platform = currentDesktopPlatform();
  if (!platform) {
    return;
  }
  const buttons = document.querySelectorAll("[data-download-os]");
  for (const button of buttons) {
    const matches = button.dataset.downloadOs === platform;
    button.hidden = !matches;
    button.classList.toggle("btn-solid", matches);
    button.classList.toggle("btn-outline", !matches);
  }
  const note = document.querySelector(".hero-note");
  if (note) {
    note.textContent =
      platform === "macos"
        ? "Free forever. Requires macOS 14+ on Apple Silicon."
        : "Free forever. Ubuntu 24.04 LTS on amd64. Native preview.";
  }
  const otherDownloads = document.querySelector("[data-other-downloads]");
  if (otherDownloads) {
    otherDownloads.hidden = false;
  }
}

function startCopyButtons() {
  for (const button of document.querySelectorAll("[data-copy]")) {
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copy);
      } catch {
        return;
      }
      const label = button.textContent;
      button.textContent = "Copied";
      setTimeout(() => {
        button.textContent = label;
      }, 1500);
    });
  }
}

function start() {
  startPlatformDownload();
  startCopyButtons();
  buildHeatmaps();
  buildSparks();
  startNowPlaying();
  startReveals();
  startPresenterDemo();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
