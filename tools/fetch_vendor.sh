#!/bin/zsh
# Downloads yt-dlp into vendor/bin (git ignores that folder): the official standalone macOS build from
# github.com/yt-dlp/yt-dlp, checked against the release's SHA2-256SUMS file. License: Unlicense.
#
# Rerun it for every release: Twitch changes break old yt-dlp builds.
#
# ffmpeg is NOT fetched here on purpose. Ready-made static builds bundle GPL and patent-encumbered codecs
# (x264, x265, Xvid, faac), which is a heavy burden for a paid app. Run tools/build_ffmpeg.sh for an LGPL-only one at
# vendor/bin/ffmpeg.
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

[[ -x "$vendor/ffmpeg" ]] || echo "NOTE: vendor/bin/ffmpeg is missing. See the comment at the top of this script."
