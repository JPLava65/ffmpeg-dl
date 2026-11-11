#!/bin/bash
# xc3 avstart tests (b-e of the xc3 spec, 2026-11-11). Runs both builds side by side.
# Usage: test-xc3-avstart.sh <xc3 bin dir> <xc2 bin dir> <work dir>
# Needs python3. Prints, per run, the first audio and first video packet times found in the output.
set -u
X3=$(cd "$1" && pwd); X2=$(cd "$2" && pwd); W=$3
mkdir -p "$W" && cd "$W" && rm -rf ./*
hr(){ echo; echo "===== $*"; }
# h264 decoder warnings from probing a mid-GOP start are dropped from the log (same on both builds)
quiet(){ grep -vE '^\s*(\[h264 @|Last message repeated)'; }

# first packet time per stream type, over all segments in playlist order; plus packet counts
first(){ # $1 = ffprobe, rest = files
  local P=$1; shift
  for f in "$@"; do "$P" -v quiet -show_entries packet=stream_index,pts_time,flags -show_entries stream=index,codec_type \
    -of json "$f"; done | python3 -c '
import json,sys
dec=json.JSONDecoder(); s=sys.stdin.read(); i=0; first={}; n={}
while i<len(s):
    while i<len(s) and s[i].isspace(): i+=1
    if i>=len(s): break
    d,i=dec.raw_decode(s,i)
    t={x["index"]:x["codec_type"] for x in d.get("streams",[])}
    for p in d.get("packets",[]):
        k=t.get(p["stream_index"]); n[k]=n.get(k,0)+1
        if k not in first and p.get("pts_time") not in (None,"N/A"): first[k]=float(p["pts_time"])
a=first.get("audio"); v=first.get("video")
print("first audio %s  first video %s  audio-before-video %s  packets %s" % (
    "%.3f"%a if a is not None else "-", "%.3f"%v if v is not None else "-",
    "%.3f s"%(v-a) if a is not None and v is not None else "-", n))'
}
seg(){ # $1 = ffmpeg dir, $2 = name, $3 = input, rest = env; $IOPT = extra input options
  local B=$1 n=$2 in=$3; shift 3; rm -f ${n}_*.ts ${n}.m3u8
  env "$@" "$B/ffmpeg" -nostdin -hide_banner -loglevel warning ${IOPT:-} -i "$in" -c copy -f segment -segment_format mpegts \
    -segment_time 10 -segment_list ${n}.m3u8 ${n}_%d.ts 2>&1 | quiet | sed "s/^/  [$n log] /"
  echo "  [$n] exit=${PIPESTATUS[0]}  segments: $(ls ${n}_*.ts | wc -l)"
  echo "  [$n] $(first "$B/ffprobe" $(grep -v '^#' ${n}.m3u8))"; }
cut(){ # $1 = in, $2 = out, $3 = seconds to cut (by bytes, 188-byte boundary)
  local sz dur off; sz=$(stat -c %s "$1"); dur=$("$X3/ffprobe" -v error -show_entries format=duration -of csv=p=0 "$1")
  off=$(python3 -c "import sys;sz,dur,c=int(sys.argv[1]),float(sys.argv[2]),float(sys.argv[3]);print(int(sz*c/dur)//188*188)" $sz $dur $3)
  tail -c +$((off+1)) "$1" > "$2"; echo "  cut $off bytes (~$3 s) from $1 -> $2"; }
mk(){ # $1 = gop, $2 = file
  "$X3/ffmpeg" -nostdin -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=1280x720:r=25 -f lavfi -i sine=f=440:r=48000 \
    -ac 2 -t 60 -c:v libx264 -preset veryfast -g $1 -keyint_min $1 -sc_threshold 0 -c:a aac -f mpegts "$2"; echo "  made $2 (gop $1) exit=$?"; }

hr "b. mid-GOP start, -g 50 (2 s GOP), ~1 s cut"
mk 50 g50.ts; cut g50.ts mid.ts 1
echo "  input:  $(first "$X3/ffprobe" mid.ts)"
echo "  input video keyframes: $("$X3/ffprobe" -v quiet -select_streams v -skip_frame nokey -show_entries frame=pts_time -of csv=p=0 mid.ts | head -3 | tr '\n' ' ')"
seg "$X2" xc2_b mid.ts
seg "$X3" xc3_b mid.ts

hr "c. safety net, -g 500 (20 s GOP), ~3 s cut"
mk 500 g500.ts; cut g500.ts mid500.ts 3
echo "  input:  $(first "$X3/ffprobe" mid500.ts)"
echo "  input video keyframes: $("$X3/ffprobe" -v quiet -select_streams v -skip_frame nokey -show_entries frame=pts_time -of csv=p=0 mid500.ts | head -3 | tr '\n' ' ')"
# a 20 s GOP needs more than the default 5 MB / 5 s probe to find the video parameters (both builds)
IOPT="-probesize 50000000 -analyzeduration 30000000" seg "$X2" xc2_c mid500.ts
IOPT="-probesize 50000000 -analyzeduration 30000000" seg "$X3" xc3_c mid500.ts

hr "d. XC_NO_WAIT_VIDEO=1, input of b"
seg "$X3" xc3_d mid.ts XC_NO_WAIT_VIDEO=1

hr "e1. audio-only copy to mpegts (input of b)"
for b in xc2:$X2 xc3:$X3; do n=${b%%:*}; B=${b#*:}
  "$B/ffmpeg" -nostdin -hide_banner -loglevel warning -y -i mid.ts -map 0:a -c copy -f mpegts ${n}_e1.ts 2>&1 | quiet
  echo "  [$n] exit=${PIPESTATUS[0]}  $(first "$B/ffprobe" ${n}_e1.ts)"; done
hr "e2. video transcoded + audio copied to segment (input of b)"
for b in xc2:$X2 xc3:$X3; do n=${b%%:*}; B=${b#*:}; rm -f ${n}_e2_*.ts
  "$B/ffmpeg" -nostdin -hide_banner -loglevel warning -y -i mid.ts -c:v libx264 -preset ultrafast -c:a copy -f segment \
    -segment_format mpegts -segment_time 10 -segment_list ${n}_e2.m3u8 ${n}_e2_%d.ts 2>&1 | quiet
  echo "  [$n] exit=${PIPESTATUS[0]}  $(first "$B/ffprobe" $(grep -v '^#' ${n}_e2.m3u8))"; done

hr "-user-agent (XC alias) and -nofix_dts on an HTTP input"
python3 -c '
import http.server,sys
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self,f,*a): sys.stderr.write("UA=%s %s\\n" % (self.headers.get("User-Agent"), f % a)); sys.stderr.flush()
http.server.ThreadingHTTPServer(("127.0.0.1",18089),H).serve_forever()' >http.log 2>&1 & HP=$!; sleep 1
for b in xc2:$X2 xc3:$X3; do n=${b%%:*}; B=${b#*:}
  "$B/ffmpeg" -nostdin -hide_banner -loglevel warning -y -user-agent "XC-test-$n" -nofix_dts -i http://127.0.0.1:18089/mid.ts \
    -t 5 -c copy -f mpegts ${n}_ua.ts 2>&1 | quiet; echo "  [$n] exit=${PIPESTATUS[0]}  user agent seen by the server: $(grep -c "XC-test-$n" http.log)"
done; kill $HP
