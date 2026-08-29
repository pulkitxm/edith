# Native GitHub extension architecture

## Scope

The GitHub extension is a native SwiftUI browser whose resource identity is a GitHub URL. The
first release covers remote repository and code reading through the installed `gh` CLI. Editing,
pull request review, and the remaining GitHub areas land as later vertical slices.

No GitHub page is embedded. Unsupported resources always show an explicit support state and an
action to open the same URL on GitHub.

## Existing Edith foundations

The extension fits the current architecture instead of creating a second application shell:

- `EdithCore` owns registry metadata, lifecycle descriptions, platform capabilities, and route
  value types that do not need AppKit.
- `EdithKit` owns `gh` discovery, subprocess execution, typed API models, request scheduling,
  caching, recents, restoration, and operations.
- `Edith` owns the SwiftUI browser chrome, tabs, repository screens, code views, Markdown, and file
  previews.
- The existing CLI command runner supplies detached execution, cancellation, timeouts, output
  limits, sanitized environments, and process-group termination.
- The Machines feature supplies proven lazy tree, preview, and generation-guarded navigation
  patterns.
- The vendored Highlighter package supplies syntax themes and language detection. A new code viewer
  must add virtualization, line numbers, ranges, find, wrapping, and scroll restoration.
- Extension enablement, tool setup, settings, readiness, and destination visibility stay in the
  shared registry and mutation flow.

GitHub authorization is not a macOS permission. Readiness checks `gh auth status` for each selected
host, account, and required scopes. Edith never reads, stores, or prints the underlying token.

## Proposed data flow

```text
GitHubPage
  -> GitHubBrowserModel
    -> GitHubClient
      -> GitHubRequestScheduler
        -> GitHubCache
        -> GitHubCLITransport
          -> CLICommandRunner
            -> gh
```

The model publishes only results belonging to the tab generation that requested them. Navigating
away cancels active work and removes queued work for that tab. Cached content can remain visible
while a lower-priority revalidation runs.

## Typed route map

Every route stores its host so the same value works for `github.com` and authenticated Enterprise
hosts. `GitHubRepository` contains `host`, `owner`, and `name`. Numbers use positive integers, and
commit identifiers accept full or abbreviated hexadecimal values until the server resolves them.

| URL pattern | Typed resource | First target support |
| --- | --- | --- |
| `/` | `home` | Fully native |
| `/search?q=...&type=...` | `search(query:type:)` | Fully native |
| `/{account}` | `account(name:)` | Native read-only |
| `/orgs/{org}` | `organization(name:)` | Native read-only |
| `/{owner}/{repo}` | `repository(repository:)` | Fully native |
| `/{owner}/{repo}/tree/{revision-path}` | `content(kind:.tree, revisionPath:)` | Fully native |
| `/{owner}/{repo}/blob/{revision-path}` | `content(kind:.blob, revisionPath:)` | Fully native |
| `/{owner}/{repo}/raw/{revision-path}` | `content(kind:.raw, revisionPath:)` | Native read-only |
| `/{owner}/{repo}/commits/{revision}/{path?}` | `commits(reference:path:)` | Fully native |
| `/{owner}/{repo}/commit/{oid}` | `commit(oid:)` | Fully native |
| `/{owner}/{repo}/blame/{revision-path}` | `blame(revisionPath:)` | Fully native |
| `/{owner}/{repo}/compare/{base}...{head}` | `comparison(base:head:)` | Fully native |
| `/{owner}/{repo}/branches` | `branches` | Fully native |
| `/{owner}/{repo}/tags` | `tags` | Fully native |
| `/{owner}/{repo}/pulls` | `pullRequests(filters:)` | Later native slice |
| `/{owner}/{repo}/pull/{number}` | `pullRequest(number:)` | Later native slice |
| `/{owner}/{repo}/issues` | `issues(filters:)` | Later native slice |
| `/{owner}/{repo}/issues/{number}` | `issue(number:)` | Later native slice |
| `/{owner}/{repo}/actions` | `actions` | Later native slice |
| `/{owner}/{repo}/actions/runs/{id}` | `workflowRun(id:)` | Later native slice |
| `/orgs/{org}/projects/{number}` | `organizationProject(number:)` | Later native slice |
| `/users/{user}/projects/{number}` | `userProject(number:)` | Later native slice |
| `/{owner}/{repo}/projects/{number}` | `repositoryProject(number:)` | Later native slice |
| `/{owner}/{repo}/settings/{section?}` | `repositorySettings(section:)` | Opens on GitHub initially |
| `/settings/{section?}` | `accountSettings(section:)` | Opens on GitHub initially |

Line fragments are separate typed values:

- `#L18` becomes `GitHubLineSelection.single(18)`.
- `#L18-L27` becomes `GitHubLineSelection.range(18...27)`.
- Reversed or nonpositive ranges are rejected instead of silently corrected.

