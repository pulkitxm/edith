# `ed studio`

[Back to the CLI reference](../README.md)

Studio is the Media suite's workshop for files. In the Edith window you drop
images, PDFs, videos, audio and documents into Studio, then pick **Edit**,
**Compress**, **Convert** or any of more than a hundred tools, the way you would
on a site like iLovePDF or iLoveIMG, except that nothing leaves this Mac. `ed
studio` runs the same tools from a terminal or a script.

Enable **Studio** in Edith's Extensions screen under **Media**. The CLI does not
need the app to be running: every tool runs inside `ed` itself.

## At a glance

| Command | What it does |
| --- | --- |
| `ed studio` | Runs `ed studio tools`, the default subcommand. |
| [`ed studio tools`](./tools.md) | Lists every tool, optionally only those for one kind of file. |
| [`ed studio info <tool>`](./info.md) | Shows what a tool does and every setting it takes. |
| [`ed studio run <tool> <files...>`](./run.md) | Runs a tool and saves the results. |
| [`ed studio probe <file>`](./probe.md) | Describes a file and lists the tools that accept it. |

## What is in Studio

- **PDF:** merge, split, remove and reorder pages, rotate, pages per sheet,
  page size, crop, compress, grayscale, OCR, repair, flatten, decompress and
  linearize (with qpdf), PDF to JPG, JPG to PDF, PDF to Word, PowerPoint, Excel,
  text, Markdown and PDF/A, watermark, page numbers, metadata, protect, unlock,
  redact and compare. The PDF editor adds text, shapes, drawings, highlights,
  notes, images, signatures, form fields, redaction boxes, crop areas and a
  page organizer.
- **Images:** compress, resize, crop, convert, rotate, watermark, remove the
  background, blur faces, upscale, meme, border, collage, GIF maker, adjust,
  remove metadata, extract text and make icons. The image editor adds crop and
  straighten, adjustments, filters, text, drawing, shapes, stickers, blur and
  frames.
- **Video and audio** (with FFmpeg): compress, convert, trim, split, merge, GIF,
  extract audio, frames, mute, rotate, crop, resize, speed, reverse, add music,
  volume, watermark, subtitles, loop, frame rate, slideshows, stabilize,
  denoise, fades, color and social formats, plus the audio versions of these.
  **Edit** on a video opens the timeline editor, and its projects are listed
  under **Projects**.
- **Documents and the web:** Word, text, Markdown, Excel, CSV and PowerPoint
  to PDF, documents to Markdown or text, and web pages or HTML files to PDF or
  an image.
- **Files:** zip, unzip and tar.
- **Intelligence:** on-device summaries with Apple Intelligence, and
  translation with the macOS Translation languages you have downloaded.

## Engines

Video and audio tools use FFmpeg, and four PDF tools use qpdf. Tools that need a
missing engine say so in Studio with an install button, and `ed studio tools`
marks them. Install either with `ed tools install ffmpeg` or `ed tools install
qpdf`.

## Where results go

`run` saves each result next to the file it came from unless you pass
`--output-dir`. In the app, choose the destination under **Save to**: next to the
original, Downloads, or a folder. A result never overwrites a file; a second run
saves `report-compressed 2.pdf`.

## Where to go next

- [`ed tools`](../tools/README.md), for installing FFmpeg and qpdf
- [All `ed` commands](../README.md)
