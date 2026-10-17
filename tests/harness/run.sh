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
# silence, cap, cava, quiet, loud, suppressed, suppressedrelinger,
# oldmarker, latemarker, nobridge, stale, latedir.
# "cava" points PipeWire and Pulse at the real session so cava can listen
# to the default microphone. "quiet" and "loud" feed the spectrum from
# fake-cava.py instead; "quiet" starts from a saved calibration left high
# by an earlier, louder session. "stale" takes about 35 s.
#
# Output goes to $VOXSCOPE_TEST_DIR/<scenario> (default
# ~/.cache/voxscope-test/<scenario>): frames/*.png and log.txt.
#
# Optional environment:
#   VOXSCOPE_THEME       a stock Omarchy theme name, such as tokyo-night,
#                        or the path of a colors.toml; the HUD is coloured
#                        from it instead of the active theme, which is left
#                        alone
#   VOXSCOPE_SETTINGS    a JSON object of plugin settings, as they would
#                        appear on the plugin's entry in shell.json, for
#                        example '{"compact": true}'
#   VOXSCOPE_PLUGIN_DIR  where to take the plugin's files from instead of
#                        this checkout, for example an export of an older
#                        commit to compare against
#
# The HUD's overlay appears on the focused screen while it runs. It takes
# no keyboard focus and lets clicks through.

set -euo pipefail

scenario=${1:-}
case $scenario in
  pipeline | fastidle | relinger | noscript | silence | cap | cava | quiet | loud | suppressed | suppressedrelinger | oldmarker | latemarker | nobridge | stale | latedir) ;;
  *)
    echo "usage: $0 pipeline|fastidle|relinger|noscript|silence|cap|cava|quiet|loud|suppressed|suppressedrelinger|oldmarker|latemarker|nobridge|stale|latedir" >&2
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
plugin=${VOXSCOPE_PLUGIN_DIR:-$repo}
cp -- "$plugin"/*.qml "$plugin"/*.js "$plugin/cava.conf" "$run/app/"
cp -- "$here/shell.qml" "$run/app/shell.qml"

theme=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/theme/colors.toml
if [[ -n ${VOXSCOPE_THEME:-} ]]; then
  if [[ $VOXSCOPE_THEME == */* ]]; then
    theme=$VOXSCOPE_THEME
  elif [[ $VOXSCOPE_THEME =~ ^[a-z0-9-]+$ ]]; then
    theme=/usr/share/omarchy/themes/$VOXSCOPE_THEME/colors.toml
  else
    echo "$0: bad theme name: $VOXSCOPE_THEME" >&2
    exit 2
  fi
  if [[ ! -f $theme ]]; then
    echo "$0: no such theme: $theme" >&2
    exit 2
  fi
fi
if [[ -f $theme ]]; then
  cp -- "$theme" "$run/state/omarchy/current/theme/colors.toml"
fi

if [[ $scenario == cap ]]; then
  printf '[audio]\nmax_duration_secs = 12\n' >"$run/config/voxtype/config.toml"
fi
if [[ $scenario == stale ]]; then
  printf '[audio]\nmax_duration_secs = 1\n' >"$run/config/voxtype/config.toml"
fi
if [[ $scenario == quiet ]]; then
  mkdir -p -- "$run/state/voxscope"
  python3 -I -c 'import json, sys; print(json.dumps({"version": 1, "ref": [0.3] * 32, "noise": [0.002] * 32}))' \
    >"$run/state/voxscope/calibration.json"
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
  HARNESS_BRIDGE="$here/fake-bridge.py" HARNESS_SETTINGS="${VOXSCOPE_SETTINGS:-}" \
  HARNESS_CAVA="$scenario" HARNESS_FAKE_CAVA="$here/fake-cava.py" \
  timeout 40 quickshell -p "$run/app/shell.qml" >"$run/log.txt" 2>&1 || status=$?

echo "$scenario: exit $status, output in $run"
sed -E 's/\x1b\[[0-9;]*m//g' "$run/log.txt" | grep -E 'qml: (FRAME|CHECK|FAIL|WINDOW|LIVE|HOLD)' | sed -E 's/.*qml: /  /' || true
