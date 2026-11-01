# Development workflow

Use one worktree and one development app per worker. Build the host from source,
then build and sideload the extensions being changed. A branch does not need a
GitHub Release to run locally. See the [testing guide](testing.md) for acceptance
checks and review evidence.

## What each command builds

| Command | Result | Launches the app? |
| --- | --- | --- |
| `make build` | Current checkout's host in `dist/Edith.app` | Yes, this worktree's development slot |
| `make cli` | Same development host and bundled CLI | No |
| `./build.sh --background` | Same development host | Yes, hidden |
| `make extension-dev EXTENSION=keepAwake` | Local ad-hoc signed package in `dist/extensions/keepAwake.zip` | No, does not install it |
| `make extension-sideload EXTENSION=keepAwake` | Fresh development package, installed into this slot | Requires this slot's app already running |
| `make install` | Release host installed at `/Applications/Edith.app` | Yes, replaces the installed app |

`make build` invokes `./build.sh`. It compiles `Packages/EdithHost` and packages
the host, Sparkle, resources and CLI. Features live in separate extension
packages. Rebuilding the host alone does not rebuild or install changed
extensions. `make build PR=123` and `make build BRANCH=feature-name` select a
source worktree; they are also source builds, not release downloads.

## Prepare a worker

Start from the agreed base commit, with a unique worktree directory and branch.
For example, from an existing checkout:

```sh
git fetch origin main
git worktree add ../edith-calendar-layout -b feature/calendar-layout origin/main
cd ../edith-calendar-layout
bun install --frozen-lockfile
scripts/dev-slots.sh slot
```

Read `AGENTS.md` in that checkout. Give each worker a bounded outcome, owned
files, base commit, dependencies, required checks and expected final proof.
Assign one owner to shared changes such as the manifest, host ABI, build scripts
and shared UI. Dependent work starts from that owner's checkpoint, or waits for
it, rather than independently changing the same contract.

The folder name determines the slot after normalization and removal of the
`edith-` prefix. Use distinct normalized names. Branch switching within a
worktree keeps the same slot and data. The build rejects a slot owned by another
existing worktree; rename your folder instead of removing the other slot.

Stage new source files explicitly before building. The host builder rejects
untracked source inputs. Commit coherent checkpoints through Pukbot so the
source revision used for verification can be reproduced. Do not stage generated
packages, caches or private configuration.

## Build and exercise an unpublished extension

On a Mac with full Xcode, Bun and the extension's native prerequisites:

```sh
make build
dist/Edith.app/Contents/MacOS/ed app info
make extension-sideload EXTENSION=keepAwake
dist/Edith.app/Contents/MacOS/ed extensions info keepAwake
```

The example uses `keepAwake`; use the exact, case-sensitive id in
`Extensions/manifest.json`. Make target names are not always identical to ids:
`keepAwake` has `ci-extension-keep-awake`, for example.

Check that `app info` reports this worktree's bundle path and
`com.pulkit.edith.dev.<slot>` identifier. Use this bundled CLI for every command.
The `ed` on `PATH` reaches the installed app. Commands do not launch the app
implicitly. For unattended work, build with `./build.sh --background`; for a
build without a running app, use `make cli`, then launch `dist/Edith.app` before
sideloading.

Sideloading builds the native prerequisites when needed, gives the package a
fresh patch version, installs it and starts or restarts the extension. It
replaces the catalog version only in this slot. Confirm the installed version
and active state, then exercise the actual changed behavior in the app or CLI.
A package build alone proves neither loading nor feature behavior.

### Dependencies, ABI and reloads

Inspect the extension's `dependencies` in `Extensions/manifest.json`. Sideload
local dependency packages first, in dependency order. Sideload does not download
missing dependencies. If shared host or marketplace contracts changed, rebuild
the host first and rebuild affected extensions against that same checkout.
Packages must match the running host ABI, architecture and minimum macOS version.
Do not edit package metadata to bypass a mismatch.

Swift libraries can remain mapped until the app quits, and owned tasks can delay
replacement. If the new version is waiting for old work to drain, finish or stop
that work and restart this slot. Recheck its version and behavior after restart.
Do not infer that new code is active merely because a ZIP was installed.

