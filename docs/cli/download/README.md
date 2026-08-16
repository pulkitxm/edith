# `ed download`

`ed download` is the queue Edith feeds to yt-dlp: YouTube links waiting to
become files in your music folder. Reach for it when you want to queue
something from a script or a terminal rather than from the Download sheet, or
when you want to know what the queue is holding without opening a window.

The queue is a single file, `downloads.json` under
`~/Library/Application Support/Edith/data`, so listing it, adding to it,
retrying, removing and clearing are plain file writes that work whether or not
Edith is running. Running the downloads is not something `ed` does: that belongs
to the app, so anything you add while Edith is closed waits in the queue and
starts when you next open it, and `ed` says so on stderr rather than failing.
The one binary `ed` runs itself is the yt-dlp that `ed download tool` reports on.

`ed downloads` and `ed dl` are the same group under different names, and
`ed download` with nothing after it is `ed download ls`.

## At a glance

| Command | What it does |
| --- | --- |
| `ed download` | Runs `ed download ls`, which is the default subcommand. |
| `ed download ls` | Lists the queue, newest first, as a numbered table. |
| `ed download add` | Queues one or more YouTube URLs as audio or video. |
| `ed download retry` | Puts a failed or interrupted entry back in the queue. |
| `ed download rm` | Takes one entry out of the queue. |
| `ed download clear` | Forgets what has finished, or the whole queue with `--everything`. |
| `ed download tool` | Reports the yt-dlp being used, or runs its self-update. |
| `ed download cancel` | Stops what is downloading and empties everything that has not finished. |

`ed download list` is the same command as `ed download ls`.

## Commands

- [`ed download ls`](./ls.md)
- [`ed download add`](./add.md)
- [`ed download retry`](./retry.md)
- [`ed download rm`](./rm.md)
- [`ed download clear`](./clear.md)
- [`ed download tool`](./tool.md)
- [`ed download cancel`](./cancel.md)

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The listing printed, or the queue was changed. Also an empty queue for `ls`, `clear` and `cancel`, `retry --all` with nothing to retry, `tool --json` with yt-dlp missing, and `--help` on the group or any verb. |
| 1 | `add` found no YouTube URL in its arguments, `retry` was given neither a number nor `--all`, `retry <n>` named an entry that is not `failed` or `interrupted`, or the queue file could not be written. |
| 2 | `ls --limit` was negative (`--limit cannot be negative`), or the command line was wrong in ArgumentParser's own terms: an unknown flag, `add` with no URL, `rm` with no number, or a number that is not an integer. |
| 3 | `add --kind` named something other than `audio` or `video`, or `rm <n>` and `retry <n>` named a position outside the queue (`there is no download 9`, with the queue size as the hint). |
| 4 | `rm` or `retry <n>` was run against an empty queue (`the download queue is empty`), or `tool` could not find yt-dlp: an error on the human path, and under `--json` too when `--update` was passed. |

Nothing here exits 4 for the usual reason. No verb in this group asks Edith to
answer a question, so none of them fails because the app is closed.

## Notes and gotchas

- The queue lives at `downloads.json` in Edith's data directory,
  `~/Library/Application Support/Edith/data` normally, or
  `<repoPath>/apps/dashboard/data` when the `repoPath` setting points at a
  checkout. Both `ed` and the app read and write that one file, and every
  mutation here rewrites it whole and atomically.
- Order is by queued time, newest first, applied on every read. `ed` does no
  sorting of its own beyond that, so the numbering is stable between two reads
  only if nothing was added or removed in between. URLs queued by one `add`
  share a single timestamp, so their order relative to each other is not
  defined.
- Every mutating verb posts `com.pulkit.edith.downloadQueueChanged`, which is
  a fire-and-forget distributed notification. A running Edith reloads the queue
  from disk when it hears it and starts on the next queued item if it is idle,
  so `ed download add` on an open Edith begins downloading within moments. If
  nothing is listening, the file is still correct and the work happens the next
  time the app looks.
- yt-dlp runs inside the main Edith window, not the menu bar helper, and the
  "Edith is not running" note checks for the helper. The two normally start
  together, but the note is a hint rather than a guarantee: the queue drains
  when the app's downloader is alive, which in practice is once the Music page
  or Download sheet has been opened in that session. `cancel` is the one verb
  that looks for the main app instead, because the main app is what holds the
  yt-dlp there is to stop.
- `ed download add --kind` always defaults to `audio`. It does not read
  `musicDownloadKind`, the setting the sheet's Audio/Video picker writes, so
  choosing Video in the UI does not change what `ed` queues. Pass `--kind
  video`, or read the setting yourself with `ed config get musicDownloadKind`.
- `--prefix` is prepended raw to the title with no separator, so pass the
  underscore or dash you want: `--prefix roadtrip_` gives `roadtrip_Title.m4a`,
  `--prefix roadtrip` gives `roadtripTitle.m4a`. It is recorded in the entry's
  output template at queue time, so changing your music folder afterwards does
  not move where that entry will land.
- Audio is extracted to `m4a` and video is merged to `mp4`, with the thumbnail
  embedded either way. Intermediate `webm`, `mkv`, `opus`, `ogg`, `part`,
  `ytdl` and `temp` files next to the finished one are removed when a download
  completes.
- Only YouTube links are accepted, because that is what the parser filters to.
  Any other host is discarded silently, which means `ed download add
  https://vimeo.com/1234` and `ed download add hello` both fail the same way,
  with `none of that looked like a URL`.
- `detail` for a failed entry is the entire yt-dlp log for that attempt, not a
  one-line summary. It can be several kilobytes and contain newlines. The table
  has no column for it, so `--json` is the only way to read it.
- Removing an entry never deletes a downloaded file, and clearing the queue
  never touches your music folder. Use `ed music rm` for the files themselves.
- Nothing in this group has a `--yes` guard. `rm`, `clear`, `clear
  --everything` and `cancel` all act immediately, unlike `ed music rm` or
  `ed cleaner clean`.
- `--help` works on the group and on every verb, prints on stdout and exits 0.
- Completion knows the verbs and the flags: `ed dl <TAB>` offers all seven,
  and `ed download ls --<TAB>` offers `--active`, `--limit` and `--json`. It
  stops there. The number `rm` and `retry` take completes to nothing, and so
  does `--kind`, so `audio` and `video` have to be typed out.

## Where to go next

- [`ed music`](../music/README.md), the library these downloads land in, and the verbs
  for renaming, moving and playing what arrives.
- [`ed tools`](../tools/README.md), which is where yt-dlp gets installed in the first
  place.
- [`ed config`](../config/README.md) for `musicFolderPath` and `musicDownloadKind`.
- [All `ed` commands](../README.md).
