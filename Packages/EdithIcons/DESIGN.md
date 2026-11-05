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

A control glyph follows the same language but is usually a single plate. A back
plate on a chevron or an arrow would be noise.

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

### Control glyphs

Controls sit next to text on every screen, so they follow stricter rules.

- **Optical box.** 12 units on the small cut, 14 on the regular cut, so a control
  next to a tool icon does not look oversized.
- **Single plate.** Use a back plate only where it is the meaning, such as the
  track behind `adjust` or the box behind `share`.
- **Even units.** Prefer even coordinates on the small cut. At 12pt on 2x a unit
  is 1.5 pixels, so only even edges stay on whole pixels.
- **Turn arrows.** Circular arrows end in a solid corner wedge, not an open
  chevron head. This is the set's own arrow, used by `refresh`, `sync`,
  `history`, `rotate` and the seek pair.

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

`EdithIconTone` has three values, and all of them derive from one foreground
color, so any theme, accent or ink works.

- `.duotone` draws the back plate at 45%. This is the default.
- `.monochrome` draws both plates at 100%. The slit still separates them, so it
  stays legible for selected states and status items.
- `.muted` draws the whole icon at 45%. This is the off state: an unsaved heart,
  an unpinned pin, a disconnected network. Do not draw an outline version.

Off states with their own meaning are real drawings: `eyeOff`, `videoOff`,
`wifiOff`, `speakerOff` and `micMute`. Filled and unfilled are not separate icons,
because every icon is already solid.

## Optical sizing

`EdithIconCut.optical(for:)` picks the cut by point size:

- Below 18pt, and at exactly 24pt and 32pt: the small cut. At 2x those two
  sizes land on whole pixels on the 16 grid.
- Everything else: the regular cut.

Prefer these sizes: **16, 20, 24, 32, 40, 60, 80**. They are all pixel exact on
Retina displays. Measured partial coverage at 2x is about 1 to 3% at these
sizes, against 8.5% at 28pt. 64 and 128 use the regular cut and are not pixel
exact, which does not show at that scale. An explicit size from `UIScale.pt` can
land anywhere, and those are antialiased. Font sizing below snaps instead.

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

Raw values match extension ids, so `EdithIcon(name: extensionID)` resolves any
manifest entry. Each row states the object drawn and what it does. Every shape
was drawn from that concept on these grids.

### Brand

| Icon | Concept |
| --- | --- |
| `brand` | A round-backed E whose middle stroke is a free pill, the shape of the notch where Edith lives |

### Extensions

| Icon | Title | Concept |
| --- | --- | --- |
| `appMaintenance` | App Updates | Tile with an up arrow, older version peeking beneath |
| `attention` | Attention | The day as a disc, one slice lifted out |
| `audioMixer` | Audio Mixer | Three console faders at different levels |
| `bifrost` | Launcher | The launcher bar with caret, results below |
| `blitztree` | Disk Map | A treemap with its largest block lit |
| `calendar` | Calendar | A page with the next meeting cut out |
| `cleaner` | Cleaner | A broom, bristle head forward |
| `clipboard` | Clipboard | A clipboard with its clip slotted in |
| `codeStats` | Code Stats | A commit heatmap with a rising streak |
| `colorPicker` | Color Picker | An eyedropper |
| `companion` | Memory | A card index box with tabbed cards |
| `database` | Database | Stacked disks, the top one lit |
| `docs` | Docs | An open reference book |
| `downloads` | Downloads | A solid arrow landing on a tray |
| `emoji` | Emoji Picker | A winking face |
| `focusDim` | Focus Dim | A clear front window over a hatched, dimmed one |
| `herdr` | Agents | A formation of prompt chevrons: a herd, one leading |
| `hinge` | Hinge | A lid on its pivot with a sweep arc |
| `homebrew` | Homebrew | A mug with a head of foam |
| `jev` | Jev | A path reaching a fork, one way taken |
| `keepAwake` | Keep Awake | An open eye |
| `keystrokeHighlight` | Keystroke Highlight | A single keycap |
| `latex` | LaTeX | A sigma |
| `lidAwake` | Lid Awake | The open eye above a closed lid |
| `machines` | Machines | A server rack with status lights |
| `micMute` | Mic Mute | A struck through microphone |
| `music` | Music | A beamed pair of notes |
| `notchShelf` | Notch Shelf | A notched screen with a move toward the notch |
| `plugins` | Plugins | A plug |
| `presenter` | Presenter | A line of text under a hatched redaction bar |
| `quinjet` | Code Review | A diff: a removed row above an added row |
| `seoAudit` | Site Audit | A web page under a loupe |
| `socialManager` | Social Manager | Two profiles side by side |
| `studio` | Studio | Crop marks |
| `system` | Running Apps | Two tiles and the dock's running dot |
| `systemStats` | Menu Bar Stats | A gauge |
| `terminal` | Terminal | A solid window with a knocked out prompt |
| `timeLapse` | Screen Recorder | Capture brackets around a record dot |
| `usage` | Usage | Three meters filling toward their limits |
| `virtualCamera` | Virtual Camera | A webcam on its stand |
| `windowSweaters` | Window Sweaters | A knitted sweater with ribbed hem and cuffs |

