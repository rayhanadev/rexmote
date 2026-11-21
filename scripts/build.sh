#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
identity="${REXMOTE_SIGNING_IDENTITY:-${1:-}}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | awk '/"Apple Development:|"Developer ID Application:/ && !found { print $2; found=1 }')"
  identity="${identity:--}"
fi
swift build -c release
binaries="$(swift build -c release --show-bin-path)"
dist="$PWD/dist"
mkdir -p "$dist"
staging="$(mktemp -d "$dist/.rexmote-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Rexmote.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ln -s ../MacOS/rexmote "$app/Contents/Resources/rexmote-pane"
cp Notices/rexweb-LICENSE "$app/Contents/Resources/rexweb-LICENSE"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$binaries/rexmote" "$app/Contents/MacOS/rexmote-viewer"
cp "$binaries/rexmote" "$app/Contents/MacOS/rexmote"
host="$app/Contents/Helpers/Rexmote Host.app"
mkdir -p "$host/Contents/MacOS"
cp Resources/Host-Info.plist "$host/Contents/Info.plist"
cp "$binaries/rexmote-host" "$host/Contents/MacOS/rexmote-host"
codesign --force --sign "$identity" "$host"
codesign --force --sign "$identity" --identifier dev.rexmote.cli "$app/Contents/MacOS/rexmote"
codesign --force --sign "$identity" "$app"
codesign --verify --strict --deep "$app"
if [[ -e "$dist/Rexmote.app" ]]; then mv "$dist/Rexmote.app" "$staging/previous.bundle"; fi
if ! mv "$app" "$dist/Rexmote.app"; then
  if [[ -d "$staging/previous.bundle" ]]; then mv "$staging/previous.bundle" "$dist/Rexmote.app"; fi
  exit 1
fi
printf 'Built and signed: %s\n' "$dist/Rexmote.app"
