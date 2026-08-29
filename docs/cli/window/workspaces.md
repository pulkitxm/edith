# Workspace Restorer

Workspace Restorer saves named profiles of running applications and their restorable windows. A profile records window frames, minimized and full-screen state, display identity and visible bounds, active application, and front-to-back ordering.

Enable the extension and grant Accessibility first:

```bash
ed extensions enable workspaceRestorer
ed permissions request accessibility
```

## Capture and inspect

```bash
ed window workspace capture "Writing"
ed window workspace ls
ed window workspace preview "Writing"
ed window workspace preview "Writing" --json
```

The dry run never launches applications or changes windows. It reports each saved window, its current match confidence, planned action, target display, and remapped frame.

## Restore and recover

```bash
ed window workspace restore "Writing"
ed window workspace restore "Writing" --launch-missing --timeout 20 --concurrency 2
ed window workspace cancel
ed window workspace recover
ed window workspace history --json
```

Restore never closes applications or windows. Existing windows are matched one-to-one by application identity, title, role, display, and captured order. Window changes run sequentially because Accessibility frame mutations are safest in order. Missing applications launch only when `--launch-missing` or the matching setting is enabled.

Before a restore, Edith captures an automatic recovery profile. `recover` applies that snapshot if a partial result, timeout, or cancellation leaves the desktop somewhere you do not want it. Per-window results are retained in bounded history.

## Display changes

Stable display identities win when the same displays remain connected. Missing displays map deterministically using geometry, aspect ratio, size, and relative position. Saved frames are normalized into each target display's current visible frame, then clamped so resized, rotated, added, removed, or reordered displays cannot place a restored window outside usable bounds.

## Manage and transfer profiles

```bash
ed window workspace rename "Writing" "Drafting"
ed window workspace duplicate "Drafting" "Research"
ed window workspace export "Research" ~/Desktop/research-workspace.json
ed window workspace import ~/Desktop/research-workspace.json
ed window workspace delete "Research"
```

Settings provide the same capture, dry-run, restore, cancel, recovery, rename, duplicate, and delete actions. They also configure bundle identifier exclusions, launch policy, timeout, bounded launch concurrency, and global shortcuts for capture and restoring the latest profile. Workspace Restorer actions are registered for Command Bar-compatible surfaces.
