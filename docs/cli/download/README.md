# `ed download`

Download videos, images, carousels and social posts through Edith's persistent
background queue. Enable **Downloads** in Extensions, then open **Media >
Downloads**. Music does not need to be enabled.

Paste one or more complete web links, choose a format and destination, and select
**Add to queue**. Progress, cancellation, retry, logs, opening files and revealing
them in Finder are available in the same page. The background agent keeps working
when the window closes. Interrupted jobs can be retried after an agent restart.

## Formats and providers

| Format | Provider | Result |
| --- | --- | --- |
| Entire post (`post`) | gallery-dl, then yt-dlp if no files were found | Photos and videos from a post or carousel, in their source formats |
| Images (`images`) | gallery-dl | Image files only, including direct image URLs |
| Video (`video`) | yt-dlp and FFmpeg | Best available video and audio, merged to MP4 when merging is needed |
| Audio (`audio`) | yt-dlp and FFmpeg | Audio extracted to M4A |

Install yt-dlp, FFmpeg and Deno from the extension's setup controls. Install the
optional gallery-dl tool for photos and entire posts:

```sh
ed tools install yt-dlp
ed tools install ffmpeg
ed tools install deno
ed tools install gallery-dl
ed extensions enable downloads
```

The providers cover YouTube, Instagram, TikTok, X/Twitter, Facebook, Reddit,
Pinterest, Flickr, Snapchat, LinkedIn, Vimeo, Twitch and many other sites.
Coverage varies by media type, installed extractor version, region and whether
the post requires login. Accepting a URL does not guarantee the platform will
serve its media. Unsupported links, removed posts and authentication errors are
reported in the queue. There is no paid API or proxy service to configure.

- [yt-dlp supported sites](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md)
- [gallery-dl supported sites](https://github.com/mikf/gallery-dl/blob/master/docs/supportedsites.md)

## Destinations and login

Audio defaults to the configured Music folder. Videos, images and entire posts
default to `~/Downloads/Edith`. Choose a folder in the UI or pass `--directory`.
Each gallery gets its own queue-ID subfolder so different posts do not collide.
Video and audio filenames include the source ID. Existing files are not
overwritten, and removing queue entries never deletes downloaded files.

For login-required posts, explicitly choose Safari, Chrome, Firefox, Brave or
Edge under **Login cookies**, or pass `--browser`. The local download tool reads
that browser's cookies; Edith stores only the browser choice in the queue.
Public downloads do not read browser cookies. Browser access can require macOS
permission, and authenticated or protected content may still be unavailable.

Each request accepts at most 100 URLs and the queue holds at most 128 active
items. A link downloads at most 100 media items. Whole-channel and large-playlist
archiving are outside this workflow. User-level downloader configuration files
are ignored so their output paths and postprocessing commands cannot alter a job.

## Commands

| Command | What it does |
| --- | --- |
| [`ed download ls`](./ls.md) | Lists the queue, newest first; `--active` filters unfinished jobs. |
| [`ed download status`](./status.md) | Summarizes every lifecycle state. |
| [`ed download add`](./add.md) | Queues web links with a format, destination and optional browser. |
| [`ed download retry <n>`](./retry.md) | Retries a failed or interrupted job; `--all` retries all. |
| [`ed download cancel [n]`](./cancel.md) | Cancels one job, or all active jobs, while keeping history. |
| [`ed download rm <n> --yes`](./rm.md) | Removes a queue record. |
| [`ed download clear --yes`](./clear.md) | Clears finished history. |
| [`ed download open <n>`](./open.md) | Opens completed files. |
| [`ed download reveal <n>`](./reveal.md) | Reveals completed files in Finder. |
| [`ed download tool`](./tool.md) | Reports yt-dlp; `--update` requests its self-update. |

All commands accept `--json`. `ed downloads` and `ed dl` are aliases;
`ed download` defaults to `ls`. Queue mutations require the background agent;
saved history can be read offline. Updates for Homebrew-managed tools should use
Homebrew rather than the tool's standalone self-updater.

```sh
ed download add 'https://www.instagram.com/p/example/' --kind post --browser firefox
ed download add 'https://example.com/photo.png' --kind images --directory ~/Pictures/Saved
ed download add 'https://www.youtube.com/watch?v=example' --kind video
ed download ls --json
```

## Related commands

- [`ed download add`](./add.md)
- [`ed tools`](../tools/README.md)
- [`ed music`](../music/README.md)
- [All `ed` commands](../README.md)
