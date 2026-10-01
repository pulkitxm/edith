# `ed seo`

`ed seo` audits a site the same way the Site Audit screen does: projects, discovered pages, the Lighthouse switch, and saved runs. The background agent stores the projects. Edith or `edithd` has to be running.

[The `ed` command line](../README.md)

| Command | What it does |
| --- | --- |
| [`ed seo ls`](./ls.md) | Lists saved projects. |
| [`ed seo create`](./create.md) | Creates a project from a site URL. |
| [`ed seo rename`](./rename.md) | Renames a project. |
| [`ed seo delete`](./delete.md) | Deletes a project after `--yes`. |
| [`ed seo show`](./show.md) | Shows one project and its page selection. |
| [`ed seo pages`](./pages.md) | Discovers pages and changes the selection. |
| [`ed seo lighthouse`](./lighthouse.md) | Turns Lighthouse on or off for the next audit. |
| [`ed seo start`](./start.md) | Audits the selected pages. |
| [`ed seo stop`](./stop.md) | Cancels a running audit after `--yes`. |
| [`ed seo run`](./run.md) | Shows one run, its issues, and a social card. |

`ls` is the default, so a bare `ed seo` lists projects. `ls` is also `list`, and `delete` is also `rm`.
