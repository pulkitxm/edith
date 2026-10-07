import { parse } from "diff2html";
import { Diff2HtmlUI } from "diff2html/lib/ui/js/diff2html-ui-base.js";
import hljs from "highlight.js/lib/core";
import latex from "highlight.js/lib/languages/latex";
import yaml from "highlight.js/lib/languages/yaml";
import "diff2html/bundles/css/diff2html.min.css";
import "./review.css";

hljs.registerLanguage("latex", latex);
hljs.registerLanguage("yaml", yaml);

const list = document.getElementById("files");
const target = document.getElementById("patch");
const filter = document.getElementById("filter");
let files = [];
let selected = 0;
let current = {};

function drawFile() {
  target.replaceChildren();
  if (!files.length) {
    target.textContent = "No changes in this pull request.";
    return;
  }
  const ui = new Diff2HtmlUI(target, [files[selected]], {
    drawFileList: false,
    outputFormat: current.split ? "side-by-side" : "line-by-line",
    colorScheme: current.dark ? "dark" : "light",
    matching: "none",
    synchronisedScroll: true,
    fileContentToggle: false,
    stickyFileHeaders: true,
    highlight: true,
    highlightLanguages: new Map([["tex", "latex"], ["yml", "yaml"]]),
  }, hljs);
  ui.draw();
  target.scrollTop = 0;
}

function drawFiles() {
  list.replaceChildren();
  const query = filter.value.toLowerCase();
  files.forEach((file, index) => {
    const name = file.newName === "/dev/null" ? file.oldName : file.newName;
    if (!name.toLowerCase().includes(query)) return;
    const button = document.createElement("button");
    button.className = index === selected ? "selected" : "";
    button.setAttribute("aria-current", index === selected ? "true" : "false");
    const path = document.createElement("span");
    path.className = "path";
    const leaf = document.createElement("span");
    leaf.className = "filename";
    leaf.textContent = name.split("/").at(-1);
    const directory = document.createElement("span");
    directory.className = "directory";
    directory.textContent = name.includes("/") ? name.slice(0, name.lastIndexOf("/")) : "";
    path.append(leaf, directory);
    button.title = name;
    button.setAttribute("aria-label", `${name} +${file.addedLines} −${file.deletedLines}`);
    const counts = document.createElement("span");
    counts.className = "counts";
    const additions = document.createElement("span");
    additions.className = "additions";
    additions.textContent = `+${file.addedLines}`;
    const deletions = document.createElement("span");
    deletions.className = "deletions";
    deletions.textContent = `−${file.deletedLines}`;
    counts.append(additions, deletions);
    button.append(path, counts);
    button.onclick = () => { selected = index; drawFiles(); drawFile(); };
    list.append(button);
  });
}

filter.addEventListener("input", drawFiles);
window.edithReview = {
  configure(options) {
    if (options.patch !== current.patch) {
      files = parse(options.patch, { diffMaxChanges: 10000, diffMaxLineLength: 10000 });
      selected = 0;
      filter.value = "";
    }
    current = options;
    document.body.classList.toggle("dark", options.dark);
    document.documentElement.style.fontSize = `${options.fontSize}px`;
    document.getElementById("summary").textContent = `Changed files · ${files.length}`;
    drawFiles();
    drawFile();
  },
};
