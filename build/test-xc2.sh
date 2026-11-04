#!/bin/bash
# Acceptance tests 1-5, 7, 8 for xc-ffmpeg-8.1.3-xc2 (spec of 2026-11-03).
# Usage: test-xc2.sh <dir with ffmpeg+ffprobe> <FreeSans.ttf> <workdir> [xc1 dir]
set -u
B=$(cd "$1" && pwd); FONT=$2; T=$3; X1=${4:-}
mkdir -p "$T" && cd "$T" && rm -f ./*.ts ./*.m3u8 ./*.png
F=$B/ffmpeg; P=$B/ffprobe
hr(){ echo; echo "===== $*"; }

hr "1. static, version, no -march=native"
for b in "$F" "$P"; do echo "\$ ldd $(basename $b)"; ldd "$b" 2>&1; done
"$F" -version | head -1
echo "march=native count: $("$F" -buildconf | grep -c march=native)"
"$F" -buildconf | tr -s ' ' '\n' | grep -E -- '--enable-lib(harfbuzz|ass|zimg|vidstab)|--extra-version'

hr "2. filters"
"$F" -hide_banner -filters | grep -E " drawtext | subtitles | ass | zscale | vidstab"

hr "3. test input"
"$F" -nostdin -hide_banner -loglevel warning -f lavfi -i testsrc2=s=1280x720:r=25 -f lavfi -i sine=f=440:r=48000 \
  -ac 2 -t 10 -c:v libx264 -g 50 -c:a aac -f mpegts in.ts; echo "exit=$?  $(stat -c %s in.ts) bytes"

DT="drawtext=fontfile=$FONT:text='TEST123':fontsize=40:x=50:y=50:fontcolor=white"
HEAD=(-nofix_dts -fflags +igndts -copyts -vsync 0 -nostats -nostdin -hide_banner -loglevel warning -y -i in.ts)
TAIL=(-vcodec libx264 -preset ultrafast -acodec copy -scodec copy -mpegts_flags +initial_discontinuity -mpegts_copyts 1 -f mpegts)
fp(){ # $1 = name, rest = filter/map args
  local n=$1; shift; rm -f out_$n.ts frame_$n.png
  local s=$(date +%s.%N); "$F" "${HEAD[@]}" "$@" "${TAIL[@]}" out_$n.ts; local rc=$? e=$(date +%s.%N)
  echo "[$n] exit=$rc  $(awk "BEGIN{printf \"%.1f\", $e-$s}")s  $(stat -c %s out_$n.ts 2>/dev/null || echo 0) bytes"
  [ $rc = 0 ] || return
  "$F" -nostdin -hide_banner -loglevel error -y -i out_$n.ts -frames:v 1 frame_$n.png; echo "[$n] frame_$n.png exit=$?"
  # text check without eyes: the 300x60 box where TEST123 goes, drawn frame vs undrawn input frame
  echo "[$n] text box differs from input frame: $("$F" -nostdin -hide_banner -i frame_in.png -i frame_$n.png \
    -filter_complex '[0]crop=300:60:40:40[a];[1]crop=300:60:40:40[b];[a][b]psnr' -f null - 2>&1 | grep -o 'average:[^ ]*')"
  "$F" -nostdin -hide_banner -loglevel error -y -i out_$n.ts -map 0 -c copy -f null - && \
    echo "[$n] streams in output: $("$P" -v quiet -show_entries stream=codec_type -of csv=p=0 out_$n.ts | tr '\n' ' ')"; }
"$F" -nostdin -hide_banner -loglevel error -y -i in.ts -frames:v 1 frame_in.png
hr "4. fingerprint - exact panel command as given (-filter_complex + -map 0)"
fp exact -filter_complex "$DT" -map 0
hr "4a. same, filter on the video stream only (-vf) with -map 0"
fp vf -map 0 -vf "$DT"
hr "4b. same, labelled filter_complex: [0:v]...[v] -map [v] -map 0:a"
fp label -filter_complex "[0:v]$DT[v]" -map "[v]" -map 0:a

hr "7. production command shapes"
"$F" -y -nostdin -hide_banner -loglevel warning -err_detect ignore_err -nofix_dts -start_at_zero -copyts -vsync 0 \
  -correct_ts_overflow 0 -avoid_negative_ts disabled -max_interleave_delta 0 -probesize 5000000 -analyzeduration 5000000 \
  -i in.ts -map 0 -copy_unknown -vcodec copy -acodec copy -individual_header_trailer 0 -f segment -segment_format mpegts \
  -segment_time 10 -segment_list_size 6 -segment_format_options "mpegts_flags=+initial_discontinuity:mpegts_copyts=1" \
  -segment_list_type m3u8 -segment_list_flags +live+delete -segment_list a_.m3u8 a_%d.ts; echo "a) exit=$?  $(ls a_*.ts | wc -l) segment(s), playlist $(grep -c '\.ts' a_.m3u8) entr(y/ies)"
"$F" -y -nostdin -hide_banner -loglevel warning -i in.ts -c copy -fflags +discardcorrupt -err_detect ignore_err \
  -avoid_negative_ts make_zero -f segment -segment_format mpegts -segment_time 10 -segment_list b_.m3u8 b_%d.ts
echo "b) exit=$?  $(ls b_*.ts | wc -l) segment(s)"
"$F" -y -nostdin -hide_banner -loglevel warning -i in.ts -c copy -analyzeduration 10000000 -probesize 10000000 \
  -f segment -segment_format mpegts -segment_time 10 -segment_list c_.m3u8 c_%d.ts
echo "c) exit=$?  $(ls c_*.ts | wc -l) segment(s)"
"$F" -y -nostdin -hide_banner -loglevel warning -fflags +genpts+nobuffer -probesize 5000000 -analyzeduration 5000000 \
  -i in.ts -c copy -f segment -segment_format mpegts -segment_time 10 -segment_list d_.m3u8 d_%d.ts
echo "d) exit=$?  $(ls d_*.ts | wc -l) segment(s)"
"$P" -probesize 5000000 -analyzeduration 5000000 -i in.ts -v quiet -print_format json -show_streams -show_format > e.json
echo "e) exit=$?  $(python3 -c 'import json,sys;d=json.load(open("e.json"));print("valid JSON,",len(d["streams"]),"streams:",", ".join(s["codec_name"] for s in d["streams"]))')"

hr "8. sizes"
ls -l "$F" "$P" ${X1:+"$X1/ffmpeg" "$X1/ffprobe"} | awk '{print $5, $9}'
