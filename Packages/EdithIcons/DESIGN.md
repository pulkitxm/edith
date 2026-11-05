# Edith icon system

Edith's proprietary icon set. Every shape here was drawn for this package on
the grids below. Nothing is traced from, or derived from, SF Symbols, Lucide,
Heroicons, Tabler, Phosphor or any other set.

## The idea: plate and slit

An Edith icon is a small solid object, not a line drawing.

- **Front plate.** The subject, at full opacity. It carries most of the ink.
- **Back plate.** Optional context, at 45% opacity of the same color.
- **The slit.** Where a front plate overlaps a back plate, the back plate is
  cut away by exactly one grid unit. This gap is the signature of the set.
- **Cuts.** Detail inside a front plate is knocked out, so the surface behind
  shows through (the prompt in Terminal, the event in Calendar).

An icon is one color. It is never a gradient, a glow, or a color pair.

### Rules that keep it from reading as generated

1. No sparkles, stars, wands, orbs, gradients or neon, anywhere.
2. No tinted rounded-square chip, and no hairline outlines.
3. A back plate must never be the dominant rounded square. At 45% over a dark
   surface that shape is the old brown chip again. Keep the rounded plate in
   front and knock detail out of it.
4. Every icon draws what the tool does, not a generic metaphor.

## Grids

| | Small cut | Regular cut |
| --- | --- | --- |
| Grid | 16 by 16 | 20 by 20 |
| Live area | 1 to 15 | 2 to 18 |
| Pixel exact at 1x | 16, 32, 48 | 20, 40, 60 |
| Pixel exact at 2x | 16, 24, 32, 40, 48 | 20, 30, 40, 50, 60 |
| Slit | 1 | 1 |
| Stem, axis aligned | 2 | 2 |
| Heavy stem | 3 | 3 |
| Corner, large plate | 1 to 2 | 2 to 3 |
| Corner, small part | 0.5 to 1 | 1 |

Both cuts are drawn separately. The small cut is not a scaled regular cut: it
drops detail and moves stems so they land on whole pixels.

### Keylines

Optical size is set by shape, so all icons feel equally large.

| Shape | Small cut | Regular cut |
| --- | --- | --- |
| Circle | diameter 14 | diameter 16 |
| Square | 12 to 14 | 14 |
| Landscape | 14 by 10 to 12 | 16 by 12 to 14 |
| Portrait | 10 to 12 by 14 | 12 by 16 |

Long diagonal objects such as the broom may run past the live area, up to the
grid edge, because a diagonal looks smaller than its bounding box.

## Geometry

- **Angles.** Edges are horizontal, vertical, 45 degrees, or a circular arc.
  Curves are used only where the object needs them (a bell, a book page).
- **Terminals.** Flat and square cut. Round caps blur at 16pt at 1x and are
  what make a set look like a stock line pack.
- **Edge placement.** Every horizontal and vertical edge sits on a whole unit.
- **Circles.** Extreme points sit on whole units: an even diameter takes a
  whole center and an odd diameter takes a half center. A 3 unit dot on a
  whole center straddles pixels and is forbidden.
- **45 degree stems.** A diagonal is only crisp when its edges pass through
  pixel corners, which fixes its width. Use these widths on these centerlines:

| Width | Horizontal run | Centerline |
| --- | --- | --- |
| 1.414 | 2 | `x + y` is whole |
| 2.121 | 3 | `x + y` is a half |
| 2.828 | 4 | `x + y` is whole |
| 3.536 | 5 | `x + y` is a half |

A stem of 2 or 3 on a diagonal looks soft at 1x. Butt ends on these stems sit
on a whole `x - y` or `x + y` line for the same reason.

- **Slit exceptions.** A gap on the center line of an even grid has to be 2
  units to stay on whole pixels (Docs gutter).
- **Minimum sizes.** A positive part is at least 2 units wide, and a knocked
  out detail is at least 1 unit.

## Tone

`EdithIconTone.duotone` draws the back plate at 45% of the foreground color,
so any theme, accent or ink works with a single color and nothing else.
`.monochrome` draws both plates at 100%. The slit still separates them, so
monochrome stays legible for template images and selected states.

## Optical sizing

`EdithIconCut.optical(for:)` picks the cut by point size:

- Below 18pt, and at exactly 24pt and 32pt: the small cut. At 2x those two
  sizes land on whole pixels on the 16 grid.
- Everything else: the regular cut.

