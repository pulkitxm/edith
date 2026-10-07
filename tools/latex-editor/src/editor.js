import { basicSetup } from "codemirror";
import { autocompletion } from "@codemirror/autocomplete";
import { redo, redoDepth, undo, undoDepth, indentWithTab } from "@codemirror/commands";
import { HighlightStyle, StreamLanguage, indentUnit, syntaxHighlighting } from "@codemirror/language";
import { stex } from "@codemirror/legacy-modes/mode/stex";
import { closeSearchPanel, openSearchPanel } from "@codemirror/search";
import { Compartment, EditorState, Transaction } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { tags } from "@lezer/highlight";

const theme = new Compartment();
const wrapping = new Compartment();
const editing = new Compartment();
const commands = ["documentclass", "usepackage", "begin", "end", "section", "subsection", "subsubsection", "textbf", "textit", "emph", "href", "url", "item", "label", "ref", "cite", "frac", "sqrt", "includegraphics", "title", "author", "date", "maketitle", "input", "newcommand", "renewcommand", "vspace", "hspace"];
let view;
let current;
let configuring = false;

function post(message) {
  window.webkit?.messageHandlers?.latexEditor?.postMessage(message);
}

function report(update) {
  if (configuring) return;
  const selection = view.state.selection.main;
  const line = view.state.doc.lineAt(selection.head);
  post({
    type: "state",
    revision: current.revision,
    documentID: current.documentID,
    ...(update?.docChanged ? { text: view.state.doc.toString() } : {}),
    line: line.number,
    column: selection.head - line.from + 1,
    canUndo: undoDepth(view.state) > 0,
    canRedo: redoDepth(view.state) > 0,
  });
}

