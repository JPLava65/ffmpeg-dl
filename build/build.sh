#!/bin/bash
# Static ffmpeg/ffprobe for XC nodes (Ubuntu 14.04 -> 24.04).
# Run inside a clean Ubuntu 22.04 (Docker `ubuntu:22.04` or a debootstrap chroot).
# glibc >= 2.34 has DNS/files lookup built in, so a fully static binary resolves
# hostnames on any target (same approach as the nginx-dl builds).
# --disable-iconv: iconv in static glibc dlopen()s the HOST gconv modules and crashes
# (seen: SIGSEGV in __gconv_find_shlib on any MPEG-TS input).
set -euo pipefail
FF_VER="${FF_VER:-8.1.3}"
OPENSSL_VER="${OPENSSL_VER:-3.5.9}"
JOBS="$(nproc)"
W=/build; OUT=/out; SSL=/opt/ssl
mkdir -p $W $OUT

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends build-essential nasm pkg-config git curl ca-certificates perl file \
  libx264-dev libx265-dev libnuma-dev libmp3lame-dev libopus-dev libvorbis-dev libtheora-dev libvpx-dev libxvidcore-dev \
  libass-dev libfreetype-dev libfontconfig-dev libfribidi-dev libharfbuzz-dev libgraphite2-dev libglib2.0-dev \
  libexpat1-dev libpng-dev libbrotli-dev libbz2-dev zlib1g-dev libunibreak-dev >/dev/null 2>&1 || \
apt-get install -y -qq --no-install-recommends build-essential nasm pkg-config git curl ca-certificates perl file \
  libx264-dev libx265-dev libnuma-dev libmp3lame-dev libopus-dev libvorbis-dev libtheora-dev libvpx-dev libxvidcore-dev \
  libass-dev libfreetype-dev libfontconfig-dev libfribidi-dev libharfbuzz-dev libgraphite2-dev libglib2.0-dev \
  libexpat1-dev libpng-dev libbrotli-dev libbz2-dev zlib1g-dev

cd $W
# ---- OpenSSL (static, current 3.5 LTS) -------------------------------------
if [ ! -f $SSL/lib64/libssl.a ] && [ ! -f $SSL/lib/libssl.a ]; then
  curl -fsSL -o openssl.tgz https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz
  tar xzf openssl.tgz && cd openssl-$OPENSSL_VER
  ./Configure linux-x86_64 no-shared no-tests no-docs --prefix=$SSL --openssldir=/usr/lib/ssl >/dev/null
  make -j$JOBS >/dev/null && make install_sw >/dev/null
  cd $W
fi
SSLLIB=$SSL/lib64; [ -d $SSLLIB ] || SSLLIB=$SSL/lib
export PKG_CONFIG_PATH=$SSLLIB/pkgconfig
# x265.pc asks for -lgcc_s (shared-only); in a static link libgcc_eh provides the same symbols
mkdir -p /opt/fakelib && ln -sf "$(gcc -print-file-name=libgcc_eh.a)" /opt/fakelib/libgcc_s.a

# ---- FFmpeg -----------------------------------------------------------------
rm -rf FFmpeg-n$FF_VER
git -c http.sslCAInfo="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" clone -q --depth 1 --branch n$FF_VER https://github.com/FFmpeg/FFmpeg.git FFmpeg-n$FF_VER
cd FFmpeg-n$FF_VER
# XC compat patch: segment_list_flags +delete, -user-agent alias, -fix_dts/-nofix_dts (no-op)
git apply "$(cd "$(dirname "$0")" && pwd)/xc-compat-$FF_VER.patch" || { echo "XC compat patch failed"; exit 1; }
./configure \
  --pkg-config-flags="--static" --extra-cflags="-I$SSL/include" \
  --extra-ldflags="-static -L$SSLLIB -L/opt/fakelib" --extra-libs="-lpthread -lm -lstdc++ -ldl" --ld=g++ \
  --extra-version="xc1-static" \
  --enable-gpl --enable-version3 --enable-static --disable-shared \
  --disable-ffplay --disable-doc --disable-debug \
  --enable-openssl --disable-iconv \
  --enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libopus --enable-libvorbis \
  --enable-libtheora --enable-libvpx --enable-libxvid \
  --enable-libfreetype --enable-libfontconfig --enable-libfribidi \
  > $OUT/configure.log 2>&1 || { tail -30 ffbuild/config.log; exit 1; }
make -j$JOBS > $OUT/make.log 2>&1 || { tail -40 $OUT/make.log; exit 1; }
strip ffmpeg ffprobe

# ---- package ----------------------------------------------------------------
mkdir -p $OUT/pkg && cp ffmpeg ffprobe $OUT/pkg/
cd $OUT/pkg
file ffmpeg | grep -q 'statically linked' || { echo "NOT STATIC"; file ffmpeg; exit 1; }
./ffmpeg -version | head -1
tar czf $OUT/xc-ffmpeg-$FF_VER-xc1.tar.gz ffmpeg ffprobe
cd $OUT && sha256sum xc-ffmpeg-$FF_VER-xc1.tar.gz > xc-ffmpeg-$FF_VER-xc1.tar.gz.sha256 && cat xc-ffmpeg-$FF_VER-xc1.tar.gz.sha256
