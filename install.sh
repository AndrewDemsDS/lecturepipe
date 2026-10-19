#!/usr/bin/env bash
# Install lecturepipe for the current user: symlinks into ~/.local/bin, the
# systemd user units, then the setup wizard.
#
#   ./install.sh              install + run lecture-setup
#   ./install.sh --no-setup   install only
#   PREFIX=~/.local ./install.sh
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SETUP=1
[[ "${1:-}" == "--no-setup" ]] && SETUP=0

mkdir -p "$BIN" "$UNITS"
for f in "$HERE"/bin/lecture-*; do
  ln -sfn "$f" "$BIN/$(basename "$f")"
done
echo "✔ commands linked into $BIN"
for u in lecture-watch.path lecture-watch.service; do
  install -m 644 "$HERE/systemd/$u" "$UNITS/$u"
done
# The service finds lecture-watch through PATH; make sure $BIN is on it.
sed -i "s|^Environment=PATH=.*|Environment=PATH=$BIN:/usr/local/bin:/usr/bin:/bin|" "$UNITS/lecture-watch.service"
echo "✔ systemd user units installed (not armed yet)"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "! $BIN is not on your PATH. Add to your shell rc:"
     echo "    export PATH=\"$BIN:\$PATH\"" ;;
esac

if [[ "$SETUP" == 1 ]]; then
  echo
  exec "$BIN/lecture-setup"
else
  echo "Run lecture-setup when ready."
fi
