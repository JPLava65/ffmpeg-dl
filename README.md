# ffmpeg-dl: static ffmpeg/ffprobe for XC nodes

**What it is:** FFmpeg **8.1.3** + ffprobe, fully static (no shared libraries at all), built in a clean
Ubuntu 22.04 with OpenSSL 3.5.9. Runs on Ubuntu 14.04 → 24.04. Replaces XC's bundled
`N-92517-gd0f5942-Xtream-Codes` (Nov 2018) at `/home/xtreamcodes/iptv_xtream_codes/bin/`.

| File | sha256 |
|---|---|
| `xc-ffmpeg-8.1.3.tar.gz` | see `xc-ffmpeg-8.1.3.tar.gz.sha256` |

**Included:** x264, x265, mp3lame, opus, vorbis, theora, vpx, xvid, freetype/fontconfig/fribidi (drawtext),
OpenSSL (https sources), native RTMP. **Left out:** libass (subtitle burn-in; XC copies subtitles),
iconv (static glibc + iconv crashes on MPEG-TS input — see build.sh), librtmp (native RTMP instead).

## Compatibility with XC's stream options (tested)
- Accepted: -vsync, -async, -copyts, -start_at_zero, -err_detect, -fflags, -avoid_negative_ts, -probesize,
  -analyzeduration, all -segment_* options, -progress, -individual_header_trailer.
- **Rejected:** `-user-agent` (use `-user_agent` — the 2018 build accepts both, so change XC first) and
  `-nofix_dts` (not a standard ffmpeg option — XC-specific; remove from the streams that use it).
- New, not in the 2018 build: `-reconnect_on_network_error 1`, `-reconnect_on_http_error 4xx,5xx`.

## Tests run on the build (2026-10-25)
file input; XC-style HTTP → segment muxer (copy) with -user_agent and reconnect options (m3u8 + .ts
segments + -progress output OK); transcode with -vsync/-async (x264/aac); ffprobe JSON.
Not yet tested: real sources, hostname (DNS) sources, RTMP sources, live reconnect — do these on the test panel.

## Rebuild
`build/build.sh` inside a clean Ubuntu 22.04 (Docker `ubuntu:22.04` or a debootstrap chroot):
`docker run --rm -v $PWD/build:/b -v $PWD/out:/out ubuntu:22.04 bash /b/build.sh`
