# `ed usage projects list`

List cost and tokens per repository, with matching folders grouped under their
stable repository identity.

```
ed usage projects list [--range <range>] [--limit <n>] [--json]
```

`--range` accepts `today`, `week`, `month` or `all` and defaults to `all`.
`--limit` must be greater than zero. With no limit, every repository is shown.

The plain table includes repository name, cost and tokens. JSON is a top-level
array ordered by cost descending. Each object has exactly `repositoryID`,
`repositoryName`, `repositoryURL`, `cost`, `tokens` and `folders`. Folder objects
have `folderName`, `path`, `machineName`, `machineID`, `cost` and `tokens`.

Folders with the same GitHub remote share a repository across machines.
Repositories with the same visible name remain separate. Usage without reliable
folder attribution appears under `Unattributed`, so totals still reconcile with
`ed usage summary`.

## Examples

```
ed usage projects list
ed usage projects list --range week --limit 5
ed usage projects list --json | jq -r '.[].repositoryID'
```

## Where to go next

- [`ed usage projects`](./projects.md), repository actions and drilldown
- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
