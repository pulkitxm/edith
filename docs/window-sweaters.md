# Window Sweaters

Window Sweaters knits a border around every window, in a colour chosen for the app
that owns it. Claude gets its terracotta, Finder its blue, Spotify its green. Apps
without a colourway of their own take a colour derived from their name, so it stays
the same every time you open them.

The borders are drawn by Edith's menu bar companion, not by a separate app.

## Enable it

Turn on Window Sweaters in Settings, or run `ed extensions enable windowSweaters`.
Borders appear on the windows already open, and on new ones as they arrive.

Accessibility is optional. Granting it lets Edith ask each app which of its windows
is focused, which is sharper in apps with panels and inspectors; without it Edith
asks the window server, which is right nearly all of the time.

## The knitting

**Sweaters on** takes the knitting off without removing the extension. Your
colourways, widths and patterns are kept for when you turn it back on.

**Pattern** chooses what is knitted:

| Pattern | What it does |
| --- | --- |
| By App | Each app gets the pattern from its own colourway, or plain knitting if it has none |
| Plain | One stitch everywhere, in each window's colour |
| A named pattern | Every window knits the same pattern, in its own colour |

**Stitch** applies to plain knitting: stockinette, rib or garter. Colourwork always
knits stockinette, so this control only appears for Plain.

**Spare wool** is the basket that apps without a curated sweater draw from. The
colour is picked from the app's name, so it is stable across launches and neighbouring
windows rarely collide.

**Border width** is how wide a band is knitted, from 2 to 60 points. **Stitch size**
is how many stitch rows fit across that band; fewer rows knit chunkier. A pattern
needs enough rows to read, so the slider will not go below what the current pattern
requires.

**Sits** decides whether the knitting tucks behind the window edge or lies over it.
Behind is the default and leaves the window's own content untouched.

**Unfocused** darkens the sweater on every window except the one you are working in.
At zero, every window looks the same.

**Repeat starts** is where each side's pattern repeat is anchored. At the corner the
pattern holds still while you resize a window; centred composes each side, but slides
as the window changes size.

**Never knit** is a comma-separated list of app names that stay bare.

The settings pane previews four sample sweaters as you change any of this, drawn by
the same renderer that paints the real windows.

## What it does not do

Borders hide while a window is being resized and return when you let go. They also
hide during the Dock's minimize animation, because a rectangular border cannot follow
that shape.

The colours are chosen by hand, not read from app icons.

## From the command line

```sh
ed extensions enable windowSweaters
ed config ls --group sweaters --json
ed config set windowSweatersActive false
ed config set windowSweatersPattern zigzag
ed config set windowSweatersBorderWidth 18
ed extensions doctor windowSweaters --json
```

Every control in the pane is an ordinary setting in the `sweaters` group, so
`ed config ls --group sweaters` is the full list.

## How it works

Each tracked window gets its own window-server overlay, shaped into a ring around the
window and ordered against it. Window creation, movement, resize, stacking, hide and
Space changes arrive as window-server notifications; a twentieth-of-a-second snapshot
pass repairs anything a notification missed, retires windows that have gone away, and
rebuilds an overlay the server has stranded.

The knitting itself is a seamless tile: one stitch repeat is rendered once per
band width, colour and pattern, lit from a height field derived from the yarn, then
tiled into four mitred sides. Stroking the stitches directly would cost well over a
second for a full-screen window; tiling makes each redraw a single draw call.

This uses private window-server interfaces, so a macOS update can change how it
behaves.

## Credits

Ported from [Window Sweaters](https://github.com/saragordic/window-sweaters) by Sara
Gordic, itself derived from [JankyBorders](https://github.com/FelixKratz/JankyBorders)
by Felix Kratz. Both are GPL-3.0, as is Edith. The renderer, the colourwork charts and
the curated app colourways are Sara Gordic's design.

Application names in the collection belong to their respective owners and describe
colourway inspiration only. No affiliation or endorsement is implied.
