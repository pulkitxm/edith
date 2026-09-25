# `ed usage attribution`

Review and reset how Edith matched unknown and non-GitHub folders in agent usage
to one of your GitHub repositories.

```
ed usage attribution [ls] [--json]
ed usage attribution reset [--yes] [--json]
```

With no command, this group runs `ed usage attribution ls`.

## How folders are matched

After every usage refresh, Edith looks at folders whose usage has no GitHub
remote, and at chats that ran with no folder at all (they show as `unknown`).
The known repositories are the GitHub repositories that already appear in
`usage.json`.

- By name, with or without a Jev key: a folder whose name or path clearly names
  exactly one known repository moves under it. Case is ignored, and so are
  suffixes such as `-worktrees`, `-main` and `-fix`. A chat with no folder moves
  when its title names exactly one repository. Two candidates, or none, leave it
  where it is.
- By Jev, only while a key is saved: for what is left, Jev picks one known
  repository or `none` from the folder, its path, the machine, the agent and up
  to five chat titles. An answer below 0.9 counts as `none`. Chats titled only
  `Chat <id>` carry no signal and are never sent. Each run asks at most 40 new
  questions, and every answer, `none` included, is kept, so nothing is asked
  twice.

A moved folder keeps its path, so it shows under the chosen repository in the
dashboard drilldown and in `ed usage projects show`, marked `attributed by name`
or `attributed by Jev`. `ed usage projects list --json` adds `attribution` to
every folder. Cost and tokens only move; the totals in `ed usage summary` never
change. When only some chats of a folder move, the folder's cost and tokens are
split by those chats' share of its cost.

Decisions live in `usage-attribution.json` next to `usage.json` and take effect
on the next refresh.

## `ed usage attribution ls`

Lists every decision, sorted by key: its scope (`folder` or `chat`), folder,
machine, chat title, repository or `none`, whether it was made by `name` or
`jev`, and Jev's confidence. JSON is an array of objects with `key`, `scope`,
`folder`, `machine`, `title`, `repositoryID`, `repositoryName`, `method`,
`confidence` and `decidedAt`.

## `ed usage attribution reset`

Forgets every decision. Without `--yes` it only reports how many decisions it
would forget, as `{"applied": false, "decisions": <n>}` in JSON. With `--yes` it
clears them, and the next refresh moves folders back and decides again.

## Where to go next

- [`ed usage projects`](./projects.md), the repository drilldown
- [`ed jev`](../jev/README.md), the key that turns Jev matching on
- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
