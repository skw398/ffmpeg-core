# ffmpeg-core

Unofficial FFmpeg builds for macOS on Apple Silicon, including `ffmpeg`,
`ffprobe` and `ffplay`. This is the reduced ("core") configuration: nine
third-party libraries are linked statically, and runtime dynamic dependencies
are limited to Apple system libraries and frameworks. Keeping the dependency set
small keeps the supply-chain surface and the rebuild simple.

> [!NOTE]
> This project is under active development. Builds are provided as-is, without warranty.

## Included

| Area | Library |
|---|---|
| H.264 encode | x264 |
| HEVC encode | x265 |
| AV1 encode | SVT-AV1 |
| VP8 / VP9 encode | libvpx |
| AV1 decode | dav1d |
| MP3 encode | LAME |
| Opus encode | libopus |
| TLS (https, HLS) | OpenSSL |
| Playback | SDL2 |

DASH and IMF input use Apple's libxml2, so no extra dependency is pinned.

Capabilities that FFmpeg implements itself remain available: MP4/MOV, Matroska
and WebM, MPEG-TS, HLS, common native codecs (AAC, FLAC, ALAC, ProRes,
MPEG-2/4, H.264 and HEVC decode), the built-in filters, and
VideoToolbox / AudioToolbox / AVFoundation.

## Not included

- Subtitle rendering and text drawing (`subtitles`, `ass`, `drawtext`).
  Subtitle streams can still be copied, extracted and remuxed.
- Blu-ray and DVD input.
- WebP and JPEG XL output.
- OCR, QR codes, VMAF and other analysis filters.
- Vorbis output.
- Optional libraries outside [`deps.txt`](deps.txt): for example `zscale` (HDR
  and color conversion), SRT and RIST streaming, audio fingerprinting, video
  stabilization, and the `soxr` / `rubberband` resamplers.

## Links

- [Pinned dependencies](deps.txt)
- [Rebuilding from a source package](BUILDING.md)
- [Upstream modifications](SOURCE-CHANGES.md)
- [License scope, warranty and support](LICENSING.md)

Original project material is MIT-licensed. The FFmpeg binaries are distributed
under GPL-3.0-or-later. See [LICENSE](LICENSE) and [LICENSING.md](LICENSING.md).
