#!/bin/bash
# Installs omarchy-backup: symlinks the CLI into ~/.local/bin, writes default
# config/paths files, and (optionally) installs the systemd --user timers.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_TARGET="$HOME/.local/bin/omarchy-backup"

mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT_DIR/bin/omarchy-backup" "$BIN_TARGET"
echo "Linked $BIN_TARGET -> $ROOT_DIR/bin/omarchy-backup"

"$ROOT_DIR/bin/omarchy-backup" init

case "${1:-}" in
  --with-timers)
    "$ROOT_DIR/bin/omarchy-backup" timers install
    ;;
  *)
    echo
    echo "Not installing automatic timers yet. Review ~/.config/omarchy-backup/config.conf"
    echo "then run: omarchy-backup timers install"
    ;;
esac

echo
echo "Done. Try: omarchy-backup snapshot --baseline my-good-state"
