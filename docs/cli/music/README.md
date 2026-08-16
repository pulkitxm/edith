# `ed music`

`ed music` is two things behind one noun. It is transport control for whichever
music player is actually playing on this Mac, Spotify, Apple Music or Edith's
own library player, and it is the file manager for Edith's library folder:
listing, moving, renaming and trashing tracks. Reach for it to see what is
playing without switching apps, to drive playback from a script or a hotkey, and
to keep the library tidy from a shell.

The group answers to `ed music`, `ed nowplaying` and `ed np`. A bare `ed music`
runs `ed music status`, and flags meant for `status` may be given straight to
it, so `ed np --json` and `ed music --player spotify` both work.

## At a glance

| Command | What it does |
| --- | --- |
| `ed music status` | What is playing right now, on whichever player. The default subcommand. |
| `ed music play` | Resume playback on the active player. |
| `ed music pause` | Pause the active player. |
| `ed music stop` | Stop the active player and reset its position to zero. |
| `ed music toggle` | Toggle play and pause. Aliased `playpause`. |
| `ed music next` | Skip to the next track. |
| `ed music previous` | Go back to the previous track. Aliased `prev`. |
| `ed music volume` | Set the active player's volume, from 0 to 1. |
| `ed music players` | Every player Edith can see, and which one is active. |
| `ed music ls` | List the library, a folder at a time. Aliased `list`. |
| `ed music mkdir` | Make a folder in the library. Aliased `newfolder`. |
| `ed music mv` | Move a track into a folder. Aliased `move`. |
| `ed music rename` | Rename a track or a folder. |
| `ed music rm` | Move a track or folder to the Trash. |
| `ed music start` | Play one track out of the library, or a whole folder. |
| `ed music seek` | Jump to a point in the current track, from 0 to 1. |
| `ed music shuffle` | Turn shuffle on or off, or report it. |
| `ed music repeat` | Turn repeat on or off, or report it. Aliased `loop`. |
| `ed music rescan` | Read the music folder again after changing it outside Edith. |

## Players

There are exactly three players, and they are named `builtin`, `spotify` and
`apple`. `builtin` is Edith's own library player, which lives in the menu bar
app and shows up as `Edith` in human output.

Each is reached a different way, which is why some commands need Edith running
and others do not.

- `spotify` and `apple` are driven straight over AppleScript: `ed` pipes a
  script into `/usr/bin/osascript` and waits up to 6 seconds. Edith does not
  have to be running for this, and never sees the command.
- `builtin` is driven over the app's own notification bus. Reading its state
  posts `requestMusicState` and waits up to 2 seconds for a `musicState` reply;
  changing it posts `musicCommand`. It counts as reachable only when the menu
  bar app is running and the `tabMusicEnabled` extension is on.

Every AppleScript starts with a `System Events` check for the player's process,
so a player that is not already open is reported as not running rather than
launched. Nothing in this group ever opens Spotify or Apple Music for you.

**Choosing the active player.** With no `--player`, `ed` takes a snapshot of all
three and scores each one: not running scores 0, running scores 1, plus 2 if it
has a track loaded and plus 4 if it is actually playing. The highest score wins.
Ties are broken first toward the player you last drove from the command line,
which `ed` remembers in the `cliActivePlayer` shared default after every
successful transport command, and otherwise toward the earlier player in the
fixed order `builtin`, `spotify`, `apple`. When the best score is still 0,
nothing is running and the command exits 4:

```
$ ed music pause
error: no music player is running
hint: open Spotify or Apple Music, or turn on Edith's Music extension
```

**Forcing one.** `--player <name>` skips the scoring, probes only that player,
and fails if it is not running. The spellings are generous and
case-insensitive:

| Player | Accepted spellings |
| --- | --- |
| `builtin` | `builtin`, `built-in`, `edith`, `internal` |
| `spotify` | `spotify` |
| `apple` | `apple`, `applemusic`, `apple-music`, `music`, `itunes` |

Anything else exits 3 with `no player named <text>` and the three canonical
names as the hint. A named player that is closed exits 4 and says which:

```
$ ed music next --player spotify
error: Spotify is not running
hint: open Spotify, then retry
```

`--player` exists on eight commands only: `status`, `play`, `pause`, `stop`,
`toggle`, `next`, `previous` and `volume`. `players` always looks at all three.
`start`, `seek`, `shuffle` and `repeat` always mean Edith's own player, because
they drive the library queue rather than a generic transport.

## Commands

