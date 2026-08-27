# Finder Tools

Finder Tools adds focused shortcuts and installation assistance to macOS Finder. It does not add another file browser.

Enable the extension and inspect its readiness:

```bash
ed extensions setup finderTools
ed extensions status finderTools --json
```

The extension can move Finder selections with Command-X and Command-V, rename the current selection with F2, save a copied image into the open Finder folder as a PNG file, and offer to install the single app found on a mounted disk image. Copying an image file still uses Finder's normal file paste instead of creating a duplicate PNG.

Accessibility is required for the Finder keyboard shortcuts. macOS asks for Finder Automation access on first use when Edith reads the current selection or destination. The disk image installer only accepts a real DMG mount containing exactly one executable app bundle. It verifies the copied app before placing it in `/Applications`, never replaces an existing app, ejects the disk image after a successful install, and only then moves the unchanged DMG to Trash.

Each behavior can be changed from Settings, Extensions, Finder Tools, or from the CLI:

```bash
ed config ls --group findertools
ed config set finderToolsCutPaste false
ed config set finderToolsRename true
ed config set finderToolsPasteImages true
ed config set finderToolsDiskImageInstaller true
```

If shortcuts stop responding, refresh Accessibility after changing System Settings:

```bash
ed permissions refresh
ed extensions doctor finderTools
```

[Back to the CLI reference](../README.md)
