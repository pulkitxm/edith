# BlitzTree

Enable **BlitzTree** in Extensions, then open **Maintenance > BlitzTree**.
It uses [BlitzTree](https://github.com/ahmedkhaleel2004/blitztree)'s Rust scan
engine through its versioned, read-only JSON CLI.

## Setup

Install Rust from [rustup.rs](https://rustup.rs) and Xcode Command Line Tools
(`xcode-select --install`). Extension setup builds the CLI from pinned upstream
revision `d5a0fc8c30b150969f4c6066520f0cadc87a9eb6` using Cargo's locked dependencies.
The standalone BlitzTree app's DMG does not contain the CLI.

```sh
ed tools install blitztree
ed extensions enable blitztree
ed extensions verify blitztree --json
ed app reveal blitztree
```

## Explore disk space

Choose a folder to start a scan. Click a folder in the treemap or the lists to
scan inside it. Back returns to the previous folder. Rescan refreshes the current
folder; Cancel stops the scanner. Leaving the page also cancels an active scan.
Nothing scans automatically on launch or when the extension is enabled.

The treemap shows immediate children, sized by allocated bytes, with an Other
block for unlisted space. Each list contains at most 200 entries. Largest files
and folders use the upstream 50 MB threshold. Lists overlap and must not be added
together. Cleanup candidates use the same rules as BlitzTree's Clean Up panel.
Reveal in Finder lets you inspect each item before deciding what to remove.
Edith does not delete anything from this page.

Allocated bytes are disk footprint, not guaranteed recoverable space. Hard links,
APFS clones, snapshots and open files affect recovery. Scans stay on one volume,
skip cloud-only directories and do not follow directory symlinks. Partial scans
show their error and skipped-directory counts. Full Disk Access for Edith is
optional and can make protected folders readable; folder access still follows
macOS permissions. Scan reports stay in memory and are not uploaded or synced.
