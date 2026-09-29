# Video delivery and masters

The editor exports through AVFoundation's reader/writer pipeline. Preview and export use the same video composition and audio mix. Export rebuilds the composition from the project before encoding.

## Encoding controls

The export sheet offers these codecs:

| Codec | Container | Intended use |
| --- | --- | --- |
| H.264 High | MP4 | Broadly compatible delivery |
| HEVC | MP4 | Smaller delivery files |
| HEVC Main 10 | MP4 | 10-bit delivery |
| ProRes 422 | MOV | Editing intermediate |
| ProRes 422 HQ | MOV | High-quality master |
| ProRes 4444 | MOV | High-precision master |

H.264 and HEVC expose target average video bitrate and maximum keyframe interval. The actual bitrate depends on content complexity and is reported after export. VideoToolbox hardware encoding is preferred. Requiring hardware encoding makes an unavailable hardware configuration an error rather than silently using software.

ProRes quality is selected by codec rather than an arbitrary bitrate. High-precision codecs receive half-float RGBA frames from the composition. A high-bit-depth codec cannot restore detail lost from the original source. The composited project background is opaque, including in a ProRes 4444 file.

Audio controls include mono or stereo, AAC at 128 to 320 kbps, and 24-bit PCM in QuickTime masters. AAC supports 44.1 or 48 kHz; PCM also supports 96 kHz. Every export uses the timeline's audio mix, including gains and fades.

The Audio mix tab exports a standalone WAV, AIFF, or M4A. WAV and AIFF use 24-bit PCM; M4A uses AAC. Mono AAC is limited to 256 kbps. Audio mix exports retain the full timeline duration, including leading gaps and trailing silence, and verify the decoded sample count before replacing the destination.

Delivery is explicitly Rec. 709 SDR. A 10-bit codec selection does not enable HDR mastering. Resolution presets only downscale the configured canvas, and the project frame duration determines output timing, including rational frame rates and high frame rates. Resolution and codec are independent settings.

## Completion and verification

The encoder writes to a unique temporary file beside the destination. After encoding, verification reads compressed samples to count frames and probes the actual dimensions, frame rate, codecs, audio sample rate and channels, color metadata, file size, and SHA-256. Bit depth is included when the native format description supplies it.

The encoded frame count and dimensions must match the composition before the export can finish. Overwriting atomically replaces the destination only after successful verification. A failure or cancellation removes the partial file and leaves an existing destination intact. Source media and the project document cannot be selected as the editor's export destination.

The completion sheet displays dimensions, frame count, codec, and checksum. Programmatic consumers can use the full structured delivery report.

## Regression coverage

`VideoDeliveryTests` renders synthetic media through all six codecs, checks AAC and PCM outputs, validates checksums, covers 120 fps and 60000/1001 fps, and cancels an active export to confirm destination preservation and temporary-file cleanup.
