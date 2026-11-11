# ffmpeg-dl: static ffmpeg/ffprobe for XC nodes

**What it is:** FFmpeg **8.1.3** + ffprobe with a small **XC compatibility patch**, fully static (no shared
libraries), built in a clean Ubuntu 22.04 with OpenSSL 3.5.9. Runs on Ubuntu 14.04 → 24.04. Replaces XC's
bundled `N-92517-gd0f5942-Xtream-Codes` (Nov 2018) at `/home/xtreamcodes/iptv_xtream_codes/bin/`.
Version string: `n8.1.3-xc1-static`.

| Release | File | Notes |
|---|---|---|
| **v8.1.3-xc3** | `xc-ffmpeg-8.1.3-xc3.tar.gz` (+ `.sha256`) | xc2 + `build/xc-avstart-8.1.3.patch`: on live copy outputs, audio starts with the picture (see "xc3" below). Same panel commands as xc2; xc2 ↔ xc3 swap either way. Halyard panel code only. Build: `build/build-xc3.sh`; tests: `build/test-xc2.sh` + `build/test-xc3-avstart.sh` |
| v8.1.3-xc2 | `xc-ffmpeg-8.1.3-xc2.tar.gz` (+ `.sha256`) | xc1 + libharfbuzz (drawtext: the panel's fingerprint), libass, libzimg, libvidstab. **Validated on the Halyard lab LB (2026-11-04). For Halyard 1.0.4+ nodes only — see below.** Build: `build/build-xc2.sh`; tests: `build/test-xc2.sh` |
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
| Halyard 1.0.4+ panel code | **xc2** or **xc3** |
| Original XC panel code | **keep the 2018 build (N-92517)** — not xc1, xc2 or xc3 |

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

## xc3: audio starts with the picture (2026-11-11)
**What it changes.** With stream copy, ffmpeg starts audio at once but video only at its next keyframe, so a live
channel's first segment began with up to one GOP of sound without picture. xc3 adds one patch,
`build/xc-avstart-8.1.3.patch` (`fftools/ffmpeg_mux.c`, `ffmpeg_mux.h`): for the output muxers **segment, mpegts and
hls**, when the output has a **copied** video stream (not cover art), every other copied stream waits for the first
video keyframe and starts at its timestamp.
- **Safety net:** if no video keyframe arrives within 10 s of stream time, ffmpeg logs
  `XC: no video keyframe within 10 s, starting the other streams without it` and starts the other streams anyway.
- **Not affected:** audio-only outputs, outputs whose video is transcoded, other muxers (mp4, mkv, flv, ...).
- **Off switch:** `XC_NO_WAIT_VIDEO=1` in ffmpeg's environment gives the xc2 behaviour.
- **No new command-line option**, so the panel's commands are identical and xc2 and xc3 can be swapped either way.
- Everything else is xc2: FFmpeg n8.1.3, same configure line except `--extra-version=xc3-static`, same libraries.

**Node rule (same as xc2):** Halyard panel code only. Nodes with the original panel code keep the 2018 build.

**Tests (2026-11-11):** `build/test-xc2.sh` on xc3 in Ubuntu 14.04, 18.04, 20.04, 22.04 and 24.04 userlands: same
results as xc2. `build/test-xc3-avstart.sh` (xc3 next to xc2):
| Test | xc2 | xc3 |
|---|---|---|
| copy to segment, input cut mid-GOP (2 s GOP) | audio 1.168 s before video | audio 0.005 s after video |
| 20 s GOP, cut 3 s in | audio from the start | warning logged, audio starts 10.0 s after the input's first audio, exit 0 |
| `XC_NO_WAIT_VIDEO=1` | — | audio 1.168 s before video (= xc2) |
| audio-only copy; video transcoded + audio copied | all 2774 audio packets | all 2774 audio packets (unchanged) |
| `-user-agent` + `-nofix_dts` on an HTTP input | sent, exit 0 | sent, exit 0 |
