#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec /usr/bin/python3 "$SCRIPT_DIR/install_safety.py" install "$@"
