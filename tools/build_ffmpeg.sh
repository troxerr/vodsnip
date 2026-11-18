#!/bin/zsh
# Builds an LGPL-only ffmpeg and ffprobe into vendor/bin from the official FFmpeg source.
#
# Only Apple's own libraries are linked (VideoToolbox, Security for HTTPS, zlib, iconv), so there is no GPL or
# patent-encumbered codec inside and nothing to ship besides the binaries. LGPL still asks you to include the
# license text (https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt) and a pointer to the FFmpeg source
# (https://ffmpeg.org) in the app's About text or website.
#
# Takes a few minutes. Build files live in a temp folder, not in the repo.
set -euo pipefail
here=${0:A:h:h}
version="9.0.2"
# SHA-256 of ffmpeg-$version.tar.xz, the same value Homebrew's formula pins. Update both together.
sha256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
curl -fsSL -o src.tar.xz "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz"
[[ "$(shasum -a 256 src.tar.xz | awk '{print $1}')" == "$sha256" ]] || { echo "ERROR: source checksum mismatch"; exit 1; }
tar -xf src.tar.xz
cd "ffmpeg-$version"

./configure --prefix="$work/out" \
  --disable-gpl --disable-nonfree --disable-autodetect --disable-doc --disable-debug --disable-ffplay \
  --enable-securetransport --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-iconv \
  --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags="-mmacosx-version-min=14.0 -liconv" > "$work/configure.log"
grep -q "^License: LGPL" "$work/configure.log" || { echo "ERROR: build is not LGPL"; exit 1; }
make -j"$(sysctl -n hw.ncpu)" > "$work/make.log" 2>&1 || { tail -20 "$work/make.log"; exit 1; }
make install >> "$work/make.log" 2>&1

mkdir -p "$here/vendor/bin"
install -m 755 "$work/out/bin/ffmpeg" "$work/out/bin/ffprobe" "$here/vendor/bin/"
strip -x "$here/vendor/bin/ffmpeg" "$here/vendor/bin/ffprobe"
echo "ok: $("$here/vendor/bin/ffmpeg" -version | head -1) (LGPL, system libraries only)"
