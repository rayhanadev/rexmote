#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-}" in ""|--host-only) ;; *) echo 'Usage: ./install.sh [--host-only]' >&2; exit 2;; esac
bin="${REXMOTE_BIN_DIR:-$HOME/.local/bin}"
scripts/build.sh
if [[ "${1:-}" == --host-only ]]; then
  scripts/install.sh "$PWD/dist/Rexmote.app" "$bin" --host-only
else
  scripts/install.sh "$PWD/dist/Rexmote.app" "$bin" --with-rex
  echo 'Open Remote Desktop Pane is available in the Rex command palette.'
fi
