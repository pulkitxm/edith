(() => {
  const TRACKS = [
    {
      title: "Weightless",
      artist: "Marconi Union",
      from: "#e08a6a",
      to: "#b3543a",
    },
    { title: "Nightcall", artist: "Kavinsky", from: "#6a8d9e", to: "#2f4a63" },
    { title: "Strobe", artist: "deadmau5", from: "#7a9e83", to: "#2f5c3f" },
    {
      title: "Teardrop",
      artist: "Massive Attack",
      from: "#9e6a97",
      to: "#5c2f56",
    },
    { title: "Intro", artist: "The xx", from: "#c89b3c", to: "#7a5c14" },
  ];

  function level(i) {
    const rnd = Math.abs(Math.sin(i * 12.9898 + 4.1) * 43758.5453) % 1;
    return rnd < 0.06 ? 0 : Math.min(4, 1 + Math.floor(rnd * 4.2));
  }

  document.querySelectorAll(".heatmap").forEach((el) => {
    const rows = Number(el.dataset.rows) || 7;
    const cols = Number(el.dataset.cols) || 16;
    const frag = document.createDocumentFragment();
    for (let c = 0; c < cols; c++) {
      for (let r = 0; r < rows; r++) {
        const cell = document.createElement("i");
        cell.className = `l${level(c * rows + r)}`;
        frag.appendChild(cell);
      }
    }
    el.appendChild(frag);
  });

  document.querySelectorAll("[data-spark]").forEach((el) => {
    const heights = [
      18, 22, 20, 26, 30, 28, 34, 40, 37, 44, 48, 46, 53, 58, 55, 61, 66, 64,
      68,
    ];
    for (const h of heights) {
      const bar = document.createElement("i");
      bar.style.height = `${h}%`;
      el.appendChild(bar);
    }
  });

  const np = {
    title: document.querySelector("[data-title]"),
    artist: document.querySelector("[data-artist]"),
    art: document.querySelector("[data-art]"),
    progress: document.querySelector("[data-progress]"),
  };
  if (np.title && np.progress) {
    let ti = 0;
    let p = 18;
    const paint = () => {
      const t = TRACKS[ti];
      np.title.textContent = t.title;
      np.artist.textContent = t.artist;
      np.art.style.background = `linear-gradient(145deg, ${t.from}, ${t.to})`;
    };
    paint();
    setInterval(() => {
      p += 100 / 60;
      if (p >= 100) {
        p = 0;
        ti = (ti + 1) % TRACKS.length;
        paint();
      }
      np.progress.style.width = `${p}%`;
    }, 100);
  }

  const pdemo = document.querySelector("[data-presenter-demo]");
  if (pdemo) {
    const badge = pdemo.querySelector("[data-pbadge]");
    const note = pdemo.querySelector("[data-pnote]");
    const flip = () => {
      const on = pdemo.classList.toggle("on");
      badge.textContent = on ? "Presenter on" : "Presenter off";
      badge.style.opacity = on ? "1" : "0.5";
      note.textContent = on
        ? "Spend and track names hidden for the room."
        : "Everything visible to you.";
    };
    pdemo.classList.remove("on");
    flip();
    setInterval(flip, 2200);
  }
})();