### Suites and workflows

| Icon | Title | Concept |
| --- | --- | --- |
| `suiteAgents` | Agents & Terminal | Stacked terminal windows |
| `suiteUtilities` | Mac Utilities | A toolbox |
| `suiteDesk` | Desk | A desk with drawers |
| `suiteMedia` | Media | A film frame with play |
| `suiteDeveloper` | Developer & Data | Angular braces around a data point |
| `suiteLabs` | Labs | A flask, half full |
| `workflowCustom` | Custom | Three tiles and a plus |

### Onboarding steps

| Icon | Title | Concept |
| --- | --- | --- |
| `stepWorkflow` | Pick a workflow | A signpost with two directions |
| `stepTools` | Choose your tools | Ticked rows |
| `stepAccess` | Allow what they need | A key |

### Permissions

The calendar permission uses `calendar`.

| Icon | Title | Concept |
| --- | --- | --- |
| `permissionNotifications` | Notifications | A bell |
| `permissionAccessibility` | Accessibility | A figure with open arms on a disc |
| `permissionInputMonitoring` | Input Monitoring | A keyboard |
| `permissionFullDisk` | Full Disk Access | A drive in perspective |
| `permissionScreenRecording` | Screen Recording | A display with a record dot |
| `permissionApplicationAudio` | Application Audio | A speaker with two waves |
| `permissionCamera` | Camera | A camera body |
| `permissionBluetooth` | Bluetooth | Headphones, the device the permission exists for |
| `permissionAutomation` | Automation | A gear |

### Controls and shared objects

These live in `tools/icons-controls.mjs`.

#### Direction

| Icon | Concept |
| --- | --- |
| `chevronRight`, `chevronLeft`, `chevronUp`, `chevronDown` | A single turn of direction: disclosure and navigation |
| `chevronUpDown` | Two opposed turns: a value that opens a list |
| `arrowRight`, `arrowLeft`, `arrowUp`, `arrowDown` | A shaft with a head: go or move that way |
| `arrowUpRight`, `arrowDownRight` | A diagonal shaft into a corner: leaves this place |
| `arrowSwap`, `arrowSort` | Two opposed arrows: exchange, or reorder |
| `resizeHorizontal`, `resizeVertical` | One shaft, two heads: drag to resize |
| `arrowTurn` | A path turning a corner: a nested or following step |
| `undo`, `redo` | A path that doubles back |
| `enter` | A line that drops and returns: confirm |
| `signOut` | A panel with an arrow leaving it |

#### Turn arrows

| Icon | Concept |
| --- | --- |
| `refresh` | A loop ending in a corner wedge: run again |
| `sync` | Two half loops chasing each other |
| `history` | A loop running backward around clock hands |
| `rotate` | A loop around a small tile: turn this object |
| `seekForward`, `seekBack` | A loop around a play wedge: jump in time |

#### Editing and actions

| Icon | Concept |
| --- | --- |
| `close`, `closeFilled` | Two crossed bars: dismiss, alone or knocked out of a disc |
| `plus`, `addFilled` | A cross of equal arms: add |
| `minus`, `removeFilled` | One bar: remove |
| `check` | A tick: done or selected |
| `more` | Three dots: more actions |
| `menu` | Three equal bars: a menu |
| `filter` | Three shrinking bars: narrow a list |
| `adjust` | Two tracks with knobs: tune values |
| `search` | A loupe: find |
| `zoomIn`, `zoomOut` | A solid loupe with a mark knocked out |
| `trash` | A bin with a lid and two slots: discard |
| `edit` | A pencil on the diagonal, ferrule slit from its body |
| `copy` | One sheet lifted off another |
| `link` | Two hooks joined by a bar |
| `share` | An arrow leaving an open box |
| `saveTo` | An arrow entering an open box |
| `external` | A tile with a diagonal arrow knocked out: opens elsewhere |
| `expand`, `collapse` | Two corner wedges moving apart or together |
| `lineTool` | A single diagonal stroke: the line tool |
| `marker` | A marker over a highlighted stroke |
| `signature` | A pen stroke over its baseline |
| `scissors` | Crossed blades on two rings |

