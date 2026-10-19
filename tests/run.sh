#!/usr/bin/env bash
# All checks: shellcheck, python syntax, bats.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
shellcheck -x bin/* lib/common.sh install.sh uninstall.sh
python3 -m py_compile lib/*.py
bats tests/
