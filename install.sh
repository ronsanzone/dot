#!/usr/bin/env bash
set -euo pipefail

DOT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/bin"
ln -sfn "$DOT_ROOT/bin/dot" "$HOME/bin/dot"

printf '[dot] installed %s\n' "$HOME/bin/dot"
