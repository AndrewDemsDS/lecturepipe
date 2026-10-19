#!/usr/bin/env bash
# Remove the symlinks and units install.sh created. Recordings, transcripts,
# models and the config file are left alone.
set -euo pipefail
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
systemctl --user disable --now lecture-watch.path lecture-pending.timer 2>/dev/null || true
rm -f "$UNITS/lecture-watch.path" "$UNITS/lecture-watch.service" "$UNITS/lecture-pending.timer" "$UNITS/lecture-pending.service"
systemctl --user daemon-reload 2>/dev/null || true
for f in "$BIN"/lecture-*; do [[ -L "$f" ]] && rm -f "$f"; done
echo "✔ lecturepipe removed. Config kept at ${XDG_CONFIG_HOME:-$HOME/.config}/lecturepipe/config"
