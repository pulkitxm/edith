# `ed database connections list`

Lists a bounded page of saved database connection summaries.

```
ed database connections list [--search <text>] [--product <product>]...
    [--environment <environment>]... [--group <group>] [--tag <tag>]...
    [--favorites-only] [--order <order>] [--limit <count>] [--offset <count>]
    [--json]
```

`ed database`, `ed database connections`, and
`ed database connections ls` reach the same command.

| Option | Values | Default | What it does |
| --- | --- | --- | --- |
| `--search` | text | none | Matches display names in the broker metadata store. |
| `--product` | `postgresql`, `mysql`, `mariadb`, `sqlite`, `redis`, `valkey`, `mongodb`, `elasticsearch`, `opensearch`, or `clickhouse` | all | Includes one product. Repeat to include several. |
| `--environment` | `local`, `development`, `testing`, `staging`, `production`, or `other` | all | Includes one environment. Repeat to include several. |
| `--group` | text | all | Requires an exact connection group. |
| `--tag` | text | none | Requires a tag. Repeated tags must all match. |
| `--favorites-only` | flag | off | Includes only favorite connections. |
| `--order` | `name`, `recently-used`, `recently-updated`, or `recently-created` | `recently-used` | Selects server-side ordering. |
| `--limit` | 1 through 500 | 100 | Bounds the returned page. |
| `--offset` | 0 through 1000000 | 0 | Skips matching connections before the returned page. |
| `--json` | flag | off | Emits one JSON array on stdout. |

The human table contains `ID`, `NAME`, `PRODUCT`, `ENVIRONMENT`, `MODE`, and
`FAVORITE`. JSON contains one summary object per connection with `id`,
`displayName`, `product`, `family`, `environment`, `deploymentMode`,
`readOnlyPolicy`, `productionPolicy`, `group`, `tags`, `color`, `favorite`, and
the four lifecycle timestamps. Optional fields are present as `null`.

The result never contains endpoints, usernames, authentication material,
credential references, TLS resource identifiers, tunnel details, or connection
options. Use `get` when a script explicitly needs the safe non-secret details
for one connection.

```
ed database connections list --json
ed database connections list --product postgresql --environment production
ed database connections list --tag reporting --favorites-only --order name
```

Invalid product, environment, order, limit, or offset values exit 2 before a
broker request is sent.

## Where to go next

- [`ed database connections get`](./connections-get.md)
- [`ed database connections`](./connections.md)
- [All `ed` commands](../README.md)