### GitHub Releases and offline work

The marketplace downloads published extensions from a signed GitHub catalog.
It cannot supply an unpublished branch's code. Local sideloading supplies that
code without publishing a release or needing production signing credentials.
A new host ABI may have no compatible published packages yet; build and sideload
the required extensions and dependencies locally.

Installed compatible packages and a verified cached catalog can work offline.
A fresh slot has neither. Source builds can still need network access to resolve
SwiftPM, Cargo, Sparkle or other native dependencies. Prepare those dependencies
while online; sideloading removes the release-publication dependency, not every
network dependency. Catalog download, signing and update behavior require their
own marketplace tests and eventual signed release verification.

## Parallel builds without collisions

Parallelize independent outcomes across worktrees. Each checkout owns its
`dist`, `local`, SwiftPM build directories and development app. Do not symlink
mutable build directories between worktrees. Run only one build or test driver
at a time within a checkout. In particular, do not overlap `make build`,
`extension-sideload`, manual Swift builds and `ci-local` there.

Heavy Make targets share the machine resource gate described in `AGENTS.md`.
Keep the same `EDITH_MAKE_GATE_DIR` across workers if overriding its default.
The gate controls CPU and memory admission; it is not a lock on output files.
Direct `./build.sh`, Bun and Swift invocations do not themselves enter the Make
gate. Prefer Make entry points and coordinate direct invocations explicitly.
Do not set `EDITH_MAKE_GATE=skip` to make a busy machine accept more workers.

`make ci-local` schedules lanes inside one run and avoids overlapping declared
Swift package paths. Start with `CI_LOCAL='--jobs=2'` on a shared Mac and lower
it when several workers are compiling. This job count controls lanes, not the
entire machine or every compiler's thread count. The runner's package exclusion
is local to that invocation. Two runners in one checkout still collide, and
logs use the same `local/ci-logs` paths.

A gate timeout means the command did not run. Report it as pending, let existing
work finish, then retry. Do not report a queued or skipped command as a pass.
Workers may build concurrently, but coordinate visible app launches, global
shortcuts and screen capture so one worker does not interrupt another's proof.
Slot isolation does not isolate hardware, clipboard, global shortcuts or
external services.

## Remote development and integration

| Environment | Appropriate work | Remaining verification |
| --- | --- | --- |
| macOS with full Xcode | Host, native extensions, package tests, slot app and CLI | Permissions, hardware and external services used by the feature |
| Headless macOS | Compilation and tests that support unattended execution | Visible UI and any interactive permission or hardware flow |
| Linux server | Portable script tests and supported backend checks | Native app build, package loading and UI on macOS |

Workers on servers hand off a committed revision and their actual test results
to a Mac worker. The Mac checks out that revision in its own worktree, builds
the host and sideloads the changed packages. Downloading the latest release
would test a different revision. Do not use a shared production installation
as the integration environment.

One coordinator integrates the checkpoints into a separate worktree, reruns the
change-selected checks on the combined diff and repeats the end-to-end smoke
flow. Independent worker passes do not prove their combined result. Rebuild and
sideload the affected packages from the integrated revision before capturing
final evidence. Keep each PR coherent and below roughly 2,000 changed lines;
split larger work into ordered PRs.

## Slot lifecycle

Each slot has its own preferences, keychain items, permission grants and data in
`~/Library/Application Support/Edith Dev/<slot>`, with matching caches and logs.
A new slot starts empty. Grant only the permissions needed for the flow. See
[Contributing](../CONTRIBUTING.md) for signing identity setup and permission
stability between rebuilds.

Development apps do not register production login items or the lid-awake daemon.
Never restart or register production service labels to make a development test
pass. Use a separate, explicitly scheduled installed-release check for behavior
that depends on production services or distribution signing.

Run `./build.sh --teardown` before removing your worktree, after saving any
needed synthetic fixtures and results. It deletes slot data and permissions.
`./build.sh --gc` cleans orphaned slots and also affects LaunchServices entries;
it is machine-wide cleanup, so coordinate it with other workers. Avoid `make
reset`, `make reinstall` and `make install` during ordinary parallel development.
