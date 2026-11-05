---
name: edith-icons
description: Design, add, change or use an icon in Edith. Use whenever a change needs any icon or glyph in the app or an extension, including extension manifests, guide steps, buttons, menus, status items and empty states, or when someone asks for a new icon, a redraw, or an icon review. Every icon must come from the EdithIcons package and be drawn for it.
---

# Edith Icons

Edith draws its own icons. Every icon in the app comes from `Packages/EdithIcons`
and was drawn for that package, on its grids, by the process below.

## The rule

- Never reuse an icon from anywhere. That means no SF Symbols, no icon font, no
  open source set such as Lucide, Heroicons, Tabler or Phosphor, and no asset
  copied, traced or adapted from another product, repository or website.
- If the icon you need does not exist, draw it. Never substitute a system symbol
  "for now", and never add a local shape to a feature.
- Do not call `Image(systemName:)`, `Label(_, systemImage:)`,
  `NSImage(systemSymbolName:)` or any API that takes an SF Symbol name.
- `make ci-icons` fails on any of these outside the listed exceptions.

The only exceptions:

- Marks that identify someone else's product, such as an agent, service or
  provider logo shown next to its name. These are their brand, not our iconography.
- User content, such as an app's own icon, a file preview or a favicon.
- Chrome macOS draws for us, such as window controls and native menu chevrons.

## Design system

`Packages/EdithIcons/DESIGN.md` is the full specification, including grids,
keylines, diagonal stem widths and the concept table for every icon. Read it
before drawing. The essentials:

- **An icon is a small solid object, not a line drawing.** A front plate at full
  opacity carries the subject.
- **Optional back plate** at 45% opacity of the same color, for context.
- **The slit.** Where plates overlap, the back plate is cut away by exactly one
  grid unit. This gap is the signature of the set.
- **Cuts.** Detail inside a front plate is knocked out so the surface shows through.
- **One color.** Tone comes from opacity, so every icon follows the selected
  theme. No gradients, glows, or second colors.
- **No container.** Never wrap an icon in a tinted rounded square.
- **Two drawings per icon.** A 16 grid and a 20 grid, drawn separately. The small
  cut drops detail and moves stems onto whole pixels. It is not a scaled copy.
- **Geometry.** Edges are horizontal, vertical, 45 degrees or a circular arc.
  Terminals are flat. Every axis-aligned edge sits on a whole unit. Stems are 2
  units, heavy stems 3. Diagonals use only the widths listed in `DESIGN.md`.
- **Sizes.** Use 16, 20, 24, 32, 40, 60 or 80 points. They are pixel exact at 2x.
  28 is measurably soft, so avoid it.

## What makes an icon look generated

Reject your own drawing if any of these apply:

- A sparkle, star, wand, glowing orb, gradient blob, neon or purple accent.
- A tinted rounded-square chip, or a back plate that becomes one.
- Hairline outlines or rounded stroke caps, which read as a stock line pack.
- A generic metaphor. Draw what this tool does, not what any tool might do.
- Sparkles meaning "smart". Show the action instead.

## Process

1. Check `DESIGN.md` and `Sources/EdithIcons/EdithIcon.generated.swift`. Reuse an
   existing Edith icon only when it means the same thing. Do not bend one to fit.
2. Write the concept in one line: the object, and what it does. If you cannot,
   the concept is not ready.
3. Sketch the concept in at least two ways, and pick the one that reads at 16pt.
4. Draw both cuts in `tools/icons-controls.mjs`, or `tools/icons-app.mjs` for a
   tool, suite or permission. The tools compute the slits and booleans. Never
   edit `svg/` by hand: it is written from these files. For a control, keep to
   one plate, the 12 unit optical box, and even units where you can.
5. Build, generate and test, from `Packages/EdithIcons`. Run `bun install` in
   `tools/` once first.

   ```sh
   bun tools/build.mjs
   bun scripts/generate.ts
   bun scripts/generate.ts --check
   bun tools/audit.mjs
   swift test
   ```

   Never edit `EdithIcon.generated.swift` or `names.json` by hand. The audit must
   report no off-grid axis edges.
6. Render every review sheet with `bun tools/sheets.mjs`. It writes to `local/icons/`
   at 16, 20, 24, 28, 32, 40, 64 and 128 points, at 1x and 2x, in dark and light,
   in other themes, beside real 13pt text and inside native controls. Open the
   images and look at the pixels, zoomed. Fix blurred stems, uneven optical weight
   and anything that merges at 16pt. While drawing, `bun tools/sheets.mjs plus,trash`
   renders only those icons to `local/icons/focus.png`.
7. Compare the new icon beside its neighbors in the set. It fails if it looks
   heavier, lighter or from a different hand, or if it is confusable at 16pt with
   another icon. Check `local/icons/confusable-16pt.txt`: a pair near the top that
   is not a deliberate variant needs a new silhouette. A set is only as good as
   its weakest icon.
8. Add a row to the concept table in `DESIGN.md`. Describe the object and what it
   does, never the symbol it replaces.

## Using an icon

Use the shared views so size, zoom, theme and pixel alignment are handled for you.
`EdithExtensionUI` re-exports the package, so extensions need no extra dependency.
See "Using the package" in `DESIGN.md` for the full API.

- Next to text, use `EdithIconView(.plus)` with no size. It follows the surrounding
  font, and `.font(...)` still works.
- For a title and an icon, use `Label("Rename", edith: .edit)` or
  `Button("Rename", edith: .edit) {}`. They also work inside menus, which
  `EdithIconView` does not.
- For a real image, use `EdithIcon.plus.image()` or `.nsImage()`.
- For a fixed slot in the app, use `PageIcon` or `PageGuideBadge`.
- For an off state, use `tone: .muted`. Do not draw an outline version.
- From a string, use `EdithIcon(name:)`. An unknown name shows a placeholder.

- Extension manifests name their icons by Edith icon name, and
  `bun scripts/extension-index.mjs --check` rejects a name that does not exist.
  Scripts read valid names from `Packages/EdithIcons/names.json`.
- Color comes from the surrounding `foregroundStyle`. Use the kit's accent for
  heroes and `inkSoft` for dense rows.
- Icons are decorative to VoiceOver. The surrounding control carries the label.
- Reference icons by name, not with drawn shapes or image files in a feature.