Prefer these sizes: **16, 20, 24, 32, 40, 60, 80**. They are all pixel exact on
Retina displays. Measured partial coverage at 2x is about 1 to 3% at these
sizes, against 8.5% at 28pt. 64 and 128 use the regular cut and are not pixel
exact, which does not show at that scale. Window zoom through `UIScale.pt`
produces other sizes, and those are antialiased.

## Container: none

The tinted rounded-square chip is removed, not replaced. It is the element
that makes the app look generic. It also wastes the slot, shrinking the glyph
to 42% of its size so that a 40pt tile holds a 17pt symbol. Without it, the
same slot holds an icon of 32pt optical size.

| Current | Size | Replacement |
| --- | --- | --- |
| `HostExtensionIcon` | 40 | `EdithIconView(icon, size: 40)` in the same 40pt slot |
| `HostExtensionIcon(prominent: true)` | 40 | Same, with `tone: .monochrome` |
| `PageGuideBadge` | 48 to 64 | `EdithIconView(icon, size: 60)` |
| `HostOnboardingIcon` | 32 to 44 | `EdithIconView(icon, size: 32)` or `40` |

Accent suits heroes and cards. Use `inkSoft` for dense rows and section
headers, so that the accent keeps its meaning.

## Concepts

Raw values match extension ids, so `EdithIcon(rawValue: extensionID)` resolves
any manifest entry. The Replaces column lists the SF Symbol in use today.

### Brand

| Icon | Replaces | Concept |
| --- | --- | --- |
| `brand` | `sparkles` | A round-backed E whose middle stroke is a free pill, the shape of the notch where Edith lives |

### Extensions

| Icon | Title | Replaces | Concept |
| --- | --- | --- | --- |
| `appMaintenance` | App Updates | `shippingbox.and.arrow.backward` | Tile with an up arrow, older version peeking beneath |
| `attention` | Attention | `hourglass` | The day as a disc, one slice lifted out |
| `audioMixer` | Audio Mixer | `slider.horizontal.3` | Three console faders at different levels |
| `bifrost` | Launcher | `rainbow` | The launcher bar with caret, results below |
| `blitztree` | Disk Map | `square.grid.3x3.fill` | A treemap with its largest block lit |
| `calendar` | Calendar | `calendar` | A page with the next meeting cut out |
| `cleaner` | Cleaner | `sparkles.rectangle.stack` | A broom, bristle head forward |
| `clipboard` | Clipboard | `doc.on.clipboard` | A clipboard with its clip slotted in |
| `codeStats` | Code Stats | `chart.line.uptrend.xyaxis` | A commit heatmap with a rising streak |
| `colorPicker` | Color Picker | `eyedropper` | An eyedropper |
| `companion` | Memory | `brain.head.profile` | A card index box with tabbed cards |
| `database` | Database | `cylinder.fill` | Stacked disks, the top one lit |
| `docs` | Docs | `book.closed` | An open reference book |
| `downloads` | Downloads | `arrow.down.circle` | A solid arrow landing on a tray |
| `emoji` | Emoji Picker | `face.smiling` | A winking face |
| `focusDim` | Focus Dim | `circle.lefthalf.filled` | A clear front window over a hatched, dimmed one |
| `herdr` | Agents | `rectangle.split.3x1.fill` | A formation of prompt chevrons: a herd, one leading |
| `hinge` | Hinge | `laptopcomputer.and.arrow.down` | A lid on its pivot with a sweep arc |
| `homebrew` | Homebrew | `cube.box` | A mug with a head of foam |
| `jev` | Jev | `sparkles` | A path reaching a fork, one way taken |
| `keepAwake` | Keep Awake | `moon.zzz` | An open eye |
| `keystrokeHighlight` | Keystroke Highlight | `keyboard.badge.ellipsis` | A single keycap |
| `latex` | LaTeX | `doc.richtext` | A sigma |
| `lidAwake` | Lid Awake | `laptopcomputer` | The open eye above a closed lid |
| `machines` | Machines | `desktopcomputer` | A server rack with status lights |
| `micMute` | Mic Mute | `mic.slash.fill` | A struck through microphone |
| `music` | Music | `music.note` | A beamed pair of notes |
| `notchShelf` | Notch Shelf | `tray.and.arrow.down` | A notched screen with a move toward the notch |
| `plugins` | Plugins | `square.stack.3d.up` | A plug |
| `presenter` | Presenter | `theatermasks.fill` | A line of text under a hatched redaction bar |
| `quinjet` | Code Review | `arrow.triangle.branch` | A diff: a removed row above an added row |
| `seoAudit` | Site Audit | `doc.text.magnifyingglass` | A web page under a loupe |
| `socialManager` | Social Manager | `person.crop.rectangle.stack` | Two profiles side by side |
| `studio` | Studio | `wand.and.stars` | Crop marks |
| `system` | Running Apps | `switch.2` | Two tiles and the dock's running dot |
| `systemStats` | Menu Bar Stats | `gauge.with.needle` | A gauge |
| `terminal` | Terminal | `terminal` | A solid window with a knocked out prompt |
| `timeLapse` | Screen Recorder | `record.circle` | Capture brackets around a record dot |
| `usage` | Usage | `chart.bar.fill` | Three meters filling toward their limits |
| `virtualCamera` | Virtual Camera | `web.camera` | A webcam on its stand |
| `windowSweaters` | Window Sweaters | `square.dashed` | A knitted sweater with ribbed hem and cuffs |

