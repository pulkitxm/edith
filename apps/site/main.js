import { currentDesktopPlatform } from "./platform.js";

const library = [
  {
    title: "Weightless",
    artist: "Marconi Union",
    cover: "/music/cover-1.jpg",
    seconds: 372,
  },
  {
    title: "Clair de Lune",
    artist: "Debussy",
    cover: "/music/cover-2.jpg",
    seconds: 302,
  },
  {
    title: "Time",
    artist: "Hans Zimmer",
    cover: "/music/cover-3.jpg",
    seconds: 275,
  },
  {
    title: "Intro",
    artist: "The xx",
    cover: "/music/cover-4.jpg",
    seconds: 127,
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
    const track = library[trackIndex];
    titleElement.textContent = track.title;
    artistElement.textContent = track.artist;
    artElement.src = track.cover;
  };
  paint();
  window.setInterval(() => {
    progress += 100 / 60;
    if (progress >= 100) {
      progress = 0;
      trackIndex = (trackIndex + 1) % library.length;
      paint();
    }
    progressElement.style.width = `${progress}%`;
  }, 100);
}

function clock(seconds) {
  const whole = Math.max(0, Math.round(seconds));
  const minutes = Math.floor(whole / 60);
  return `${minutes}:${String(whole % 60).padStart(2, "0")}`;
}

function startPlayer() {
  const root = document.querySelector("[data-player]");
  if (!root) {
    return;
  }
  const art = root.querySelector("[data-np-art]");
  const title = root.querySelector("[data-np-title]");
  const artist = root.querySelector("[data-np-artist]");
  const bar = root.querySelector("[data-np-progress]");
  const elapsedText = root.querySelector("[data-np-elapsed]");
  const remainingText = root.querySelector("[data-np-remaining]");
  const queueElement = root.querySelector("[data-queue]");
  if (!art || !title || !bar || !queueElement) {
    return;
  }

  const queue = library.slice();
  const secondsPerTick = 1.6;
  let elapsed = 0;

  const renderQueue = () => {
    queueElement.textContent = "";
    for (const track of queue.slice(1)) {
      const row = document.createElement("div");
      const cover = document.createElement("img");
      cover.className = "track-art";
      cover.src = track.cover;
      cover.alt = "";
      const name = document.createElement("span");
      name.className = "track-name";
      name.textContent = `${track.title} · ${track.artist}`;
      const length = document.createElement("span");
      length.className = "mono subtle";
      length.textContent = clock(track.seconds);
      row.append(cover, name, length);
      queueElement.appendChild(row);
    }
  };

  const paint = () => {
    const track = queue[0];
    art.src = track.cover;
    title.textContent = track.title;
    if (artist) {
      artist.textContent = track.artist;
    }
    renderQueue();
  };

  const advance = () => {
    queue.push(queue.shift());
    elapsed = 0;
    queueElement.dataset.shifting = "true";
    paint();
    window.setTimeout(() => {
      delete queueElement.dataset.shifting;
    }, 460);
  };

  paint();
  window.setInterval(() => {
    const track = queue[0];
    elapsed += secondsPerTick;
    if (elapsed >= track.seconds) {
      advance();
      return;
    }
    bar.style.width = `${(elapsed / track.seconds) * 100}%`;
    if (elapsedText) {
      elapsedText.textContent = clock(elapsed);
    }
    if (remainingText) {
      remainingText.textContent = `-${clock(track.seconds - elapsed)}`;
    }
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
  const swapText = (element, text) => {
    if (element.textContent === text) {
      return;
    }
    element.dataset.swap = "out";
    window.setTimeout(() => {
      element.textContent = text;
      element.dataset.swap = "in";
    }, 200);
  };

  const flip = () => {
    const enabled = demo.dataset.presenterState !== "on";
    demo.dataset.presenterState = enabled ? "on" : "off";
    swapText(badge, enabled ? "Presenter on" : "Presenter off");
    swapText(
      note,
      enabled
        ? "Spend and track names hidden for the room."
        : "Everything visible to you.",
    );
  };
  demo.dataset.presenterState = "off";
  badge.dataset.swap = "in";
  note.dataset.swap = "in";
  flip();
  window.setInterval(flip, 3600);
}

const downloadUrls = {
  macos: "https://github.com/pulkitxm/edith/releases/latest/download/Edith.dmg",
  linux: "https://github.com/pulkitxm/edith/releases/latest/download/Edith.deb",
};

const downloadLabels = {
  macos: "Download Edith for macOS",
  linux: "Download Edith for Ubuntu",
};

function startPlatformDownload() {
  const platform = currentDesktopPlatform();
  if (!platform) {
    return;
  }
  for (const button of document.querySelectorAll("[data-download-auto]")) {
    button.href = downloadUrls[platform];
    button.setAttribute("aria-label", downloadLabels[platform]);
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

function startSystemActions() {
  const buttons = document.querySelectorAll("[data-action]");
  const text = document.querySelector("[data-action-text]");
  const icon = document.querySelector("[data-action-icon]");
  if (!buttons.length || !text || !icon) {
    return;
  }
  const idle =
    "Tap any control to see what it does. Nothing here can lock you out.";
  for (const button of buttons) {
    button.addEventListener("click", () => {
      const pressed = button.getAttribute("aria-pressed") === "true";
      for (const other of buttons) {
        other.setAttribute("aria-pressed", "false");
        other.classList.remove("is-active");
      }
      if (!pressed) {
        button.setAttribute("aria-pressed", "true");
        button.classList.add("is-active");
      }
      const message = pressed ? idle : button.dataset.explain;
      if (text.textContent === message) {
        return;
      }
      text.dataset.swap = "out";
      window.setTimeout(() => {
        text.textContent = message;
        icon.textContent = pressed ? "🔒" : button.dataset.icon;
        text.dataset.swap = "in";
      }, 180);
    });
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

function startHeaderScroll() {
  const header = document.querySelector(".site-header");
  if (!header) {
    return;
  }
  const sync = () => {
    header.classList.toggle("is-scrolled", window.scrollY > 16);
  };
  sync();
  window.addEventListener("scroll", sync, { passive: true });
}

function start() {
  startPlatformDownload();
  startHeaderScroll();
  startSystemActions();
  startCopyButtons();
  buildHeatmaps();
  buildSparks();
  startNowPlaying();
  startPlayer();
  startReveals();
  startPresenterDemo();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
