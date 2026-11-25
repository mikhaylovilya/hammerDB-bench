#!/usr/bin/env bash
# Удобный wrapper: сначала установка, затем один замер.
# Для повторных запусков используй rhel103-run.sh напрямую.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$DIR/rhel103-install.sh"
bash "$DIR/rhel103-run.sh" "$@"
