#!/bin/bash
# Static ffmpeg/ffprobe n8.1.3-xc2 for XC nodes (Ubuntu 14.04 -> 24.04).
# Same as build.sh (xc1) plus libharfbuzz (drawtext needs it in FFmpeg >= 7),
# libass, libzimg and libvidstab. Run inside a clean Ubuntu 22.04 (Docker `ubuntu:22.04`
# or a debootstrap chroot) with this folder mounted at /b:
#   docker run --rm -v $PWD/build:/b -v $PWD/out:/out ubuntu:22.04 bash /b/build-xc2.sh
#
# CPU target: generic x86-64. Nothing here passes -march/-mtune; FFmpeg configure is run
# without --cpu, and the Ubuntu x264/x265/vpx/zimg libraries are built for baseline x86-64
# with run-time CPU detection. vid.stab adds only -msse2 (part of baseline x86-64).
#
# Built from source, static, because Ubuntu 22.04's packages can't be linked statically:
#  - harfbuzz: Ubuntu's libharfbuzz.a needs glib + graphite2 (no libgraphite2.a). Built with
#    FreeType only (drawtext uses hb-ft); no glib/ICU/cairo/graphite2.
#  - libass: Ubuntu has 0.15.2; built 0.17.5 against the harfbuzz above.
#  - vid.stab: Ubuntu ships no libvidstab.a. Built without OpenMP.
set -euo pipefail
FF_VER="${FF_VER:-8.1.3}"
OPENSSL_VER="${OPENSSL_VER:-3.5.9}"
HB_VER=15.0.0;     HB_SHA=968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df
ASS_VER=0.17.5;    ASS_SHA=2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc
VS_TAG=v1.1.2;     VS_COMMIT=92bc0b0f369f2a88aaacf25eac3a10f8415308fc
XV=xc2
JOBS="$(nproc)"
W=/build; OUT=/out; SSL=/opt/ssl; DEP=/opt/xcdeps
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p $W $OUT $W/dl

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends build-essential nasm pkg-config git curl ca-certificates perl file \
  xz-utils cmake python3-pip ninja-build \
  libx264-dev libx265-dev libnuma-dev libmp3lame-dev libopus-dev libvorbis-dev libtheora-dev libvpx-dev libxvidcore-dev \
  libfreetype-dev libfontconfig-dev libfribidi-dev libexpat1-dev libpng-dev libbrotli-dev libbz2-dev zlib1g-dev \
  uuid-dev libzimg-dev >/dev/null
# harfbuzz 15 needs meson >= 0.60 (Ubuntu 22.04 has 0.61; use pip's for a current one)
pip3 install -q 'meson>=1.4,<2' >/dev/null

fetch() { # url sha256 file
  [ -f "$W/dl/$3" ] || curl -fsSL -o "$W/dl/$3" "$1"
  echo "$2  $W/dl/$3" | sha256sum -c --quiet - || { echo "SHA256 MISMATCH: $3"; exit 1; }
}

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
# our static deps first, so libass/ffmpeg see our harfbuzz, not Ubuntu's
export PKG_CONFIG_PATH=$DEP/lib/pkgconfig:$DEP/lib/x86_64-linux-gnu/pkgconfig:$SSLLIB/pkgconfig
# x265.pc asks for -lgcc_s (shared-only); in a static link libgcc_eh provides the same symbols
mkdir -p /opt/fakelib && ln -sf "$(gcc -print-file-name=libgcc_eh.a)" /opt/fakelib/libgcc_s.a

# ---- harfbuzz (static, FreeType only) ----------------------------------------
if [ ! -f $DEP/lib/x86_64-linux-gnu/libharfbuzz.a ] && [ ! -f $DEP/lib/libharfbuzz.a ]; then
  fetch https://github.com/harfbuzz/harfbuzz/releases/download/$HB_VER/harfbuzz-$HB_VER.tar.xz $HB_SHA harfbuzz-$HB_VER.tar.xz
  rm -rf harfbuzz-$HB_VER && tar xJf dl/harfbuzz-$HB_VER.tar.xz && cd harfbuzz-$HB_VER
  meson setup _b --prefix=$DEP --buildtype=release --default-library=static \
    -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
    -Dicu=disabled -Dgraphite2=disabled -Dintrospection=disabled -Dtests=disabled -Ddocs=disabled \
    -Dutilities=disabled -Dbenchmark=disabled > $OUT/harfbuzz.log 2>&1 || { tail -30 $OUT/harfbuzz.log; exit 1; }
  ninja -C _b install >> $OUT/harfbuzz.log 2>&1 || { tail -30 $OUT/harfbuzz.log; exit 1; }
  cd $W
