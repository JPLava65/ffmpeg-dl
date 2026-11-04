# ffmpeg-dl: static ffmpeg/ffprobe for XC nodes

**What it is:** FFmpeg **8.1.3** + ffprobe with a small **XC compatibility patch**, fully static (no shared
libraries), built in a clean Ubuntu 22.04 with OpenSSL 3.5.9. Runs on Ubuntu 14.04 → 24.04. Replaces XC's
bundled `N-92517-gd0f5942-Xtream-Codes` (Nov 2018) at `/home/xtreamcodes/iptv_xtream_codes/bin/`.
Version string: `n8.1.3-xc1-static`.

| Release | File | Notes |
|---|---|---|
| **v8.1.3-xc2** | `xc-ffmpeg-8.1.3-xc2.tar.gz` (+ `.sha256`) | xc1 + libharfbuzz (drawtext: the panel's fingerprint), libass, libzimg, libvidstab. **Validated on the Halyard lab LB (2026-11-04). For Halyard 1.0.4+ nodes only — see below.** Build: `build/build-xc2.sh`; tests: `build/test-xc2.sh` |
| v8.1.3-xc1 | `xc-ffmpeg-8.1.3-xc1.tar.gz` (+ `.sha256`) | **no drawtext** (no harfbuzz), so panel fingerprinting fails on it |
| v8.1.3 | `xc-ffmpeg-8.1.3.tar.gz` | unpatched — **do not deploy**: XC live streams fail on it |

## XC compatibility patch (`build/xc-compat-8.1.3.patch`, ~40 lines)
XC's 2018 ffmpeg is itself a patched build. XC's encoded PHP passes options upstream FFmpeg doesn't have:
1. `-segment_list_flags +live+delete` — XC's own flag: delete .ts segments that left the playlist. Without it
   upstream ffmpeg refuses to start ("Unable to parse segment_list_flags"); simply dropping it would let
   `streams/` fill the disk. Re-implemented; each dropped segment is deleted **one segment later** (so a
   player that just read the playlist can still fetch it). Disk = list_size + 1 segments per stream.
2. `-user-agent` — alias of `-user_agent` restored (removed upstream). No panel/DB change needed.
3. `-fix_dts` / `-nofix_dts` — XC-only option ("fix invalid dts"). Accepted, **no effect**. XC only
   passes `-nofix_dts` (off), which matches. What XC's fix did when on is unknown.

## Compatibility with XC's stream options (tested)
- XC `streams_arguments` templates (user-agent, http_proxy, cookies, headers, b:v/b:a, minrate/maxrate/bufsize,
  crf, filter_complex scale/delogo/overlay/yadif, aspect, r, ar, ac, threads) and transcode profile
  `-vcodec h264 -acodec aac`: all accepted.
- XC live command line (copy → segment, +live+delete, mpegts_copyts, initial_discontinuity, -async,
  -err_detect, -nofix_dts): accepted; only list_size+1 segments remain on disk; every listed segment exists.
- New, not in the 2018 build: `-reconnect_on_network_error 1`, `-reconnect_on_http_error 4xx,5xx`.
- Same probe speed as the 2018 build on a real source (test panel, 2026-10-25).

## Rebuild
`build/build.sh` (applies the patch automatically) inside a clean Ubuntu 22.04:
`docker run --rm -v $PWD/build:/b -v $PWD/out:/out ubuntu:22.04 bash /b/build.sh`

## xc2 notes
- Fingerprint needs the panel to send a labelled filter graph or `-vf` (ffmpeg 8 rejects an unlabelled
  `-filter_complex` when `-map 0` has already taken the video stream: "Cannot find an unused video input stream").
- harfbuzz 15.0.0 (FreeType only), libass 0.17.5 and vid.stab 1.1.2 are built from source, static; see
  `build/build-xc2.sh`. Generic x86-64 target (no `-march`).
- `build/test-xc2.sh <bin dir> <FreeSans.ttf> <work dir>` runs the acceptance tests.

## Which build on which node (2026-11-04)
| Node runs | Use |
|---|---|
| Halyard 1.0.4+ panel code | **xc2** |
| Original XC panel code | **keep the 2018 build (N-92517)** — neither xc1 nor xc2 |

The original XC panel builds two command forms that every ffmpeg 8.x refuses: fingerprint
(`-filter_complex "drawtext=..."` + `-map 0`) and transcode filters (unlabelled `-filter_complex` + `-map 0`).
On a node running the original panel code those features fail with any 8.x build. Halyard 1.0.4 fixes both
(fingerprint uses `-vf`; filters become one `-vf` chain).

## xc2 validation (2026-11-03/04)
- Build tests (`build/test-xc2.sh`, Ubuntu 22.04 builder): all pass except the original-panel command form above.
- Halyard lab LB (Ubuntu 22.04, 48 threads), installed over xc1: drawtext present; panel command audit identical
  to xc1 for live copy (8 shapes), fetch arguments (user agent, headers, cookies, reconnect, proxy), transcode
  without filters, VOD (mp4/mkv/ts copy + transcode) and probes (stream / fetch / admin); fingerprint end to end
  through the admin API on a live TS viewer: text drawn; transcode filters (scale, delogo, yadif, logo, combined,
  two outputs HLS + FLV) 13/13 OK with Halyard 1.0.4's command builder; a real panel-started channel with
  bitrate + scale + delogo + logo gave 640x360 H.264 + AAC with logo and delogo visible; full Halyard regression
  suite equal to the previous baseline.
- Oldest fleet OS (Ubuntu 14.04.6, kernel 3.13, glibc 2.19): ffmpeg/ffprobe start, drawtext present, fingerprint
  command exits 0 with H.264 + AAC output and the text drawn, XC segmenter with +live+delete exits 0 and deletes
  old segments.