The segments after `tree`, `blob`, `raw`, and `blame` are intentionally stored as an unresolved
revision path when a URL is pasted. Branch names and file paths can both contain `/`, so the URL is
ambiguous without repository data. The resolver loads a bounded branch and tag set, then chooses
the longest matching ref prefix. A commit prefix is accepted directly. If no ref matches, the UI
shows an explicit missing-ref state.

Internal navigation already knows the selected ref and uses a resolved `GitHubContentLocation`.
Serializing that location recreates the canonical GitHub URL.

## Browser and session state

`GitHubBrowserSession` is a versioned, Codable document in Application Support. It stores:

- Ordered tabs and the selected tab identifier
- Pinned state and display title
- Back and forward entries per tab
- Current address-bar draft separately from the committed route
- Per-entry scroll anchor, horizontal offset, selected lines, file wrapping, and find position
- A bounded recently closed list
- The last selected host and repository picker context

Tab mutations are synchronous model operations followed by a debounced atomic save. Navigation is
recorded only after a route parses. Reload retains the same history entry and invalidates its
resource cache. Closing the final unpinned tab creates a new home tab. Pinned tabs require an
explicit close action.

Command-click opens a resolved link in a background tab. Context menus offer Open in New Tab,
Open in New Window, Copy Link, and Open on GitHub. External links never enter a native GitHub route.

## UI loading language

Skeletons are the default initial loading state. Each skeleton mirrors the final layout so content
does not jump when data arrives:

- Home uses repository and pull request cards with stable icon, title, metadata, and badge slots.
- Repository lists use rows with owner, name, visibility, language, activity, and description
  placeholders.
- The file browser uses fixed-depth tree rows, breadcrumb blocks, a file header, metadata chips,
  and code-line placeholders.
- Code skeletons include a line-number rail and varied source widths inside the same horizontal
  scroll container as the final viewer.
- Commit history, blame, comparison, and detail screens reserve avatar, summary, status, and action
  geometry.
- Preview skeletons reserve the expected media or document aspect ratio when metadata provides it.

Skeleton motion follows Reduce Motion. With motion enabled, one subtle shared shimmer passes across
the surface. With motion reduced, placeholders remain static. Cached stale content is never
replaced by a skeleton during revalidation. Small progress indicators are limited to explicit
actions such as reload, retry, commit, upload, or download.

Every resource also has explicit offline, empty, permission-denied, rate-limited, unavailable, and
error states. A blank content area is never a valid state.

## Module layout

```text
Packages/Edith/Sources/EdithCore/GitHub/
  GitHubRoute.swift

Packages/Edith/Sources/EdithKit/Features/GitHub/
  Models/
    GitHubModels.swift
    GitHubRateLimit.swift
    GitHubSession.swift
  Services/
    GitHubCache.swift
    GitHubClient.swift
    GitHubCLITransport.swift
    GitHubRecentStore.swift
    GitHubRequestScheduler.swift
  Operations/
    GitHubOperations.swift

Packages/Edith/Sources/Edith/Features/GitHub/
  ViewModels/
    GitHubBrowserModel.swift
    GitHubResourceModel.swift
  Views/
    GitHubPage.swift
    GitHubBrowserChrome.swift
    GitHubHomeView.swift
    GitHubRepositoryView.swift
    GitHubCodeView.swift
    GitHubMarkdownView.swift
    GitHubPreviewView.swift
    GitHubSkeletons.swift
```

The feature remains in the existing targets. A separate Swift package would make shared defaults,
extension lifecycle, preview infrastructure, and app navigation harder to reuse without improving
isolation.

## CLI transport

`GitHubCLITransport` locates `gh` through `CLIToolEnvironment`, never through a login shell. It uses
argument arrays and the sanitized process environment. The generic command result must preserve
stdout and stderr separately so JSON decoding never sees diagnostic text.

Stable `gh` commands with `--json` are preferred. Missing surfaces use `gh api`:

- REST for repository metadata, refs, trees, blobs, commits, comparisons, and paginated lists
- GraphQL for fields that would otherwise cause many REST requests
- `gh api --include` when response headers are needed
- `--hostname` for an authenticated Enterprise host

The transport decodes a typed header and body envelope. It understands `Link`, `ETag`,
`Last-Modified`, `Retry-After`, `X-RateLimit-Limit`, `X-RateLimit-Remaining`,
`X-RateLimit-Reset`, and `X-RateLimit-Resource`. Diagnostics are sanitized and never include
environment values, authorization headers, or tokens.

## Scheduling and retries

`GitHubRequestScheduler` is an actor with three priorities:

1. Visible navigation and direct user actions
2. Explicit pagination and user refresh
3. Cache revalidation, recents enrichment, and prefetch

Only one API request for a tab starts at a time. A small global concurrency cap allows unrelated
tabs to progress without causing bursty API traffic. Identical reads coalesce behind one in-flight
request. Cancellation removes queued work and terminates the active subprocess.

Automatic retries apply only to idempotent reads. The scheduler respects `Retry-After` and rate
limit reset dates, adds bounded jitter for secondary limits, and publishes the retry date to the
UI. Authentication, validation, permission, and not-found failures do not retry automatically.

