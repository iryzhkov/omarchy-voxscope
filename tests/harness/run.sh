#!/bin/bash
# Visual test harness for Voxscope.
#
# Usage: tests/harness/run.sh <scenario>
#
# Runs Hud.qml in a standalone Quickshell against a scratch runtime
# directory, plays a scripted dictation into it (the Voxtype state file,
# postprocess.json and a fake audio bridge), and saves frames of the card
# and a log of the HUD's state. Nothing outside the scratch directory is
# touched; Voxtype itself is never contacted.
#
# Scenarios (see shell.qml): pipeline, fastidle, relinger, noscript,
# silence, cap, cava, suppressed, latemarker, stale, latedir.
# "cava" points PipeWire and Pulse at the real session so cava can listen
# to the default microphone. "stale" takes about 35 s.
#
# Output goes to $VOXSCOPE_TEST_DIR/<scenario> (default
# ~/.cache/voxscope-test/<scenario>): frames/*.png and log.txt.
#
# The HUD's overlay appears on the focused screen while it runs. It takes
# no keyboard focus and lets clicks through.

set -euo pipefail

scenario=${1:-}
case $scenario in
  pipeline | fastidle | relinger | noscript | silence | cap | cava | suppressed | latemarker | stale | latedir) ;;
  *)
    echo "usage: $0 pipeline|fastidle|relinger|noscript|silence|cap|cava|suppressed|latemarker|stale|latedir" >&2
    exit 2
    ;;
esac

here=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
base=${VOXSCOPE_TEST_DIR:-$HOME/.cache/voxscope-test}
run=$base/$scenario
real_runtime=${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}
wayland=$real_runtime/${WAYLAND_DISPLAY:?WAYLAND_DISPLAY is not set}

rm -rf -- "$run"
mkdir -p -- "$run/app" "$run/runtime/voxtype" "$run/state/omarchy/current/theme" \
  "$run/config/voxtype" "$run/frames"
chmod 700 "$run/runtime"

# The plugin and the harness side by side, so the harness can use Hud.qml
# without importing from outside its own directory.
cp -- "$repo"/*.qml "$repo"/*.js "$repo/cava.conf" "$run/app/"
cp -- "$here/shell.qml" "$run/app/shell.qml"

theme=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/theme/colors.toml
if [[ -f $theme ]]; then
  cp -- "$theme" "$run/state/omarchy/current/theme/colors.toml"
fi

if [[ $scenario == cap ]]; then
  printf '[audio]\nmax_duration_secs = 12\n' >"$run/config/voxtype/config.toml"
fi
if [[ $scenario == stale ]]; then
  printf '[audio]\nmax_duration_secs = 1\n' >"$run/config/voxtype/config.toml"
fi

# Hyprland's IPC socket cannot be reached from here: its path under the
# scratch runtime is longer than a Unix socket path may be. Without it the
# HUD falls back to the first screen.
#
# For cava, PipeWire and Pulse are pointed at the real sockets instead.
audio_env=()
if [[ $scenario == cava ]]; then
  audio_env=(PIPEWIRE_RUNTIME_DIR="$real_runtime" PULSE_SERVER="unix:$real_runtime/pulse/native")
fi

# "latedir" starts without Voxtype's runtime directory; the harness creates
# it.
if [[ $scenario == latedir ]]; then
  rmdir -- "$run/runtime/voxtype"
else
  printf 'idle' >"$run/runtime/voxtype/state"
fi

status=0
env "${audio_env[@]}" XDG_RUNTIME_DIR="$run/runtime" WAYLAND_DISPLAY="$wayland" \
  XDG_STATE_HOME="$run/state" XDG_CONFIG_HOME="$run/config" \
  HARNESS_SCENARIO="$scenario" HARNESS_OUT="$run/frames" \
  HARNESS_BRIDGE="$here/fake-bridge.py" \
  timeout 40 quickshell -p "$run/app/shell.qml" >"$run/log.txt" 2>&1 || status=$?

echo "$scenario: exit $status, output in $run"
sed -E 's/\x1b\[[0-9;]*m//g' "$run/log.txt" | grep -E 'qml: (FRAME|CHECK|FAIL|WINDOW)' | sed -E 's/.*qml: /  /' || true
