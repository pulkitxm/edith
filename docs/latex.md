# LaTeX

Enable LaTeX in Extensions, then open it from Media. Add as many projects as you
need. The project library and document editor have separate screens. Select Open
editor on a project card, or add a project to open its editor immediately. Use
Back to projects after saving, submitting, or discarding your edits. A project points to either a local `.tex` file or a GitHub repository,
base branch, and relative source path. An empty base branch uses the repository
default. Adding a project verifies that its source exists and is UTF-8 text.

## Local documents

Install Tectonic from the extension's tool controls. Choose a `.tex` file, edit
its source, and select Save & compile. The source stays on disk and the PDF is
written beside it. The output pane shows the PDF or build log. Compilation runs
from the source directory so relative includes and assets resolve normally.
Edith refuses to save over source changes made by another editor.
The source editor includes LaTeX syntax colors, line numbers, undo and redo,
inline find, line wrapping, and text size controls. Use Command-Return to save
and compile. The PDF pane has page navigation, zoom, fit, and Save PDF as.

## Repository documents

Install GitHub CLI, Quinjet, and Pukbot, then authenticate with `gh auth login`.
The account needs permission to push branches and add GitHub Actions workflows.
Use `owner/repository` and a relative path such as `papers/main.tex`.

Edit the source and select Create pull request. Edith creates a branch from the
commit that supplied your source and commits the edited source plus a dedicated
compiler workflow through Pukbot. Subsequent edits update the same open PR.
Repository sources remain in memory until submitted. Only project pointers and
PR identifiers are saved locally. No repository checkout or local PDF is made.
If submission fails after creating the branch or PR, retry reconnects the
existing remote work. Source conflicts are reported instead of overwritten.

Choose pdfLaTeX for documents using pdfTeX commands such as `\pdfgentounicode`.
The repository compiler uses a full TeX Live environment with pdfLaTeX. Local
pdfLaTeX compilation needs latexmk and a local TeX Live installation on PATH.

GitHub Actions compiles the document on pull requests and pushes and uploads the
PDF as a run artifact. Select Refresh PDF to view the current revision in memory, or open Builds &
PDF artifacts on GitHub. PDF previews never write repository artifacts to disk.
Use Review in Quinjet to see the live PR, patch, and checks without cloning.
Merge options offer a squash merge with branch deletion or a squash merge after
required checks pass. Branch protections remain enforced. Refresh or reload to
see updated checks and completed merges. A new edit after a completed PR starts
a new review branch.

Discard or submit unsaved changes before switching projects or removing a
library entry. Removing an entry only removes its pointer from the library.

```sh
ed extensions enable latex
ed app reveal latex
ed tools install tectonic
```