#### Layout and windows

| Icon | Concept |
| --- | --- |
| `sidebarLeft`, `sidebarRight` | A narrow lit panel beside the content |
| `grid`, `gridDense` | Four or nine tiles |
| `columns` | Three equal columns |
| `list` | Bulleted rows |
| `textLines`, `textAdd` | Lines of text, and the same with a plus |
| `window`, `windows` | A title bar over a body, alone or stacked |
| `menuBar` | A lit strip across the top of a screen |
| `layoutLeft`, `layoutRight`, `layoutTop`, `layoutBottom` | A screen with one half lit: where a window goes |
| `layoutCenter`, `layoutFull` | A window in the middle of the screen, or filling it |
| `selection` | A dashed marquee |
| `scan` | Capture brackets around a line |
| `frame` | An empty rectangle: the shape tool |
| `triangle` | A solid triangle: the sharpness control and the shape tool |

#### Status and selection

| Icon | Concept |
| --- | --- |
| `success` | A tick knocked out of a disc |
| `info` | An i knocked out of a disc |
| `alert` | A bang knocked out of a disc |
| `help` | An angular question mark knocked out of a disc |
| `warning` | A bang knocked out of a triangle |
| `error` | A cross knocked out of an octagon |
| `blocked` | A ring struck through |
| `placeholder` | A plain lozenge: shown for an unknown name |
| `ring`, `dot`, `radioOn` | An empty ring, a dot, and the two together |
| `checkbox`, `checkboxOn` | An empty box, and a tick knocked out of a full one |

#### Media

| Icon | Concept |
| --- | --- |
| `play`, `pause`, `stop` | The three transport shapes |
| `skipForward`, `skipBack` | A wedge against a bar: next or previous |
| `fastForward`, `rewind` | Two wedges: faster |
| `frameForward`, `frameBack` | A wedge past a faint bar: one frame |
| `repeatAll`, `repeatOne` | A closed loop of two arrows, the second with one mark |
| `shuffle` | Two crossing arrows, slit where they meet |
| `record` | A dot inside a faint ring |
| `eject` | A wedge above a bar |
| `speakerLow`, `speakerOff` | A speaker cone with one wave, or a cross |
| `waveform` | Five bars of uneven height: sound |
| `video`, `videoOff` | A camera body with a lens wedge, or struck through |
| `photo`, `photoStack` | A plate with a peak and a sun knocked out, alone or stacked |
| `captions` | Subtitle lines knocked out of a screen |
| `playlist` | Rows beside a note |
| `mic` | A capsule in a cradle |

#### Files and containers

| Icon | Concept |
| --- | --- |
| `folder`, `folderAdd`, `folderRemove` | A body under a faint tab, with a mark knocked out |
| `doc`, `docText`, `docAdd` | A page with a folded corner |
| `archive` | A box under a faint lid |
| `box` | An isometric carton on a 2 to 1 slope, top face faint |
| `tray` | Papers settling into a tray |
| `layers` | A lit sheet over faint sheets |
| `books` | Spines on a shelf, one leaning |
| `appTile`, `appDownload` | An app tile, alone or with a down arrow |

#### People and messages

| Icon | Concept |
| --- | --- |
| `person`, `personAdd` | A head and shoulders, with a plus |
| `message`, `messages` | A speech bubble, one or two |
| `send` | A paper dart with a fold |
| `mail` | An envelope with its flap knocked out |
| `hand` | An open palm: stop |

#### Time and data

| Icon | Concept |
| --- | --- |
| `clock` | Hands knocked out of a disc |
| `timer` | A stopwatch with its crown |
| `hourglass` | Faint sand above, lit sand below |
| `calculator` | Display and keys knocked out of a body |
| `hash` | A number sign |
| `table` | A lit header over faint cells |
| `code` | Angle brackets around a faint slash |
| `chartBar` | Three rising solid bars |
| `chartLine` | A rising line on faint axes |
| `pulse` | A heartbeat trace |
| `timeline` | A playhead across a faint clip |

#### Connectivity and system

