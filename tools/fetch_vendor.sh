#!/bin/zsh
# Downloads the two tools Vodsnip ships with into vendor/bin (git ignores that folder).
#
#   yt-dlp  the official standalone macOS build from github.com/yt-dlp/yt-dlp, checked against the release's
#           SHA2-256SUMS file. License: Unlicense.
#   ffmpeg  a static build from evermeet.cx, checked against the hash its own API reports.
#
# LICENSE WARNING: that ffmpeg build is GPL. Shipping a GPL binary means you must offer its source and
# license text with the app. For a no-strings build, use an LGPL-only static ffmpeg instead: put it at
# vendor/bin/ffmpeg yourself and skip this script's ffmpeg step (FETCH_FFMPEG=0).
#
# Rerun any time to update yt-dlp: Twitch changes break old versions, so ship a fresh one with every release.
set -euo pipefail
here=${0:A:h:h}
vendor="$here/vendor/bin"
mkdir -p "$vendor"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "==> yt-dlp (official release)"
base="https://github.com/yt-dlp/yt-dlp/releases/latest/download"
curl -fsSL -o "$tmp/yt-dlp_macos" "$base/yt-dlp_macos"
curl -fsSL -o "$tmp/SUMS" "$base/SHA2-256SUMS"
want=$(grep " yt-dlp_macos\$" "$tmp/SUMS" | awk '{print $1}')
got=$(shasum -a 256 "$tmp/yt-dlp_macos" | awk '{print $1}')
[[ -n "$want" && "$want" == "$got" ]] || { echo "ERROR: yt-dlp checksum mismatch"; exit 1; }
install -m 755 "$tmp/yt-dlp_macos" "$vendor/yt-dlp"
echo "ok: $("$vendor/yt-dlp" --version)"

if [[ "${FETCH_FFMPEG:-1}" == 1 ]]; then
  echo "==> ffmpeg (evermeet.cx static build, GPL)"
  info=$(curl -fsSL "https://evermeet.cx/ffmpeg/info/ffmpeg/release")
  url=$(print -r -- "$info" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["download"]["zip"]["url"])')
  want=$(print -r -- "$info" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["download"]["zip"]["sha256"])')
  [[ "$url" == https://evermeet.cx/* && -n "$want" ]] || { echo "ERROR: unexpected ffmpeg API answer"; exit 1; }
  curl -fsSL -o "$tmp/ffmpeg.zip" "$url"
  got=$(shasum -a 256 "$tmp/ffmpeg.zip" | awk '{print $1}')
  [[ "$want" == "$got" ]] || { echo "ERROR: ffmpeg checksum mismatch"; exit 1; }
  mkdir "$tmp/ff" && unzip -q "$tmp/ffmpeg.zip" -d "$tmp/ff"
  install -m 755 "$tmp/ff/ffmpeg" "$vendor/ffmpeg"
  echo "ok: $("$vendor/ffmpeg" -version | head -1)"
fi

echo "vendor/bin is ready. Next: tools/release.sh"
