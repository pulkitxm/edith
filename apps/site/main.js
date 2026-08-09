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

function start() {
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
