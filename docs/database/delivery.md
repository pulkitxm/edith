# Database delivery stack

The stack is deliberately split by review boundary. Each branch is created from its predecessor with `gh stack`, kept coherent, tested, pushed normally, and represented on GitHub through Pukbot. Pull request descriptions contain exactly one line. Evidence is a later concise Pukbot comment.

| Order | Branch | Pull request scope | Primary gates |
| ---: | --- | --- | --- |
| 1 | `feature/database-foundation` | Research, product contract, architecture, verification matrix, and stack plan | Documentation and repository policy checks |
| 2 | `feature/database-contracts` | Extension registration, shared types, capabilities, values, paging, errors, persistence, secrets, safety, and operation center | Unit, migration, redaction, policy, lifecycle tests |
| 3 | `feature/database-surfaces` | Canonical executor, fake adapter, CLI command family, MCP stdio server, and operation parity | CLI, MCP, completion, docs, cancellation, output tests |
| 4 | `feature/database-postgres` | PostgreSQL adapter, metadata, SQL execution, transactions, editing, plans, and real-product contracts | PostgreSQL unit and TUF integration results |
| 5 | `feature/database-relational-ui` | Native relational workbench, grid, SQL editor, staged edits, diagrams, plans, and responsive states | Render, accessibility, grid, interface journey tests |
| 6 | `feature/database-keyspace` | Redis and Valkey adapters, keyspace workspace, commands, MCP, monitoring, and real-product tests | Redis and Valkey contract and TUF results |
| 7 | `feature/database-mongodb` | MongoDB adapter, document workspace, pipelines, schema sampling, commands, MCP, and tests | MongoDB contract and TUF results |
| 8 | `feature/database-search` | Elasticsearch and OpenSearch adapters, search workspace, product differences, tasks, commands, MCP, and tests | Separate Elasticsearch and OpenSearch TUF results |
| 9 | `feature/database-clickhouse` | ClickHouse adapter, analytical workspace, plans, parts, mutations, commands, MCP, and tests | ClickHouse contract and TUF results |
| 10 | `feature/database-sql-products` | MySQL, MariaDB, and SQLite adapters with product-native metadata, dialects, plans, and administration | Separate MySQL, MariaDB, SQLite results |
| 11 | `feature/database-data-transfer` | Streaming import and export, monitoring, maintenance, saved work, and advanced operations | Format, backpressure, partial failure, and real-product tests |
| 12 | `feature/database-hardening` | Million-record results, tunnel failures, performance, responsive polish, accessibility, documentation, and final evidence | Full local CI, all TUF matrix results, rendered inspection |

No pull request may exceed 5,000 changed lines. The target is below 2,000. A layer is split further if its production code and tests cannot stay reviewable under that target.

## Checkpoint rule

Within every branch, checkpoints are made after each coherent passing boundary, such as contracts, persistence, policy, one adapter read path, one mutation path, one interface workspace, or one test family. Unrelated changes are staged separately. A checkpoint must compile and pass its relevant focused suite.

## Branch gate

Before a branch is pushed:

1. Relevant focused tests pass.
2. Swift formatting and comment policy pass for Swift changes.
3. CLI parity, completion, and docs pass for command changes.
4. Package build and tests pass.
5. Real adapter results are recorded when the branch claims a product.
6. Interface changes are run and inspected in representative widths and themes.
7. No secret, credential, private endpoint, generated database, or result spool is staged.
8. The diff contains only the intended layer and stays within line limits.

## Stack gate

After a lower branch changes, dependent branches are restacked and tested again. Rewritten remote branches use only `git push --force-with-lease`. `gh stack` is used for topology and restacking, never for GitHub mutations.

For every pull request, Pukbot sets and later verifies:

- Conventional lowercase title without a final period
- Correct predecessor branch as base
- Correct head branch
- Exactly one description line
- Ready state when the layer is complete
- Repository-conventional labels and assignee when applicable
- One concise final evidence comment when the outcome can be shown

Read-only GitHub inspection verifies base, head, commit range, diff, checks, title, description line count, state, labels, assignee, and branch-tip SHA after the final push.

## CI gate

Every required check on every layer must finish green. A lower-layer fix triggers restack, repush, metadata verification, and check verification for every dependent layer. Failed checks are reproduced and fixed at their owning layer. Required failures are never disabled, ignored, cancelled into success, or converted to allowed failures.

## Evidence plan

Evidence shows the finished outcome only:

- Foundation and contracts: clean targeted test output if there is no visual result.
- CLI and MCP: concise bounded output from the Mac through a TUF forward.
- Product adapters: real capability, browse, mutation preview, and cancellation result.
- Interface layers: final wide and narrow screenshots, with light and dark split only when each shows a distinct outcome.
- Hardening: concise performance and interruption result, plus final workbench view.

One comment per pull request is the default and three is the absolute cap. Logs and intermediate debugging are not evidence.

## Completion audit

The final audit proves:

1. Every local branch has the intended parent and clean commit range.
2. Every remote branch tip equals its local tip.
3. Every GitHub pull request has the intended base, head, title, one-line description, ready state, labels, assignee, and diff.
4. No lower pull request includes a later layer.
5. Every required check is green and none is pending or cancelled.
6. Every claimed product has a separate real server result through a Mac loopback forward.
7. Every family and SQL product has a reproducible near-million-record dataset.
8. CLI, interface, and MCP parity results exist.
9. Responsive, theme, accessibility, performance, cancellation, and reconnect results exist.
10. Final evidence is posted through Pukbot and contains no secret or private material.

Pull requests remain unmerged. Merging is outside this delivery authorization.
