# `ed studio edit publications`

[Back to the CLI reference](../README.md)

Publication order is a separate local JSON manifest. Its `items` array determines
the upload sequence. Each entry keeps a stable native project ID, a project path,
and a logical upload title. Moving an approved cut to the second slot preserves
the project bytes, edits, title, ID and timestamps. The upload title belongs to
the manifest and does not rename the project.

## Create

```sh
ed studio edit publications create uploads.json --input projects.json --dry-run --json
ed studio edit publications create uploads.json --input projects.json --json
```

`projects.json`:

```json
{
  "version": 1,
  "projects": [
    {"path": "approved.openscreen", "title": "Approved episode"},
    {"path": "new.openscreen", "title": "New opening episode"}
  ]
}
```

Relative `path` values resolve beside the input plan, never beside the current
working directory. Creation stores absolute `projectPath` values and reads the
project IDs from the referenced files. Omitting `title` uses the current project
title. Explicit titles must be nonempty strings.

## Show and validate

```sh
ed studio edit publications show uploads.json --json
```

Show validates the manifest and prints the following versioned shape:

```json
{
  "version": 1,
  "items": [
    {"projectID": "approved-id", "projectPath": "/mock/approved.openscreen", "title": "Approved episode"},
    {"projectID": "new-id", "projectPath": "/mock/new.openscreen", "title": "New opening episode"}
  ]
}
```

The IDs above are placeholders. Use the IDs returned by your own `show` command.
Hand-authored manifests may use relative `projectPath` values, which resolve
beside the manifest. Show checks project structure, identity, duplicate IDs,
duplicate file references, and missing project or dependency files. It does not
render media. Use `ed studio edit validate` for render-composition validation.

## Reorder by stable identity

Save `order.json` using the IDs from `show`:

```json
{"version": 1, "projectIDs": ["new-id", "approved-id"]}
```

```sh
ed studio edit publications reorder uploads.json --input order.json --overwrite --dry-run --json
ed studio edit publications reorder uploads.json --input order.json --overwrite --json
```

Every existing ID must appear exactly once. Reorder preserves each entry's path
and title. To expand the set of projects, create a replacement manifest from a
complete project-list plan with `--overwrite`. Existing project files remain
unchanged. Publication commands do not reserve or release source-reuse ledger
entries, so the existing media ledger remains the authority for reuse policy.

## Contract and safety

- The public Swift types are `VideoPublicationPlan`, `VideoPublicationManifest`,
  `VideoPublicationOrder`, and `VideoPublicationService.Result`. The service has
  `create(at:input:dryRun:overwrite:)`, `show(_:)`, and
  `reorder(_:input:dryRun:overwrite:)`. JSON boundaries use these typed payloads
  without exposing native project models.
- Version 1 only; each array has 1 to 100 entries; each JSON input and manifest
  is at most 1 MiB. Unknown fields, non-string entry values, NULs, empty strings,
  IDs/titles over 1000 UTF-8 bytes, and paths over 4096 UTF-8 bytes are rejected.
- Output must be a local `.json` file. Existing destinations require
  `--overwrite`, including dry runs. Symlink outputs are rejected. Project,
  media, `.cursor.json` and `.session.json` sidecars, and plan aliases are
  protected, including hardlinks.
- Writes use a sibling temporary file and atomic publication. Cancellation,
  changed inputs, and validation failures leave the destination intact.
- Project loading performs no migration writes. A manifest whose stored ID no
  longer matches its project fails with `invalid_publication_identity`.
- All successful output is JSON. Create and reorder return
  `{version,path,written,manifest}`; show returns the manifest. `--json` makes
  runtime errors structured JSON on stderr. `invalid_*` errors exit 2; other
  runtime failures exit 1. Duplicate references use
  `invalid_publication_duplicate`, invalid permutations use
  `invalid_publication_order`, and protected outputs use
  `invalid_publication_output`. Unreadable projects or dependencies use
  `invalid_publication_reference` with the zero-based item index.

MCP tools are `edith_studio_edit_publications_create`,
`edith_studio_edit_publications_show`, and
`edith_studio_edit_publications_reorder`. Each accepts the same CLI arguments in
its `arguments` array and runs headlessly.