| Icon | Concept |
| --- | --- |
| `globe` | Meridians and latitudes knocked out of a disc |
| `nodes` | Three nodes joined by faint links |
| `wifi`, `wifiOff` | Arcs above a dot, or muted and struck through |
| `signal` | A dot broadcasting both ways |
| `cloud`, `cloudDownload` | A solid cloud, with an arrow knocked out |
| `lock`, `unlock` | A body with a keyhole under a faint shackle |
| `shield` | A tick knocked out of a shield |
| `eyeOff` | The awake eye, struck through |
| `power` | A broken ring with a bar: on and off |
| `bolt` | A lightning bolt: power and quick actions |
| `batteryEmpty`, `batteryLow`, `batteryHalf`, `batteryHigh`, `batteryFull` | A faint cell filling up |
| `batteryCharging` | A full cell with a bolt knocked out |
| `sun`, `moon` | Light and dark |
| `thermometer` | A bulb with a faint tube |
| `fan` | Three blades around a hub |
| `cpu` | A chip with pins |
| `memory` | A memory stick with its contacts |
| `display`, `displays` | A screen on a faint stand, one or two |
| `laptop` | A screen on a faint base |
| `phone` | A slab with a home bar |
| `cursor` | A pointer |

#### Objects

| Icon | Concept |
| --- | --- |
| `home` | A house with a door |
| `map` | Three folded panels, the middle lit |
| `location` | A map pin |
| `flag` | A pennant on a pole |
| `pin` | A thumbtack |
| `bookmark` | A ribbon with a notch |
| `tag` | A swing tag on the diagonal |
| `heart` | A heart: liked and favorite |
| `flame` | A flame: a streak |
| `building` | A tower beside a faint low block |
| `briefcase` | A case with a faint handle |
| `airplane` | A plane from above |
| `drop` | A drop: saturation |
| `palette` | A palette with a thumb bite |
| `hammer` | A hammer on the diagonal: build |
| `wrench` | An open wrench: repair and tools |
| `bandage` | A bandage on the diagonal: fix |
| `puzzle` | A piece with two tabs: an add-on |
| `coffee` | A cup on a faint saucer |
| `filters` | Three overlapping discs |
| `contrast` | A disc split into lit and faint halves |

#### Text

| Icon | Concept |
| --- | --- |
| `text` | A capital A |
| `textLarger`, `textSmaller` | A capital A with a faint wedge up or down |
| `underline` | A U over a bar |
| `strikethrough` | A faint S crossed by a lit bar |
| `textCursor` | An I-beam |

### Aliases

`aliases.json` gives an icon a second plain name, such as `gear` for
`permissionAutomation`, `camera` for `permissionCamera` and `crop` for `studio`.

## Every icon lives here

Every icon in the app comes from this package, including control glyphs such as
chevrons, close, plus, trash, refresh and check. Nothing uses SF Symbols, so draw
a missing icon here instead of reaching for a system symbol. See
`skills/edith-icons/SKILL.md` for the rule, its exceptions and the review process.

`symbol-map.json` maps each SF Symbol name found in the codebase to its Edith
icon, for the migration codemod. It holds four lists:

- `symbols`: symbol name to icon name.
- `muted`: symbols that mean an off state, so use `tone: .muted`.
- `overrides`: per file exceptions, where a symbol had a local meaning.
- `notSymbols`: strings that match a symbol name but are data, not icons.

A manifest's top level `symbolName` uses the extension id instead of this map.

## Using the package

Pick by where the icon sits. These four cover every call site.

| Where | Use |
| --- | --- |
| Next to text, any view | `EdithIconView(.plus)` |
| A fixed slot such as a hero or card | `EdithIconView(.herdr, size: 40)` |
| A title and an icon, including menus | `Label("Rename", edith: .edit)` or `Button("Rename", edith: .edit) {}` |
| Anything that needs a real image | `EdithIcon.plus.image()` or `.nsImage()` |

```swift
import EdithIcons

EdithIconView(.check).font(.caption).foregroundStyle(.tint)
EdithIconView(.herdr, size: 40).foregroundStyle(DashSkin.accent(dark))
EdithIconView(.heart, tone: saved ? .duotone : .muted)

Menu("More") {
    Button("Rename", edith: .edit) { rename() }
    Button("Delete", edith: .trash, role: .destructive) { delete() }
}

Text("\(Text(edith: .warning).foregroundColor(.orange)) \(title)")

statusItem.button?.image = EdithIcon.brand.nsImage(size: 16, tone: .monochrome)

EdithIconView(EdithIcon(name: step.symbolName))
```

