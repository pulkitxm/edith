---
name: edith-latex-edit
description: Edit and compile LaTeX documents through Edith's ed CLI, including local files and GitHub source projects with pull request review in Quinjet. Use for source edits, PDF builds, compiler troubleshooting, or managing LaTeX projects in Edith.
---

# Edith LaTeX Edit

Use `ed latex` to work with the same project library as Edith's editor. Start
with `ed latex --help` and `ed latex ls --json`. Discover command-specific
flags with `--help`; use the installed CLI's contract.

## Select a project

Use the project UUID returned by the library. Register a supplied source with
`ed latex add --name Paper --file /absolute/path/main.tex --json`, or
`ed latex add --name Paper --repo owner/repository --source docs/main.tex --json`.
Repository registration resolves the default branch unless `--branch` is given.
Use `--compiler tectonic` or `--compiler pdfLatex` when the document requires it.
The defaults are Tectonic for disk and pdfLaTeX for repositories.

Local sources and compiler artifacts stay beside the file. Repository sources,
commits, build artifacts, and pull requests stay on GitHub. Keep repository
source and edit plans in memory; do not clone or create local source copies to
perform these commands. Repository metadata saves only pointers.

## Read and edit

Read `ed latex read PROJECT --json` to obtain `source`, `revision`, and project
metadata. Every write requires that exact revision. A mismatch means the source
changed, so read again and reconcile the requested edit.

For targeted edits, send a JSON array to `ed latex edit PROJECT --revision
REVISION --json` on stdin. Each operation has literal `find`, `replace`, and
positive `expectedMatches` fields. Operations run sequentially against the
result of the previous operation. All match counts must pass before any write.
LaTeX backslashes must be escaped in JSON. Generate JSON with a serializer.

```json
[{"find":"\\section{Draft}","replace":"\\section{Introduction}","expectedMatches":1}]
```

For a complete replacement, send raw UTF-8 source to `ed latex write PROJECT
--revision REVISION --json` on stdin. Pass source through a pipe or structured
process stdin instead of interpolating it into a shell command. Input is limited
to 1 MiB. Both commands preview without `--yes`, including the proposed source
in JSON. Apply with `--yes` once the change matches the user's authorized task.

Applying saves and compiles a disk project, or creates or updates a repository
PR with its GitHub compiler workflow. GitHub writes use Pukbot. Retry a failed
repository submission through the same project so its persisted branch pointer
reconnects existing remote work. Do not make another branch to hide a failure.

## Verify and review

Use `ed latex compile PROJECT --json` to rebuild a saved disk source. If a local
save succeeds but compilation fails, the source remains saved. Read it again
before the next edit and use the compiler error to make a focused correction.
Tectonic must be installed locally; pdfLaTeX uses latexmk and TeX Live.

Repository builds run automatically after submission. Use `ed latex review
PROJECT --json` for the PR, diff, and checks used by the native Quinjet review screen. Use `ed latex
preview PROJECT --json` to check PDF availability for the current revision.
Add `--data --json` to receive base64 PDF bytes in memory for inspection.
An unavailable artifact is not proof of a successful build. Inspect checks and
report a pending or failed compilation accurately.

`ed latex merge PROJECT --json` previews a squash merge with branch deletion.
Apply with `--yes` only when merging is part of the user's request. `--auto`
schedules the merge after required checks pass. Branch protections apply.
A subsequent edit after a closed or merged PR starts a new review branch.

`ed latex remove PROJECT --json` previews removing a library pointer. `--yes`
applies it without deleting any source, repository, or pull request.
