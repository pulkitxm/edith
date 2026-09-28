# BlitzTree

Enable **BlitzTree** in Extensions, then open **Maintenance > BlitzTree**.
This is a native implementation inside Edith, inspired by
[BlitzTree](https://github.com/ahmedkhaleel2004/blitztree). The scanner and UI ship
with Edith. No separate app, CLI, Rust installation or download is required.

```sh
ed extensions enable blitztree
ed app reveal blitztree
```

## Explore disk space

Choose a folder to start a scan. Click a folder in the treemap or the lists to
scan inside it. Back returns to the previous folder. Rescan refreshes the current
folder; Cancel stops the scanner. Leaving the page also cancels an active scan.
Nothing scans automatically on launch or when the extension is enabled.

Switch between Treemap and Rings to visualize the current folder. Both show the
60 largest immediate children, sized by allocated bytes,
with an Other block for unlisted space and folder metadata. Each list contains at
most 200 entries. Largest files and folders use a 50 MB threshold. Lists overlap
and must not be added together. Cleanup candidates use Edith's developer-cache
catalog, with project markers for Cargo, Next.js and Python environments. Nested
candidates and the Trash are excluded. Reveal in Finder lets you inspect items
before deciding what to remove. The Trash button asks for confirmation, verifies
that the selected item still matches the scan, moves it to the macOS Trash and
rescans the folder. It never empties the Trash or permanently deletes files.

The native scanner walks filesystem metadata on a background task. It keeps
bounded result lists and a directory stack instead of retaining every file.
Hard-linked file bytes count once, attributed to the first encountered name.
Directory symlinks are listed but not traversed; a selected root symlink is
resolved. Scans stay on one volume and skip cloud-only directories. Partial scans
show their error and skipped-directory counts.

Allocated bytes are disk footprint, not guaranteed recoverable space. APFS clones,
snapshots and open files affect recovery. Full Disk Access for Edith is optional
and can make protected folders readable. Scan reports stay in memory and are not
uploaded or synced.
