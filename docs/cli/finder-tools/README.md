# Finder Tools

Finder Tools adds focused shortcuts and installation assistance to macOS Finder. It does not add another file browser.

Enable the extension and inspect its readiness:

```bash
ed extensions setup finderTools
ed extensions status finderTools --json
```

The extension can move Finder selections with Command-X and Command-V, rename the current file selection with F2, save a copied image into the open Finder folder as a PNG file, and offer to install the single app found on a mounted disk image. Copying an image file still uses Finder's normal file paste instead of creating a duplicate PNG. Existing destination files are never replaced. If one item in a move batch fails, Edith attempts to restore items it already moved and keeps the cut selection available when the rollback succeeds.

Accessibility is required only when at least one Finder keyboard feature is enabled. macOS asks for Finder Automation access on first use when Edith reads the current selection or destination. Permission refreshes take effect without an unrelated settings change. An installer-only configuration remains available without Accessibility or Automation.

Copied images are inspected off the main app thread. Edith rejects invalid images, encoded payloads larger than 64 MiB, dimensions above 16,384 pixels, or images above 40 million pixels. PNG clipboard data is preserved without a decode and re-encode pass. Other supported image formats are converted to PNG.

The disk image installer only accepts a real DMG mount containing exactly one executable app bundle. It verifies the app with macOS before presenting the install offer, records the app's signing fingerprint and disk-image identity, revalidates both after the prompt, and verifies the staged copy before placing it in `/Applications`. It never replaces an existing app, ejects only the image that was inspected, and only then moves the unchanged DMG to Trash.

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
