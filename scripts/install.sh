#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
source_app="${1:-$root/dist/Rexmote.app}"
bin_dir="${2:-$HOME/.local/bin}"
app_dir="${REXMOTE_APP_DIR:-$HOME/Applications}"
app="$app_dir/Rexmote.app"
link="$bin_dir/rexmote"
binary="$app/Contents/MacOS/rexmote"
[[ -x "$source_app/Contents/MacOS/rexmote" ]] || { echo "Missing built app: $source_app" >&2; exit 1; }
codesign --verify --strict --deep "$source_app"
mkdir -p "$app_dir" "$bin_dir"

if [[ -e "$link" || -L "$link" ]] && [[ "$(readlink "$link" || true)" != "$binary" ]]; then
  echo "Another command already exists at $link. Choose another bin directory." >&2
  exit 1
fi
if [[ -e "$app" || -L "$app" ]]; then
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -L "$app" || ! -x "$binary" || ( "$identifier" != dev.rexmote.viewer && "$identifier" != dev.rex-pixel.screen-host ) ]]; then
    echo "Another application already exists at $app." >&2
    exit 1
  fi
fi

staging="$(mktemp -d "$app_dir/.rexmote-install.XXXXXX")"
previous=""
installed=false
linked=false
finish() {
  result=$?
  if [[ "$result" != 0 ]]; then
    if "$linked"; then rm "$link"; fi
    if "$installed"; then mv "$app" "$staging/failed.bundle"; fi
    if [[ -n "$previous" && -d "$previous" ]]; then mv "$previous" "$app"; fi
  fi
  rm -rf "$staging"
  exit "$result"
}
trap finish EXIT

ditto "$source_app" "$staging/Rexmote.app"
codesign --verify --strict --deep "$staging/Rexmote.app"
if [[ -d "$app" ]]; then
  backup="${REXMOTE_BACKUP_DIR:-$HOME/Library/Application Support/rexmote/backups}/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$backup"
  chmod 700 "$backup"
  previous="$backup/previous.bundle"
  mv "$app" "$previous"
fi
mv "$staging/Rexmote.app" "$app"
installed=true
if [[ ! -L "$link" ]]; then
  ln -s "$binary" "$link"
  linked=true
fi
if [[ "${3:-}" == --with-rex ]]; then
  /usr/bin/python3 "$root/scripts/rex-config.py" install "$binary" install "$app" "$previous"
elif [[ "${3:-}" == --host-only ]]; then
  /usr/bin/python3 "$root/scripts/rex-config.py" install-host "$binary" update-host "$app" "$previous"
fi
printf 'Installed %s\nCommand %s\n' "$app" "$link"
case ":$PATH:" in *":$bin_dir:"*) ;; *) printf 'Add %s to PATH to type rexmote from your shell.\n' "$bin_dir";; esac
