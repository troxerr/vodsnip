#!/bin/zsh
# Builds a distributable dist/Vodsnip-<version>.dmg.
#
#   1. builds the release binary and assembles dist/Vodsnip.app
#   2. copies vendor/bin/{yt-dlp,ffmpeg} into Contents/Resources/bin (see tools/fetch_vendor.sh)
#   3. signs every binary with the hardened runtime, then the app
#   4. notarizes and staples the app, builds the DMG, signs, notarizes and staples that too
#
# Environment:
#   DEVELOPER_ID    "Developer ID Application: Your Name (TEAMID)". Found in the keychain when unset.
#   NOTARY_PROFILE  a notarytool keychain profile, made once with:
#                     xcrun notarytool store-credentials vodsnip-notary \
#                       --apple-id you@example.com --team-id TEAMID --password <app-specific password>
#   Without both, the script still builds a DMG, signed ad hoc and not notarized. That runs on this Mac only.
set -euo pipefail

here=${0:A:h:h}
name="Vodsnip"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$here/Info.plist.in")
scratch="$HOME/Library/Developer/$name/build"
dist="$here/dist"
app="$dist/$name.app"
dmg="$dist/$name-$version.dmg"
vendor="$here/vendor/bin"

identity="${DEVELOPER_ID:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)
fi
notary="${NOTARY_PROFILE:-}"
release=1
if [[ -z "$identity" || -z "$notary" ]]; then
  release=0
  identity=-
  echo "NOTE: no Developer ID certificate or NOTARY_PROFILE: building an ad hoc signed DMG for this Mac only."
fi

step() { echo "==> $*"; }

# 1. Build and assemble.
step "Building"
swift build -c release --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error|Build complete" || true
bin="$scratch/release/$name"
[[ -x "$bin" ]] || { echo "build failed"; exit 1; }

rm -rf "$dist"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
[[ -f "$here/Resources/Assets.car" ]] || "$here/tools/make_icon.sh"
cp -X "$here/Resources/Assets.car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"

# 2. Bundle the tools. A product that tells customers to run Homebrew is not shippable.
if [[ -x "$vendor/yt-dlp" && -x "$vendor/ffmpeg" ]]; then
  step "Bundling yt-dlp and ffmpeg"
  mkdir -p "$app/Contents/Resources/bin"
  cp -X "$vendor/yt-dlp" "$vendor/ffmpeg" "$app/Contents/Resources/bin/"
elif [[ "$release" == 1 ]]; then
  echo "ERROR: vendor/bin/yt-dlp and vendor/bin/ffmpeg are missing. Run tools/fetch_vendor.sh first."
  exit 1
else
  echo "NOTE: vendor/bin has no tools, so this build relies on Homebrew's yt-dlp and ffmpeg."
fi

# 3. Sign inside out: nested binaries first, then the app.
step "Signing ($identity)"
xattr -cr "$app"
flags=(--force --sign "$identity")
[[ "$release" == 1 ]] && flags+=(--options runtime --timestamp)
if [[ -d "$app/Contents/Resources/bin" ]]; then
  for tool in "$app"/Contents/Resources/bin/*; do
    codesign "${flags[@]}" --entitlements "$here/tools/vendor.entitlements" "$tool"
  done
fi
codesign "${flags[@]}" "$app"
codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | tail -2

notarize() {  # notarize <file> : submit, wait, fail loudly with the log
  local file=$1 out
  out=$(xcrun notarytool submit "$file" --keychain-profile "$notary" --wait 2>&1) || { echo "$out"; exit 1; }
  echo "$out" | tail -4
  if ! echo "$out" | grep -q "status: Accepted"; then
    local id; id=$(echo "$out" | grep -m1 "id:" | awk '{print $2}')
    xcrun notarytool log "$id" --keychain-profile "$notary" || true
    echo "ERROR: notarization was not accepted"; exit 1
  fi
}

# 4a. Notarize and staple the app (so it also works once dragged out of the DMG).
if [[ "$release" == 1 ]]; then
  step "Notarizing the app"
  zip="$dist/$name-notarize.zip"
  ditto -c -k --keepParent "$app" "$zip"
  notarize "$zip"
  rm -f "$zip"
  xcrun stapler staple "$app"
fi

# 4b. The DMG: the app next to an Applications shortcut.
step "Building the DMG"
stage=$(mktemp -d)
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "$name" -srcfolder "$stage" -ov -format UDZO "$dmg"
rm -rf "$stage"
dmgflags=(--force --sign "$identity")
[[ "$release" == 1 ]] && dmgflags+=(--timestamp)
codesign "${dmgflags[@]}" "$dmg"

if [[ "$release" == 1 ]]; then
  step "Notarizing the DMG"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  step "Gatekeeper check"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg" 2>&1 | tail -2
  spctl --assess --type execute --verbose=2 "$app" 2>&1 | tail -2
fi

echo "done: $dmg ($(du -h "$dmg" | cut -f1))"