## Cache and recent repositories

The cache is an actor-backed memory and disk store under Edith's cache directory. Each entry
contains a schema version, canonical request key, payload, ETag, last-modified value, stored date,
stale date, expiry date, and last-access date.

Reads follow stale-while-refresh behavior:

1. Return a fresh entry immediately.
2. Return a stale entry immediately and enqueue conditional revalidation.
3. On `304`, refresh metadata without rewriting the payload.
4. On a recoverable failure, keep stale content with a visible status.
5. On hard expiry without usable content, show a skeleton followed by the terminal state.

Tree and blob cache keys include host, repository, resolved object ID, path, and representation.
Commit-addressed content can use a long lifetime. Branch-addressed content revalidates more often.
A byte budget and least-recently-used eviction prevent large files and media from growing without
bound.

Recent repositories merge four bounded sources:

- Repositories opened inside Edith
- A limited server query ordered by recent activity
- Locally pinned and remotely starred repositories
- Current remote search results

Every result records its source. Edith does not claim this is GitHub's unavailable complete
recently-viewed list.

## First three pull request boundaries

### Pull request 1: extension and browser foundation

- Register the extension, `gh` tool, lifecycle, readiness, settings, and main destination
- Add typed route parsing and serialization, including line fragments and Enterprise hosts
- Add tab, history, recently closed, pin, duplicate, reorder, and restoration models
- Add native browser chrome with address parsing and complete skeleton, empty, auth, and error states
- Add fixture-driven route, state restoration, auth, and cancellation tests

### Pull request 2: repository discovery and lazy tree

- Add recent repositories, recent pull requests, organization picker, and remote search
- Add repository, branch, tag, and commit pickers
- Add lazy tree loading, breadcrumbs, pagination, conditional caching, and offline fallback
- Add repository-list and tree skeletons plus integration fixtures and UI tests

### Pull request 3: file reading and addressable code

- Add virtualized code rows, line numbers, ranges, wrapping, find, and scroll restoration
- Add copy code, copy permalink, raw view, history, blame entry points, and symbol outline
- Add Markdown, image, PDF, audio, video, binary, large-file, notebook, symlink, submodule, and LFS
  states
- Add code and preview skeletons plus URL, cache, fixture, and UI tests

Commit history, commit detail, comparison, and deeper blame behavior can follow in another focused
slice if the third diff approaches the review limit.

## Fixture repository and organization

Use a dedicated non-sensitive organization and repository. The fixture must include:

- Public, private, archived, empty, template, fork, and read-only repositories
- Default and nondefault branches, a branch containing `/`, annotated and lightweight tags, and a
  detached commit route
- Deep directories, empty directories, Unicode paths, spaces, case collisions, and very large trees
- Small, large, minified, generated, extensionless, and invalid UTF-8 text files
- Images, PDFs, audio, video, notebooks, symlinks, submodules, Git LFS pointers, and binary blobs
- GitHub-flavored Markdown with every supported block, relative asset, anchor, reference, alert,
  table, task list, sanitized HTML case, and Mermaid diagram
- Commits by several authors, renamed files, deleted files, merge commits, and blame boundaries
- Open, draft, merged, closed, conflicted, review-requested, and change-requested pull requests
- Passing, failing, cancelled, skipped, and timed-out workflows with logs and artifacts
- Issues, sub-issues, discussions, releases, packages, deployments, environments, Projects, rulesets,
  advisories, and permission-restricted settings
- A least-privilege collaborator and a no-access account for permission-state research

Fixture identifiers are configuration, not hard-coded product behavior. Sanitized CLI responses are
checked into test fixtures. Browser recordings stay outside version control.

## Risks and API limitations

- A pasted content URL cannot identify a slash-containing ref without repository data. Resolution
  must remain asynchronous and explicit.
- GitHub has no reliable API for a complete recently viewed repository list.
- REST Contents responses have size and representation limits. Large files need tree metadata,
  blob endpoints, raw streaming, or an explicit download state.
- Git LFS pointers describe content that may require a separate authenticated media request.
- Blame, Projects, merge queue, rulesets, security products, and some Enterprise versions differ in
  GraphQL or REST availability.
- `gh` command JSON fields and GitHub API previews can change. Fixture tests must pin every decoded
  response shape and tolerate additive fields.
- Primary and secondary limits have different recovery rules. A retry countdown must not imply that
  an exact reset is guaranteed.
- Enterprise hosts vary by version and enabled products. A typed route can exist even when its
  screen reports Opens on GitHub or Unavailable.
- Private media must be materialized through authenticated `gh` requests into Edith's cache, never
  handed to an unauthenticated remote URL loader.
- Markdown HTML must be sanitized before rendering. Script execution and embedded web content are
  never supported.

## Support classification

Every route resolves to exactly one visible classification:

- Fully native
- Native read-only
- Opens on GitHub
- Unavailable, with the reason and recovery action

The classification belongs to route capability metadata so the address bar, context menus, search
results, and destination view cannot disagree.
