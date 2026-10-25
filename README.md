# ffmpeg-dl: static ffmpeg/ffprobe for XC nodes

**What it is:** FFmpeg **8.1.3** + ffprobe with a small **XC compatibility patch**, fully static (no shared
libraries), built in a clean Ubuntu 22.04 with OpenSSL 3.5.9. Runs on Ubuntu 14.04 → 24.04. Replaces XC's
bundled `N-92517-gd0f5942-Xtream-Codes` (Nov 2018) at `/home/xtreamcodes/iptv_xtream_codes/bin/`.
Version string: `n8.1.3-xc1-static`.

| Release | File | Notes |
|---|---|---|
| **v8.1.3-xc1** | `xc-ffmpeg-8.1.3-xc1.tar.gz` (+ `.sha256`) | **use this one** — drop-in for XC |
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