- [`ed music status`](./status.md)
- [`ed music play`](./play.md)
- [`ed music pause`](./pause.md)
- [`ed music stop`](./stop.md)
- [`ed music toggle`](./toggle.md)
- [`ed music next`](./next.md)
- [`ed music previous`](./previous.md)
- [`ed music volume`](./volume.md)
- [`ed music players`](./players.md)
- [`ed music ls`](./ls.md)
- [`ed music mkdir`](./mkdir.md)
- [`ed music mv`](./mv.md)
- [`ed music rename`](./rename.md)
- [`ed music rm`](./rm.md)
- [`ed music start`](./start.md)
- [`ed music seek`](./seek.md)
- [`ed music shuffle`](./shuffle.md)
- [`ed music repeat`](./repeat.md)
- [`ed music rescan`](./rescan.md)

## Exit codes

| Code | What produced it |
| --- | --- |
| 0 | The command did what it says. Also the dry run of `ed music rm` without `--yes`, and `ed music status --json` when no player is running. |
| 1 | A library operation the filesystem refused: a blank name, a destination that already exists, a Trash that failed, or trashing the library root. Also `shuffle` or `repeat` given a word that is neither on nor off. |
| 2 | `volume` or `seek` outside 0 to 1, a level or position that is not a number, an unknown flag, a missing argument. |
| 3 | An unknown `--player` spelling, a track query that matches nothing, a track query that matches more than one track, a folder that does not exist. |
| 4 | No player is running, or the forced player is not; no music folder is set; `start` or `seek` with the menu bar app closed; Edith's own player unreachable because the app is closed, the Music extension is off, or it did not answer in time; osascript refused, timed out, or macOS has not granted this command line Automation access. |

## Notes and gotchas

`ed music status` with no `--player` probes all three players in the order
`builtin`, `spotify`, `apple`, one after another. The built-in probe is skipped
instantly when the app is closed or the extension is off, and the AppleScript
probes return quickly when the player is not open, so the worst case is a slow
answer rather than a hang: 2 seconds for the built-in reply and 6 for each
script. `--player` cuts it to a single probe.

Automation failures are swallowed on the way in. Reading a player's state drops
any osascript error and treats the player as not running, and every transport
command probes before it sends, so with Automation denied `ed music status`
exits 4 with `no music player is running` and `ed music pause --player spotify`
exits 4 with `Spotify is not running` rather than naming the real cause. The
osascript error is reported verbatim only when the send itself fails after a
probe that worked: then `ed` exits 4 with
`macOS has not granted this command line Automation access` and points at
System Settings. That grant belongs to your terminal, not to Edith, and is
separate from anything `ed permissions` reports.

The last player you successfully drove is remembered in the `cliActivePlayer`
shared default and used only to break a tie between two players with the same
score. `status` and `players` read it; they never write it.

Every library command needs `musicFolderPath` to be set and exits 4 with
`no music folder is set` when it is not, even though none of them need the app.
Set it with `ed config set musicFolderPath ~/Music` or from the Music page. One
subtlety follows from where the app resolves that path: a folder on `/Volumes`
that the app has not confirmed is dropped in favour of `<repoPath>/local/music`
when `repoPath` is set and `~/Library/Application Support/Edith/music`
otherwise, so the checks pass but `ed music ls` lists the fallback folder rather
than the external drive.

Track queries are matched against the relative path and the derived title, never
against file tags, and the first exact relative-path hit wins before any
substring matching happens. That makes `ed music mv Chill/beta-tune.mp3 Focus`
unambiguous even when `beta` matches several files.

Favourites follow a rename or a move, including a folder rename, because the
stored relative paths are repointed as part of the move. They do not follow a
trash: `ed music rm` leaves the old path sitting in `musicFavourites`.

`ed music rename --folder "" <name>` renames the library folder itself, because
the empty path resolves to the library root and only `rm` guards against it.
That leaves `musicFolderPath` pointing at a folder that no longer exists.

`shuffle` and `repeat` write to the standard defaults domain, matching the
`.standard` scope those two settings declare in the config catalog, so
`ed config get musicShuffling` and `ed music shuffle` always agree.

Library mutations announce themselves on the app's notification bus:
`mkdir`, `mv`, `rename`, `rm` and `rescan` all post `musicFolderChanged`, and
`mv` and `rename` additionally post a `renamed` command so a running player
follows the file. None of them wait for an acknowledgement.

Every command in this group emits exactly one JSON document per invocation, with
object keys sorted, and prints diagnostics on stderr only. There is no streaming
mode here, so `--json` output is always pretty-printed.

## Where to go next

- [`ed config`](../config/README.md) sets `musicFolderPath`, `musicVolume`,
  `musicShuffling`, `musicLooping` and the rest of the `music` group.
- [`ed extensions`](../extensions/README.md) turns the `music` extension on, which is
  what makes the built-in player reachable at all.
- [`ed permissions`](../permissions/README.md) covers the grants that belong to the
  Edith bundle, which are not the Automation grant this group needs.
- [`ed download`](../download/README.md) is how tracks get into the library in the first
  place.
- [All command groups](../README.md)
