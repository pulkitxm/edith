# `ed seo ls`

[`ed seo`](./README.md)

[The `ed` command line](../README.md)

```bash
ed seo ls [--json]
```

Lists saved site-audit projects. It reads names, site URLs, and the latest run summary. It does not crawl or change a project. `list` is an alias. JSON is an array of objects with `id`, `name`, `baseURL`, `updatedAt`, and nullable `latestRun`.
