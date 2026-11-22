#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-}" in ""|--host-only) ;; *) echo 'Usage: ./uninstall.sh [--host-only]' >&2; exit 2;; esac
app="${REXMOTE_APP_DIR:-$HOME/Applications}/Rexmote.app"
bin="${REXMOTE_BIN_DIR:-$HOME/.local/bin}/rexmote"
if [[ -e "$app" ]]; then
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$identifier" != dev.rexmote.viewer && "$identifier" != dev.rex-pixel.screen-host ]]; then
    echo "An unrelated app exists at $app." >&2; exit 1
  fi
fi
/usr/bin/python3 scripts/rex-config.py "remove${1:+-host}" "$app/Contents/MacOS/rexmote" remove "$app"
if [[ -L "$bin" && "$(readlink "$bin")" == "$app/Contents/MacOS/rexmote" ]]; then rm "$bin"; fi
if [[ -d "$app" ]]; then rm -r "$app"; fi
echo 'Removed rexmote.'
