# `ed studio run`

[Back to `ed studio`](./README.md)

Runs a Studio tool on files and prints the path of every result. Tools that
take one file at a time run on each file you pass; tools that combine files,
such as `pdf.merge`, use them in the order given. When one file of a batch
fails, the others still finish and the failure is reported on stderr.

Usage:

```
ed studio run <tool> <files...> [--set <key=value>...] [--output-dir <folder>] [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<tool>` | a tool id from `ed studio tools` | required | The tool to run. Editor tools such as `pdf.edit` only open in the app. |
| `<files...>` | paths | depends on the tool | The input files. Web tools take none and use `--set url=…`. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--set` | `key=value`, repeatable | tool defaults | One setting. Keys and allowed values come from `ed studio info`. Percentages accept `40%` or `0.4`, ranges accept `0:05-0:12`, and toggles accept `true` or `false`. |
| `--output-dir` | folder | next to each input | Save every result in this folder instead. |
| `--json` | flag | off | Emits `tool`, `outputs` (path, kind, bytes), `inputBytes`, `outputBytes`, `notes` and `failures`. |

Exit codes follow [the conventions](../conventions.md): 2 for a bad setting or a
file the tool cannot take, 3 for a missing file or tool, 4 when an engine such
as FFmpeg is missing.

Examples:

```
ed studio run pdf.merge intro.pdf body.pdf appendix.pdf
ed studio run pdf.compress scan.pdf --set level=extreme
ed studio run image.convert *.heic --set format=jpg --output-dir ~/Desktop/converted
ed studio run video.to-gif demo.mov --set range=0:02-0:06 --set width=480
ed studio run pdf.redact contract.pdf --set "terms=Jane Doe" --set phones=true
ed studio run pdf.scan receipt-1.jpg receipt-2.jpg --set look=mono
```

## Tools

Every tool id `ed studio run` accepts, in the order `ed studio tools` lists them.

| Tool | Name | What it does |
| --- | --- | --- |
| `pdf.merge` | Merge PDF | Combine PDFs and images into one PDF in the order you want. |
| `pdf.split` | Split PDF | Separate pages into several PDFs, by ranges, a fixed size or every page. |
| `pdf.remove-pages` | Remove pages | Delete the pages you do not need from a PDF. |
| `pdf.reorder` | Reorder pages | Reverse, interleave scanned sides or put pages in a custom order. |
| `pdf.rotate` | Rotate PDF | Turn all pages or just some of them. Works on many PDFs at once. |
| `pdf.organize` | Organize PDF | Sort, rotate, delete, duplicate and insert pages visually. |
| `pdf.n-up` | Pages per sheet | Print-ready layouts with 2, 4, 6, 9 or 16 pages on each sheet. |
| `pdf.page-size` | Change page size | Fit every page onto A4, Letter or another paper size. |
| `pdf.crop` | Crop PDF | Trim white margins automatically or cut fixed margins from pages. |
| `pdf.crop-area` | Crop area | Draw the area to keep on a page and apply it to one page or the whole PDF. |
| `pdf.compress` | Compress PDF | Reduce file size while keeping the PDF sharp enough to read and print. |
| `pdf.grayscale` | Grayscale PDF | Convert every page to shades of gray for cheaper printing. Text stays sharp. |
| `pdf.ocr` | OCR PDF | Make scanned PDFs searchable and selectable with on-device text recognition. |
| `pdf.repair` | Repair PDF | Rebuild a damaged PDF and recover as much of it as possible. |
| `pdf.flatten` | Flatten PDF | Burn comments, drawings and form fields into the page so they cannot be edited. |
| `pdf.decompress` | Decompress PDF | Expand compressed streams so the PDF can be inspected or edited by hand. |
| `pdf.linearize` | Optimize for web | Linearize a PDF so browsers show the first page before the rest downloads. |
| `pdf.to-images` | PDF to JPG | Turn each page into an image, or pull out every image inside the PDF. |
| `pdf.from-images` | JPG to PDF | Make a PDF from photos and scans with the page size and margins you want. |
| `pdf.to-word` | PDF to Word | Turn a PDF into an editable DOCX with headings, paragraphs and images. |
| `pdf.to-powerpoint` | PDF to PowerPoint | Turn each PDF page into a PowerPoint slide that looks exactly the same. |
| `pdf.to-excel` | PDF to Excel | Pull tables and aligned text out of a PDF into an XLSX spreadsheet. |
| `pdf.to-text` | PDF to text | Save all the text in a PDF as a plain text file. |
| `pdf.to-markdown` | PDF to Markdown | Turn PDFs into clean Markdown with headings and lists, ready for notes or LLMs. |
| `pdf.to-pdfa` | PDF to PDF/A | Make an archival copy with an embedded color profile and PDF/A-2b identification. |
| `pdf.edit` | Edit PDF | Add text, images, shapes, highlights and freehand drawings to a PDF. |
| `pdf.sign` | Sign PDF | Draw, type or import your signature and place it on any page. |
| `pdf.forms` | PDF forms | Fill in forms, or add text fields, checkboxes and choice lists to make one. |
| `pdf.watermark` | Watermark PDF | Stamp text or an image over your PDF with the font, opacity and position you choose. |
| `pdf.page-numbers` | Page numbers | Add page numbers, headers or footers with your own position, text and size. |
| `pdf.metadata` | Edit metadata | Change or remove the title, author, subject and keywords stored in a PDF. |
| `pdf.protect` | Protect PDF | Encrypt a PDF with a password and choose what others may do with it. |
| `pdf.unlock` | Unlock PDF | Remove the password and restrictions from a PDF you have the password for. |
| `pdf.redact` | Redact PDF | Find and permanently black out names, emails, numbers or any words you choose. |
| `pdf.redact-areas` | Redact areas | Draw boxes over anything, including images and signatures, then remove it for good. |
| `pdf.compare` | Compare PDF | See two versions side by side with every added and removed line highlighted. |
| `pdf.scan` | Scan to PDF | Turn photos of paper into straight, clean PDF pages, like a document scanner. |
| `image.edit` | Photo editor | Crop, straighten, adjust colors, apply filters, and add text, shapes, stickers and blur. |
| `image.compress` | Compress image | Shrink JPG, PNG, GIF, HEIC and SVG files while keeping them looking the same. |
| `image.resize` | Resize image | Set exact pixels, a percentage or a longest side. Works on many images at once. |
| `image.crop` | Crop image | Crop to an aspect ratio, an exact area, or trim plain borders automatically. |
| `image.convert` | Convert image | Turn PNG, HEIC, WEBP, SVG, PSD, RAW and more into JPG, PNG or any other format. |
| `image.rotate` | Rotate image | Rotate, flip or straighten many images at once, or only the landscape or portrait ones. |
| `image.watermark` | Watermark image | Stamp text or a logo over your images with the font, opacity and position you choose. |
| `image.remove-background` | Remove background | Cut out people, pets and objects on device, then keep them on transparency or a new background. |
| `image.blur-faces` | Blur faces | Hide faces automatically, and optionally text and license plates, before you share. |
| `image.upscale` | Upscale image | Enlarge images 2x, 3x or 4x with high-quality resampling, noise reduction and sharpening. |
| `image.adjust` | Filters and adjustments | Apply the same filter and color adjustments to a whole batch of photos. |
| `image.meme` | Meme generator | Add bold top and bottom captions in the classic meme style. |
| `image.border` | Add border | Frame images with a solid, rounded, polaroid or drop shadow border. |
| `image.collage` | Photo collage | Combine several images into one grid, row or column with even spacing. |
| `image.make-gif` | Make a GIF | Turn a series of images into an animated GIF with your own timing. |
| `image.metadata` | Remove metadata | Strip camera details and GPS location from photos before you share them, without recompressing. |
| `image.to-text` | Image to text | Read the text in screenshots, photos and scans with on-device recognition. |
| `image.icon` | Make an icon | Turn an image into a macOS .icns or Windows .ico file with every size included. |
| `video.edit` | Video editor | Cut, zoom, add text and transitions on a timeline, then export. |
| `video.compress` | Compress video | Shrink videos for sharing while keeping them sharp. |
| `video.convert` | Convert video | Change a video to MP4, MOV, WebM, MKV, AVI or an animated GIF. |
| `video.trim` | Trim video | Keep only the part of a video you need. |
| `video.split` | Split video | Cut a video into equal parts, fixed-length pieces or at the times you choose. |
| `video.merge` | Merge videos | Join clips into one video. Sizes, frame rates and sound are matched for you. |
| `video.to-gif` | Video to GIF | Turn a moment of a video into a smooth, well-colored animated GIF. |
| `video.extract-audio` | Extract audio | Save the soundtrack of a video as MP3, M4A, WAV, FLAC or Opus. |
| `video.frames` | Video to images | Save frames as JPG or PNG, every few seconds, at set times or as one thumbnail. |
| `video.mute` | Mute video | Remove the sound from a video without touching the picture. |
| `video.rotate` | Rotate video | Turn a video sideways or upside down, or mirror it. |
| `video.crop` | Crop video | Crop to square, vertical or widescreen, a custom area, or remove black bars. |
| `video.resize` | Resize video | Change the resolution to 4K, 1080p, 720p, 480p or a custom width. |
| `video.speed` | Video speed | Speed a video up for timelapses or slow it down, with matching sound. |
| `video.reverse` | Reverse video | Play a video backwards, sound included. |
| `video.add-audio` | Add music | Replace the soundtrack or mix in background music. |
| `video.volume` | Adjust volume | Make a video louder or quieter, or even out loudness automatically. |
| `video.watermark` | Watermark video | Stamp text or a logo on every frame, with the position and opacity you choose. |
| `video.subtitles` | Add subtitles | Add an SRT or VTT file as a subtitle track, or burn the captions into the picture. |
| `video.loop` | Loop video | Repeat a clip several times in a row. |
| `video.fps` | Change frame rate | Convert to 24, 25, 30, 50 or 60 frames per second. |
| `video.from-images` | Images to video | Make a slideshow video from photos, with crossfades and optional music. |
| `video.stabilize` | Stabilize video | Smooth out shaky handheld footage. |
| `video.denoise` | Reduce video noise | Clean up grainy low-light video and, optionally, background hiss. |
| `video.fade` | Fade video | Fade the picture and sound in from black and out to black. |
| `video.adjust` | Adjust colors | Change brightness, contrast, saturation and gamma. |
| `video.social` | Resize for social | Fit a video to Reels, TikTok, Shorts, square or widescreen, with a blurred fill. |
| `audio.trim` | Trim audio | Cut a song, voice memo or podcast down to the part you want. |
| `audio.convert` | Convert audio | Change audio to MP3, M4A, WAV, FLAC, Opus, OGG, AIFF or Apple Lossless. |
| `audio.compress` | Compress audio | Make audio files smaller for sharing, keeping voices and music clear. |
| `audio.merge` | Merge audio | Join audio files one after another, with an optional crossfade. |
| `audio.volume` | Change volume | Make audio louder or quieter, or even out loudness to podcast levels. |
| `audio.speed` | Audio speed | Speed up or slow down audio, keeping the pitch natural or not. |
| `audio.fade` | Fade audio | Add smooth fades to the start and end. |
| `audio.reverse` | Reverse audio | Play audio backwards. |
| `audio.remove-silence` | Remove silence | Cut long pauses from recordings, or just trim silence at the start and end. |
| `audio.denoise` | Reduce audio noise | Lower steady background noise such as hiss, hum and fans. |
| `audio.to-video` | Audio to video | Turn audio into an MP4 with a cover image or a moving waveform, ready to upload. |
| `document.to-pdf` | Office to PDF | Convert Word, Excel, PowerPoint, text, Markdown and HTML files into PDF. |
| `document.word-to-pdf` | Word to PDF | Make DOC, DOCX, RTF, ODT, text and Markdown files easy to read and share as PDF. |
| `document.excel-to-pdf` | Excel to PDF | Print XLSX and CSV spreadsheets as clean, paginated PDF tables. |
| `document.powerpoint-to-pdf` | PowerPoint to PDF | Turn PPTX slideshows into a PDF with one slide per page. |
| `document.to-markdown` | Convert to Markdown | Turn Word, HTML, RTF, slides and spreadsheets into clean Markdown for notes or LLMs. |
| `document.to-text` | Extract text | Save the plain text of documents, slides and spreadsheets as a .txt file. |
| `web.to-pdf` | HTML to PDF | Save any web page as a PDF, split into printable pages or as one long page. |
| `web.to-image` | HTML to image | Capture a web page as a PNG or JPG screenshot, including the full scroll height. |
| `web.html-to-pdf` | HTML file to PDF | Render saved HTML pages to PDF with the same engine as Safari. |
| `files.zip` | Compress to ZIP | Bundle files and folders into one ZIP archive that opens anywhere. |
| `files.unzip` | Extract archive | Open ZIP, TAR, GZ, BZ2, XZ, 7Z, RAR and other archives into a folder. |
| `files.tar` | Create TAR archive | Pack files into a .tar.gz or .tar.xz archive for Unix and Linux systems. |
| `ai.summarize` | AI summarizer | Get the key points of a PDF or document in seconds, generated on this Mac. |
| `ai.translate` | Translate PDF | Translate PDFs on this Mac and keep their layout, or save any document as Word or Markdown. |
| `ai.transcribe` | Transcribe | Turn speech in audio and video into text or subtitles, on this Mac. |

## Where to go next

- [`ed studio probe`](./probe.md)
- [All `ed` commands](../README.md)
