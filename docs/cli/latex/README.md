# `ed latex`

The LaTeX editor's project library and compiler are available directly through
`ed`, without a running app or background agent. Disk projects save source and
PDF artifacts beside the file. Repository projects use GitHub reads, Pukbot
writes, GitHub Actions builds, and native Quinjet review, without a local clone.

## Commands

| Command | Result |
| --- | --- |
| `ed latex ls --json` | Project pointers and UUIDs. |
| `ed latex add --name Paper --file /tmp/main.tex --json` | Validate and register an existing disk source. |
| `ed latex add --name Paper --repo owner/repository --source docs/main.tex --json` | Register a GitHub source, using its default branch and pdfLaTeX. |
| `ed latex read PROJECT --json` | Complete UTF-8 source, project metadata, and a revision token. |
| `ed latex write PROJECT --revision REVISION --json` | Preview a complete replacement supplied as raw UTF-8 stdin. |
| `ed latex edit PROJECT --revision REVISION --json` | Preview literal replacements supplied as JSON stdin. |
| `ed latex compile PROJECT --json` | Rebuild the saved disk source or rerun its GitHub PDF build. |
| `ed latex preview PROJECT --json` | Check PDF availability for the current revision. |
| `ed latex review PROJECT --json` | PR metadata, diff, and checks for native Quinjet review. |
| `ed latex merge PROJECT --json` | Preview a squash merge with branch deletion. |
| `ed latex remove PROJECT --json` | Preview removing a library pointer, preserving its source. |

Every command has `--help`. `ed latex` defaults to `ls`. Add accepts
`--compiler tectonic` or `--compiler pdfLatex`; the default on disk is Tectonic.
Repository registration accepts `--branch` to override the default base branch.
The source must already exist and be UTF-8.

## Checked edits

Read the source first and pass its `revision` to `write` or `edit`. An external
change invalidates that revision. Each literal edit has `find`, `replace`, and a
positive `expectedMatches`. Edits apply sequentially in memory; every match
count must pass before any write. Use JSON escaping for LaTeX backslashes.

```json
[{"find":"\\section{Draft}","replace":"\\section{Introduction}","expectedMatches":1}]
```

Preview JSON contains the proposed `source`. Add `--yes` to save and compile a
disk project, or create/update a repository PR with a compiler workflow.
Both stdin formats are limited to 1 MiB. Send repository edits through process
stdin without saving local source copies. Retry interrupted submissions with
the same project to reconnect its review branch and pull request.

Local save happens before compilation. A compiler failure leaves the edited
source saved; read again to get the new revision before correcting it. Tectonic
or latexmk with TeX Live must be installed for local builds. Repository builds
run on GitHub after submission, so inspect `review` for checks.

## PDFs and merges

`compile` rebuilds the saved revision without changing source. Disk results contain
`pdfPath` and `log`. Repository results contain `buildURL`, `buildID`, and `status`,
with a null `pdfPath`. A running build is reused; a completed build is rerun
through Pukbot. Use `preview` after the build succeeds.

`preview --data --json` returns base64 PDF bytes. Repository previews stay in
memory and only return artifacts matching the current PR head. Pending or
failed builds may have no artifact. Disk preview reports `pdfPath`; repository
preview always reports a null path.

`merge --yes` squash merges through Pukbot and deletes the branch.
`merge --auto --yes` schedules that merge after required checks pass. Branch
protections remain enforced. A new edit after a closed or merged PR starts a
new review branch. `remove --yes` removes only the project pointer.

Install the matching plugin skill from Edith's Plugins screen or with
`ed skills install edith-latex-edit --agent cursor --yes`.

## See also

- [`ed skills`](../skills/README.md)
- [`ed`](../README.md)