### Sizing from text

With no `size`, `EdithIconView` sizes itself from the surrounding font, the same
way a symbol does. A trailing `.font(...)` works, and `.imageScale` is honored.

It measures a hidden `Text` inside a custom `Layout`, so it needs no font API and
works on macOS 14. `Font.resolve(in:)` is not used: in the current SDK it needs
macOS 26. The line height then snaps to the nearest of 12, 16, 20, 24, 32 or 40
points, so a glyph stays on whole pixels at any window zoom instead of blurring.
The layout forwards the text baseline, so `.firstTextBaseline` stacks line up.

The limits:

- The size moves in steps while text scales smoothly, so a glyph can be up to
  about 15% off its ideal size between steps.
- Font weight is not followed. Stems stay 2 units in a semibold line.
- The view is not an `Image`, so a native menu drops it. Use `Label(_, edith:)`
  or `.image()` there.
- `.symbolEffect` does nothing, because these are not symbols.

`Label(_, edith:)` and `Button(_, edith:)` work everywhere, because their icon is
a real `Image`. A hidden `Text` in its background measures the line, and native
menus ignore that background. The tests check this through `NSHostingMenu`.

### Images

`.nsImage(size:tone:)` returns a template image with 1x and 2x bitmaps, so the two
tones survive as alpha. `.image(size:tone:)` wraps it for SwiftUI. In a menu or
status item, the system tints and dims it. These are fixed size, 16pt by default.

### Names

`EdithIcon(name:)` takes an icon name or an alias from `aliases.json` and returns
`.placeholder` for anything unknown, so a bad manifest shows a lozenge instead of
crashing. `EdithIcon.named(_:)` returns nil instead, `EdithIcon.isValid(name:)`
checks a name, and `EdithIcon.names` lists them all. Scripts read `names.json`,
which holds the same data, and is regenerated and checked with the Swift file.

Aliases are also constants, so `.gear` and `.permissionAutomation` are the same
icon. Add an alias when an icon has a second plain meaning. Do not redraw it.

### Performance

Parsed paths are cached once per icon, layer and cut behind a lock. Rendered
images sit in an `NSCache` keyed by icon, size and tone. Both are safe from any
thread, and the tests cover 1,000 rows and concurrent access.

### Inside the app

`EdithExtensionUI` re-exports this package, and the shared extension kit carries
it. Inside the app and extensions, prefer `PageIcon` or `PageGuideBadge` for fixed
slots: they follow `UIScale`, keep the frame on whole points so a zoomed icon stays
centered and pick the cut from the size that lands on screen.
`PageGuideBadge.flushLeading()` lines the ink up with the left edge of a text
column.

The package has no resources and no bundle lookups, so it works in any process,
including remote extension processes. Icons are hidden from accessibility because
labels belong to the surrounding control.

## Adding or changing an icon

Draw in `tools/`, which computes the slits and booleans so they stay uniform:

- `tools/icons-app.mjs` holds the brand, extensions, suites and permissions.
- `tools/icons-controls.mjs` holds controls and shared objects.
- `tools/geo.mjs` is the drawing kit, and `tools/build.mjs` writes `svg/`.

Each icon needs both cuts. Run this from `Packages/EdithIcons`. Run `bun install`
in `tools/` once first.

```sh
bun tools/build.mjs
bun scripts/generate.ts
bun scripts/generate.ts --check
bun tools/audit.mjs
swift test
bun tools/sheets.mjs
```

`tools/audit.mjs` fails on any axis edge that is off the grid. `tools/sheets.mjs`
renders every review sheet through the real views into `local/icons/`: the full
set, zoomed 16 and 20 at 1x and 2x, a size ladder, theme tints, every control
beside 13pt text, a font ladder, native controls and mockups. It also writes
`confusable-16pt.txt`, the most similar pairs at 16pt.

While drawing, `bun tools/sheets.mjs plus,trash,search` renders only those icons,
zoomed at 1x and 2x in both themes, to `local/icons/focus.png`.

The SVG files in `svg/` are the output of that step and the contract for the
package: one path `id="primary"`, optionally one `id="secondary"`, with
`fill-rule="evenodd"` and absolute `M L H V Q C Z` commands. Do not edit them by
hand, because `tools/build.mjs` rewrites them.

`EdithIcon.generated.swift` and `names.json` are written from the SVG files and
`aliases.json`, and must not be edited by hand. `--check` fails if either has
drifted. The tests also compare every case against its SVG, so drift fails without
bun installed.
