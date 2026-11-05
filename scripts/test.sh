#!/bin/zsh
# Runs the mixer tests, which need no audio hardware or permissions.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
clang -O2 -ISources/CMixer/include Sources/CMixer/CMixer.c Tests/mixer-test.c -framework CoreAudio -o "$OUT/mixer-test"
"$OUT/mixer-test"