### Suites and workflows

| Icon | Title | Replaces | Concept |
| --- | --- | --- | --- |
| `suiteAgents` | Agents & Terminal | `sparkles` | Stacked terminal windows |
| `suiteUtilities` | Mac Utilities | `switch.2` | A toolbox |
| `suiteDesk` | Desk | `hand.tap` | A desk with drawers |
| `suiteMedia` | Media | `play.rectangle.on.rectangle` | A film frame with play |
| `suiteDeveloper` | Developer & Data | `cylinder.split.1x2` | Angular braces around a data point |
| `suiteLabs` | Labs | `flask` | A flask, half full |
| `workflowCustom` | Custom | `slider.horizontal.3` | Three tiles and a plus |

### Onboarding steps

| Icon | Title | Replaces | Concept |
| --- | --- | --- | --- |
| `stepWorkflow` | Pick a workflow | `square.grid.2x2` | A signpost with two directions |
| `stepTools` | Choose your tools | `checklist` | Ticked rows |
| `stepAccess` | Allow what they need | `lock.shield` | A key |

### Permissions

The calendar permission uses `calendar`.

| Icon | Title | Replaces | Concept |
| --- | --- | --- | --- |
| `permissionNotifications` | Notifications | `bell.badge` | A bell |
| `permissionAccessibility` | Accessibility | `figure.wave` | A figure with open arms on a disc |
| `permissionInputMonitoring` | Input Monitoring | `keyboard` | A keyboard |
| `permissionFullDisk` | Full Disk Access | `externaldrive` | A drive in perspective |
| `permissionScreenRecording` | Screen Recording | `rectangle.inset.filled.badge.record` | A display with a record dot |
| `permissionApplicationAudio` | Application Audio | `speaker.wave.2` | A speaker with two waves |
| `permissionCamera` | Camera | `camera` | A camera body |
| `permissionBluetooth` | Bluetooth | `wave.3.right` | Headphones, the device the permission exists for |
| `permissionAutomation` | Automation | `gearshape.2` | A gear |

## Utility glyphs stay SF Symbols

Chevrons, close, plus, trash, refresh, check and similar control glyphs stay SF
Symbols. They sit next to system controls, they match the text weight around
them, and users read them as part of macOS. Do not redraw them here. SF Symbols
stay limited to Apple platform UI, so a proprietary mark must never use one.

## Using the package

```swift
import EdithIcons

EdithIconView(.herdr, size: 40)
    .foregroundStyle(DashSkin.accent(dark))

if let icon = EdithIcon(rawValue: entry.id) {
    EdithIconView(icon, size: 20).foregroundStyle(DashSkin.inkSoft(dark))
}

EdithIconShape(.brand, cut: .regular).fill(.white)
```

The view has no resources and no bundle lookups, so it works in any process,
including remote extension processes. It sizes itself to `size` points, inherits
`foregroundStyle`, and is hidden from accessibility because labels belong to the
surrounding control.

## Adding or changing an icon

The SVG files in `svg/` are the source of truth, one per cut:
`<name>.16.svg` and `<name>.20.svg`. Both are required.

Each file holds outlines only: one `path` with `id="primary"` and, optionally,
one with `id="secondary"`. Paths use `fill-rule="evenodd"` and absolute `M L H V
Q C Z` commands. Outline every stroke and flatten every boolean before export.

```sh
bun scripts/generate.ts
bun scripts/generate.ts --check
swift test
```

`EdithIcon.generated.swift` is written from the SVG files and must not be edited
by hand. `--check` fails if it has drifted. The tests also compare every case
against its SVG, so drift fails without bun installed.
