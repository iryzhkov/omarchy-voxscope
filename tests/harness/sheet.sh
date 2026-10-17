#!/bin/bash
# Contact sheet of the HUD mid-pipeline across stock Omarchy themes.
#
# Usage: tests/harness/sheet.sh <output dir>
#
# Runs the "pipeline" scenario of run.sh once per theme, coloured from that
# theme's colors.toml (the active theme is left alone), and puts the
# recording, STT scan, LLM scan and typing frames side by side, one row per
# theme, in <output dir>/sheet.png. Unless SHEET_VARIANTS=0 it also runs the
# compact, reduced-motion and bottom-position settings and writes
# <output dir>/variants.png, with the card placed on the theme's wallpaper
# where Hyprland reports the overlay to be, for the two positions.
#
# Environment:
#   SHEET_THEMES         theme names, space-separated (default: tokyo-night
#                        catppuccin gruvbox nord flexoki-light
#                        catppuccin-latte)
#   SHEET_VARIANTS       0 to skip the settings variants
#   VOXSCOPE_PLUGIN_DIR  passed to run.sh, to draw an older copy of the
#                        plugin
#
# Needs ImageMagick (magick), and hyprctl for the placement frames.

set -euo pipefail

out=${1:?usage: $0 <output dir>}
here=$(cd -- "$(dirname -- "$0")" && pwd)
themes=${SHEET_THEMES:-tokyo-night catppuccin gruvbox nord flexoki-light catppuccin-latte}
mkdir -p -- "$out"
out=$(cd -- "$out" && pwd)

# The frames of one run, in pipeline order.
frames_of() {
  local dir=$1/pipeline/frames
  local label
  for label in rec stt llm-late typing; do
    local f=("$dir"/*-"$label".png)
    [[ -f ${f[0]} ]] || { echo "$0: no $label frame in $dir" >&2; exit 1; }
    printf '%s\n' "${f[0]}"
  done
}

# Runs the pipeline into $out/runs/<name> with the given theme and settings,
# and records where Hyprland places the overlay 1.5 s in, while it records.
run_one() {
  local name=$1 theme=$2 settings=$3
  local dir=$out/runs/$name
  VOXSCOPE_THEME=$theme VOXSCOPE_SETTINGS=$settings VOXSCOPE_TEST_DIR=$dir \
    "$here/run.sh" pipeline >"$out/runs-$name.txt" 2>&1 &
  local pid=$!
  sleep 1.5
  if command -v hyprctl >/dev/null; then
    hyprctl layers -j >"$out/runs-$name-layers.json" 2>/dev/null || true
    hyprctl monitors -j >"$out/runs-$name-monitors.json" 2>/dev/null || true
  fi
  wait "$pid"
  if grep -q 'FAIL' "$out/runs-$name.txt"; then
    echo "$name: the harness reported a failure; see $out/runs-$name.txt" >&2
  fi
}

# A row of frames with a caption under each.
row() {
  local dest=$1 caption=$2
  shift 2
  local args=()
  local f
  for f in "$@"; do
    args+=(-label "$caption  $(basename -- "$f" .png | sed -E 's/^[0-9]+-//')" "$f")
  done
  magick montage -background '#16161a' -fill '#c8c8d0' -pointsize 30 \
    "${args[@]}" -tile x1 -geometry +10+10 "$dest"
}

rows=()
for theme in $themes; do
  run_one "$theme" "$theme" '{}'
  mapfile -t files < <(frames_of "$out/runs/$theme")
  row "$out/row-$theme.png" "$theme" "${files[@]}"
  rows+=("$out/row-$theme.png")
done
magick "${rows[@]}" -background '#16161a' -append "$out/sheet.png"
echo "sheet: $out/sheet.png"

[[ ${SHEET_VARIANTS:-1} == 0 ]] && exit 0

# The card on the theme's wallpaper, where Hyprland put the overlay, at half
# the screen's logical size.
placement() {
  local name=$1 theme=$2
  local frame wallpaper geometry
  frame=$(frames_of "$out/runs/$name" | head -n 1)
  wallpaper=$(find "/usr/share/omarchy/themes/$theme/backgrounds" -maxdepth 1 -type f | sort | head -n 1)
  [[ -n $wallpaper && -s $out/runs-$name-layers.json ]] || return 1
  geometry=$(python3 -I - "$out/runs-$name-layers.json" "$out/runs-$name-monitors.json" <<'EOF'
import json, sys
layers = json.load(open(sys.argv[1]))
monitors = {m["name"]: m for m in json.load(open(sys.argv[2]))}
for name, mon in layers.items():
    for surfaces in mon.get("levels", {}).values():
        for s in surfaces:
            if s.get("namespace") == "voxscope":
                m = monitors[name]
                w = round(m["width"] / m["scale"])
                h = round(m["height"] / m["scale"])
                print(w, h, s["x"] - m["x"], s["y"] - m["y"], s["w"], s["h"])
                sys.exit(0)
sys.exit(1)
EOF
  ) || return 1
  local sw sh lx ly lw lh
  read -r sw sh lx ly lw lh <<<"$geometry"
  # The overlay is the card with a 40 px margin all round (Hud.qml), in
  # logical pixels; everything is drawn at half that.
  magick \( "$wallpaper" -resize "$((sw / 2))x$((sh / 2))^" -gravity center -extent "$((sw / 2))x$((sh / 2))" \) \
    \( "$frame" -resize "$(((lw - 80) / 2))x$(((lh - 80) / 2))!" \) \
    -gravity northwest -geometry "+$(((lx + 40) / 2))+$(((ly + 40) / 2))" \
    -composite "$out/placement-$name.png"
  printf '%s\n' "$out/placement-$name.png"
}

run_one compact tokyo-night '{"compact": true}'
run_one reduced tokyo-night '{"reducedMotion": true}'
run_one bottom catppuccin-latte '{"position": "bottom"}'
run_one centre catppuccin-latte '{}'
row_files=()
for name in compact reduced; do
  mapfile -t files < <(frames_of "$out/runs/$name")
  row "$out/row-$name.png" "tokyo-night $name" "${files[@]}"
  row_files+=("$out/row-$name.png")
done
placed=()
for name in centre bottom; do
  if p=$(placement "$name" catppuccin-latte); then
    placed+=(-label "catppuccin-latte position $name (Hyprland's placement)" "$p")
  else
    echo "$name: no placement recorded" >&2
  fi
done
if ((${#placed[@]} > 0)); then
  magick montage -background '#16161a' -fill '#c8c8d0' -pointsize 30 \
    "${placed[@]}" -tile x1 -geometry +10+10 "$out/row-placement.png"
  row_files+=("$out/row-placement.png")
fi
magick "${row_files[@]}" -background '#16161a' -append "$out/variants.png"
echo "variants: $out/variants.png"
