#!/usr/bin/env bash
set -euo pipefail
MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export PYTHONDONTWRITEBYTECODE=1
exec python3 -I "$MODULE_DIR/module.py" "$@"
