# Agent guide

GitHub Actions runs the checks and cuts the release. Workflows live in
`.github/workflows/`, and Dependabot in `.github/dependabot.yml`. A pull
request runs the checks. A push to `main` runs them again, and a product
change on `main` publishes the next release.

## Development builds

Every worktree builds and runs its own development app, so several branches can
run at once next to the installed Edith without touching it or each other.

- `./build.sh` builds, stops this worktree's previous development build, and opens
  `dist/Edith.app`. It runs as `Edith (<slot>)` with bundle identifier
  `com.pulkit.edith.dev.<slot>`, where the slot is the worktree folder name
  without the `edith-` prefix (`main` for the primary checkout). Use
  `./build.sh --no-open` to build without launching.
- Each slot has its own background agent (`com.pulkit.edith.dev.<slot>.agent`),
  menu bar helper, preferences, keychain items and data under
  `~/Library/Application Support/Edith Dev/<slot>`, with caches and logs under
  the matching `Caches` and `Logs` folders. A new slot starts empty and asks for
  macOS permissions again.
- Talk to a development build with its own CLI,
  `dist/Edith.app/Contents/MacOS/ed`. The `ed` on your `PATH` is the installed
  app's CLI and reaches the installed agent.
- The app loads its agent with `launchctl bootstrap` when it opens and unloads
  it, along with its menu bar helper, when it quits. Development builds never
  register login items or the lid-awake daemon, so never register or restart the
  production labels (`com.pulkit.edith.agent`, `com.pulkit.edith.helper.v2`,
  `com.pulkit.edith.lidawake.v2`) from a development build or by hand.
- Run `./build.sh --teardown` before deleting a worktree. It stops the build and
  removes its data, preferences, keychain items and permission grants.
  `./build.sh --gc` does the same for slots whose worktree is already gone and
  removes production copies outside `/Applications` from LaunchServices.
- If `build.sh` reports that a slot belongs to another worktree, rename this
  worktree's folder rather than deleting the other slot.
- Only `/Applications/Edith.app` runs as Edith. `./build.sh --release --install`
  is the only way to replace it; a Release build left in `dist/` is never opened
  and refuses to start there.

See `docs/background-agent.md` for how the identities, agent loading and
LaunchServices cleanup work.
