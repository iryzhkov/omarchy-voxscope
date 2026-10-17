#!/bin/bash

# The cava.conf template carries the gain the spectrum was tuned to on real
# speech (e829b18) and the placeholder Hud.qml fills in; spectrum.js is tuned
# against both, so a change to either has to be deliberate.

set -uo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
conf=$PROJECT_DIR/cava.conf
failures=0

expect() { # key value
  if grep -qxE "$1 = $2" "$conf"; then
    echo "PASS   : cava-conf::$1"
  else
    echo "FAIL!  : cava-conf::$1 -- expected '$1 = $2'"
    failures=$((failures + 1))
  fi
}

expect sensitivity 3000
expect autosens 0
expect bars 32
expect source @SOURCE@
expect method raw
expect data_format ascii
expect ascii_max_range 1000
expect bar_delimiter 59
expect frame_delimiter 10

# Hud.qml reads at most 4 KiB of the template.
size=$(wc -c <"$conf")
if ((size <= 4096)); then
  echo "PASS   : cava-conf::size"
else
  echo "FAIL!  : cava-conf::size -- $size bytes, over the 4096 Hud.qml reads"
  failures=$((failures + 1))
fi

echo "Totals: $((10 - failures)) passed, $failures failed (cava-conf.sh)"
exit $((failures > 0))