fi

# ---- libass (static) ---------------------------------------------------------
if [ ! -f $DEP/lib/libass.a ]; then
  fetch https://github.com/libass/libass/releases/download/$ASS_VER/libass-$ASS_VER.tar.xz $ASS_SHA libass-$ASS_VER.tar.xz
  rm -rf libass-$ASS_VER && tar xJf dl/libass-$ASS_VER.tar.xz && cd libass-$ASS_VER
  ./configure --prefix=$DEP --enable-static --disable-shared --disable-libunibreak > $OUT/libass.log 2>&1 \
    || { tail -30 $OUT/libass.log; exit 1; }
  make -j$JOBS >> $OUT/libass.log 2>&1 && make install >> $OUT/libass.log 2>&1 || { tail -30 $OUT/libass.log; exit 1; }
  cd $W
fi

# ---- vid.stab (static, no OpenMP) --------------------------------------------
if [ ! -f $DEP/lib/libvidstab.a ]; then
  rm -rf vid.stab && git clone -q --depth 1 --branch $VS_TAG https://github.com/georgmartius/vid.stab.git vid.stab
  [ "$(git -C vid.stab rev-parse HEAD)" = "$VS_COMMIT" ] || { echo "vid.stab commit mismatch"; exit 1; }
  cmake -S vid.stab -B vid.stab/_b -DCMAKE_INSTALL_PREFIX=$DEP -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DUSE_OMP=OFF > $OUT/vidstab.log 2>&1 || { tail -30 $OUT/vidstab.log; exit 1; }
  cmake --build vid.stab/_b -j$JOBS >> $OUT/vidstab.log 2>&1 && cmake --install vid.stab/_b >> $OUT/vidstab.log 2>&1 \
    || { tail -30 $OUT/vidstab.log; exit 1; }
fi

# ---- FFmpeg -----------------------------------------------------------------
rm -rf FFmpeg-n$FF_VER
git -c http.sslCAInfo="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" clone -q --depth 1 --branch n$FF_VER https://github.com/FFmpeg/FFmpeg.git FFmpeg-n$FF_VER
cd FFmpeg-n$FF_VER
# XC compat patch: segment_list_flags +delete, -user-agent alias, -fix_dts/-nofix_dts (no-op)
git apply "$HERE/xc-compat-$FF_VER.patch" || { echo "XC compat patch failed"; exit 1; }
# xc1 configure line, unchanged except --extra-version; additions at the end
./configure \
  --pkg-config-flags="--static" --extra-cflags="-I$SSL/include" \
  --extra-ldflags="-static -L$SSLLIB -L/opt/fakelib" --extra-libs="-lpthread -lm -lstdc++ -ldl" --ld=g++ \
  --extra-version="$XV-static" \
  --enable-gpl --enable-version3 --enable-static --disable-shared \
  --disable-ffplay --disable-doc --disable-debug \
  --enable-openssl --disable-iconv \
  --enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libopus --enable-libvorbis \
  --enable-libtheora --enable-libvpx --enable-libxvid \
  --enable-libfreetype --enable-libfontconfig --enable-libfribidi \
  --enable-libharfbuzz --enable-libass --enable-libzimg --enable-libvidstab \
  > $OUT/configure.log 2>&1 || { tail -30 ffbuild/config.log; exit 1; }
make -j$JOBS > $OUT/make.log 2>&1 || { tail -40 $OUT/make.log; exit 1; }
strip ffmpeg ffprobe

# ---- package ----------------------------------------------------------------
rm -rf $OUT/pkg && mkdir -p $OUT/pkg && cp ffmpeg ffprobe $OUT/pkg/
cd $OUT/pkg
for b in ffmpeg ffprobe; do file $b | grep -q 'statically linked' || { echo "NOT STATIC: $b"; file $b; exit 1; }; done
./ffmpeg -version | head -1
tar czf $OUT/xc-ffmpeg-$FF_VER-$XV.tar.gz ffmpeg ffprobe
cd $OUT && sha256sum xc-ffmpeg-$FF_VER-$XV.tar.gz > xc-ffmpeg-$FF_VER-$XV.tar.gz.sha256 && cat xc-ffmpeg-$FF_VER-$XV.tar.gz.sha256