function editorTheme(options) {
  const dark = options.dark;
  const ink = dark ? "#d4d9e3" : "#263044";
  const muted = dark ? "#737c8f" : "#8991a2";
  const surface = dark ? "#171a21" : "#ffffff";
  const accent = dark ? "#bdabff" : "#653bbe";
  return [
    EditorView.theme({
      "&": { height: "100%", color: ink, backgroundColor: surface, fontSize: `${options.fontSize}px` },
      ".cm-scroller": { fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", lineHeight: "1.65", overflow: "auto" },
      ".cm-content": { padding: "14px 0 100px", caretColor: ink },
      ".cm-line": { padding: "0 16px" },
      ".cm-cursor, .cm-dropCursor": { borderLeftColor: ink, borderLeftWidth: "2px" },
      ".cm-gutters": { backgroundColor: surface, color: muted, borderRight: "none" },
      ".cm-lineNumbers .cm-gutterElement": { padding: "0 12px 0 14px", minWidth: "28px" },
      ".cm-activeLine, .cm-activeLineGutter": { backgroundColor: dark ? "#222733" : "#f3f5fa" },
      ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": { backgroundColor: dark ? "#3a4765" : "#d6e3fa" },
      ".cm-matchingBracket": { color: accent, backgroundColor: dark ? "#3a334e" : "#e9e2fb", outline: "1px solid #8070a8" },
      ".cm-panels": { color: ink, backgroundColor: dark ? "#222733" : "#f3f5fa" },
      ".cm-panels-top": { borderBottom: `1px solid ${dark ? "#363c49" : "#d8dde8"}` },
      ".cm-search": { padding: "8px 12px", fontSize: "12px" },
      ".cm-textfield": { color: ink, backgroundColor: surface, border: `1px solid ${muted}`, borderRadius: "4px", padding: "5px 8px" },
      ".cm-button": { color: ink, backgroundImage: "none", backgroundColor: surface, border: `1px solid ${muted}`, borderRadius: "4px", padding: "4px 8px" },
      ".cm-tooltip": { border: `1px solid ${muted}`, backgroundColor: surface },
      ".cm-tooltip-autocomplete ul li[aria-selected]": { color: ink, backgroundColor: dark ? "#3a4765" : "#d6e3fa" },
      ".cm-searchMatch": { backgroundColor: dark ? "#65502c" : "#fff0b1" },
      ".cm-searchMatch-selected": { backgroundColor: dark ? "#896a32" : "#ffd974" },
    }, { dark }),
    syntaxHighlighting(HighlightStyle.define([
      { tag: [tags.keyword, tags.tagName], color: accent },
      { tag: [tags.string, tags.attributeValue], color: dark ? "#b4d990" : "#53732e" },
      { tag: [tags.number, tags.bool], color: dark ? "#ebbb83" : "#a05d15" },
      { tag: tags.comment, color: muted, fontStyle: "italic" },
      { tag: [tags.atom, tags.variableName, tags.attributeName], color: dark ? "#87c8de" : "#226b8b" },
      { tag: [tags.bracket, tags.punctuation], color: dark ? "#aeb8cc" : "#627089" },
      { tag: tags.invalid, color: dark ? "#f392a1" : "#bf3450" },
    ])),
  ];
}

function complete(context) {
  const word = context.matchBefore(/\\[a-zA-Z]*/);
  if (!word || (!context.explicit && word.from === word.to)) return null;
  return {
    from: word.from,
    options: commands.map((name) => ({
      label: `\\${name}`,
      type: "function",
      apply(editor, completion, from, to) {
        const takesArgument = !["item", "maketitle"].includes(name);
        const insert = completion.label + (takesArgument ? "{}" : " ");
        editor.dispatch({ changes: { from, to, insert }, selection: { anchor: from + insert.length - (takesArgument ? 1 : 0) } });
      },
    })),
  };
}

function state(options, selection = 0) {
  return EditorState.create({
    doc: options.text ?? "",
    selection: { anchor: Math.min(selection, (options.text ?? "").length) },
    extensions: [
      basicSetup,
      StreamLanguage.define(stex),
      indentUnit.of("    "),
      EditorState.tabSize.of(4),
      EditorView.contentAttributes.of({ "aria-label": "LaTeX source", spellcheck: "false", autocorrect: "off", autocapitalize: "off" }),
      keymap.of([{ key: "Mod-b", run: () => insertSnippet("bold") }, { key: "Mod-i", run: () => insertSnippet("italic") }, { key: "Mod-s", preventDefault: true, run: () => { post({ type: "save", revision: current.revision, documentID: current.documentID }); return true; } }, indentWithTab]),
      autocompletion({ override: [complete] }),
      theme.of(editorTheme(options)),
      wrapping.of(options.wrapsLines ? EditorView.lineWrapping : []),
      editing.of([EditorView.editable.of(options.editable), EditorState.readOnly.of(!options.editable)]),
      EditorView.updateListener.of((update) => { if (update.docChanged || update.selectionSet || update.transactions.length) report(update); }),
    ],
  });
}

function insertSnippet(name) {
  const snippets = {
    bold: ["\\textbf{", "}", "Text"],
    italic: ["\\emph{", "}", "Text"],
    section: ["\\section{", "}", "Title"],
    equation: ["\\[\n    ", "\n\\]", "equation"],
    list: ["\\begin{itemize}\n    \\item ", "\n\\end{itemize}", "Item"],
  };
  const snippet = snippets[name];
  if (!snippet || view.state.readOnly) return false;
  const selection = view.state.selection.main;
  const content = view.state.sliceDoc(selection.from, selection.to) || snippet[2];
  const insert = snippet[0] + content + snippet[1];
  const from = selection.from + snippet[0].length;
  view.dispatch({ changes: { from: selection.from, to: selection.to, insert }, selection: { anchor: from, head: from + content.length }, scrollIntoView: true });
  view.focus();
  return true;
}

window.edithEditor = {
  configure(options) {
    configuring = true;
    if (!view) {
      view = new EditorView({ state: state(options), parent: document.getElementById("editor") });
    } else if (current.documentID !== options.documentID || (typeof options.text === "string" && view.state.doc.toString() !== options.text)) {
      const scrollTop = current.documentID === options.documentID ? view.scrollDOM.scrollTop : 0;
      const selection = current.documentID === options.documentID ? view.state.selection.main.head : 0;
      view.setState(state(options, selection));
      view.scrollDOM.scrollTop = scrollTop;
    } else {
      const effects = [];
      if (current.dark !== options.dark || current.fontSize !== options.fontSize) effects.push(theme.reconfigure(editorTheme(options)));
      if (current.wrapsLines !== options.wrapsLines) effects.push(wrapping.reconfigure(options.wrapsLines ? EditorView.lineWrapping : []));
      if (current.editable !== options.editable) effects.push(editing.reconfigure([EditorView.editable.of(options.editable), EditorState.readOnly.of(!options.editable)]));
      if (effects.length) view.dispatch({ effects, annotations: Transaction.addToHistory.of(false) });
    }
    current = options;
    configuring = false;
    report();
  },
  command(name) {
    if (!view) return;
    insertSnippet(name);
    if (name === "undo") undo(view);
    if (name === "redo") redo(view);
    if (name === "find") openSearchPanel(view);
    if (name === "closeFind") closeSearchPanel(view);
    if (name === "focus") view.focus();
    if (name === "undo" || name === "redo") view.focus();
    report();
  },
};
post({ type: "ready" });
