#!/usr/bin/env bash
# Удобный wrapper: сначала установка, затем один замер.
# Для повторных запусков используй ubuntu26-run.sh напрямую.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$DIR/ubuntu26-install.sh"
bash "$DIR/ubuntu26-run.sh" "$@"
