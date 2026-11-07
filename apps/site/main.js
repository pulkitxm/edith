const root = document.documentElement;
root.classList.add("js");

function storedTheme(value) {
  try {
    if (value) localStorage.setItem("edith-theme", value);
    return localStorage.getItem("edith-theme");
  } catch {
    return null;
  }
}

function currentTheme() {
  if (root.dataset.theme) return root.dataset.theme;
  return matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
}

for (const button of document.querySelectorAll("[data-theme-toggle]")) {
  button.addEventListener("click", () => {
    const next = currentTheme() === "light" ? "dark" : "light";
    root.dataset.theme = next;
    storedTheme(next);
  });
}

const menu = document.querySelector("[data-menu-toggle]");
const nav = document.getElementById("site-nav");
if (menu && nav) {
  menu.addEventListener("click", () => {
    const open = nav.classList.toggle("open");
    menu.setAttribute("aria-expanded", String(open));
  });
  nav.addEventListener("click", (event) => {
    if (event.target.closest("a")) {
      nav.classList.remove("open");
      menu.setAttribute("aria-expanded", "false");
    }
  });
}

for (const button of document.querySelectorAll("[data-copy]")) {
  button.addEventListener("click", async () => {
    const label = button.querySelector("span");
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      button.classList.add("copied");
      if (label) label.textContent = "Copied";
    } catch {
      if (label) label.textContent = "Press ⌘C";
    }
    setTimeout(() => {
      button.classList.remove("copied");
      if (label) label.textContent = "Copy";
    }, 1600);
  });
}

const revealed = document.querySelectorAll(".reveal");
if (
  "IntersectionObserver" in window &&
  !matchMedia("(prefers-reduced-motion: reduce)").matches
) {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add("in");
          observer.unobserve(entry.target);
        }
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.08 },
  );
  for (const element of revealed) observer.observe(element);
} else {
  for (const element of revealed) element.classList.add("in");
}

const search = document.querySelector("[data-ext-search]");
const extensionChips = document.querySelectorAll("[data-filter]");
if (search || extensionChips.length) {
  const sections = document.querySelectorAll("[data-section]");
  const empty = document.querySelector("[data-ext-empty]");
  let category = "all";
  const apply = () => {
    const query = (search?.value ?? "").trim().toLowerCase();
    let shown = 0;
    for (const section of sections) {
      let visible = 0;
      for (const card of section.querySelectorAll(".ext-card")) {
        const match =
          (category === "all" || card.dataset.category === category) &&
          (!query || card.dataset.search.includes(query));
        card.hidden = !match;
        if (match) visible += 1;
      }
      section.hidden = visible === 0;
      shown += visible;
    }
    if (empty) empty.hidden = shown > 0;
  };
  const select = (value) => {
    category = value;
    for (const chip of extensionChips)
      chip.setAttribute("aria-pressed", String(chip.dataset.filter === value));
    apply();
  };
  for (const chip of extensionChips)
    chip.addEventListener("click", () => select(chip.dataset.filter));
  search?.addEventListener("input", apply);
  const hash = location.hash.slice(1);
  if (hash && [...extensionChips].some((chip) => chip.dataset.filter === hash))
    select(hash);
  addEventListener("hashchange", () => {
    const value = location.hash.slice(1);
    if ([...extensionChips].some((chip) => chip.dataset.filter === value))
      select(value);
  });
}

const log = document.querySelector("[data-changelog]");
if (log) {
  const chips = document.querySelectorAll("[data-log-filter]");
  const apply = () => {
    const filter = log.dataset.filter ?? "all";
    for (const release of log.querySelectorAll(".release")) {
      const items = [...release.querySelectorAll("li")];
      const visible = items.some((item) => {
        const type = item.dataset.type;
        return filter === "all" || type === filter;
      });
      release.classList.toggle("filtered-out", filter !== "all" && !visible);
    }
    const empty = document.querySelector("[data-log-empty]");
    if (empty)
      empty.hidden = [...log.querySelectorAll(".release")].some(
        (release) => !release.classList.contains("filtered-out"),
      );
  };
  for (const chip of chips) {
    chip.addEventListener("click", () => {
      log.dataset.filter = chip.dataset.logFilter;
      for (const other of chips)
        other.setAttribute("aria-pressed", String(other === chip));
      apply();
    });
  }
  apply();
}

const player = document.querySelector("[data-player]");
if (player) {
  const start = async () => {
    const { default: Plyr } = await import("/vendor/plyr/plyr.min.mjs");
    new Plyr(player, {
      iconUrl: "/vendor/plyr/edith-controls.svg",
      blankVideo: "",
      controls: [
        "play-large",
        "play",
        "progress",
        "current-time",
        "duration",
        "mute",
        "volume",
        "fullscreen",
      ],
      ratio: "16:9",
      tooltips: { controls: false, seek: true },
    });
  };
  if ("IntersectionObserver" in window) {
    const watch = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          watch.disconnect();
          start();
        }
      },
      { rootMargin: "400px 0px" },
    );
    watch.observe(player);
  } else {
    start();
  }
}

const idle =
  window.requestIdleCallback ?? ((callback) => setTimeout(callback, 1200));
addEventListener("load", () => {
  idle(() => {
    for (const image of document.querySelectorAll(
      ".shot img[loading='lazy']",
    )) {
      const frame = image.closest(".shot");
      if (!frame) continue;
      const rect = frame.getBoundingClientRect();
      if (rect.top < innerHeight * 2) image.loading = "eager";
    }
  });
});
addEventListener(
  "scroll",
  () => {
    idle(() => {
      for (const image of document.querySelectorAll(
        ".shot img[loading='lazy']",
      )) {
        const rect = image.closest(".shot").getBoundingClientRect();
        if (rect.top < innerHeight * 1.5 && rect.bottom > -innerHeight)
          image.loading = "eager";
      }
    });
  },
  { passive: true },
);

const releaseTargets = document.querySelectorAll(
  "[data-dmg-size], [data-version]",
);
if (releaseTargets.length) {
  const apply = (release) => {
    for (const node of document.querySelectorAll("[data-dmg-size]"))
      node.textContent = release.size;
    for (const node of document.querySelectorAll("[data-version]"))
      node.textContent = release.version;
  };
  let cached = null;
  try {
    cached = JSON.parse(sessionStorage.getItem("edith-release") ?? "null");
  } catch {}
  if (cached) apply(cached);
  else {
    fetch("https://api.github.com/repos/pulkitxm/edith/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
    })
      .then((response) =>
        response.ok ? response.json() : Promise.reject(response.status),
      )
      .then((latest) => {
        const asset = latest.assets.find((item) => item.name === "Edith.dmg");
        if (!asset) return;
        const release = {
          size: `${(asset.size / 1_000_000).toFixed(1)} MB`,
          version: latest.tag_name.replace(/^v/, ""),
        };
        apply(release);
        try {
          sessionStorage.setItem("edith-release", JSON.stringify(release));
        } catch {}
      })
      .catch(() => {});
  }
}
