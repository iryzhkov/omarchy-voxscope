#!/bin/bash
# Publishing assets: the hero screenshot and the demo GIF.
#
# Usage: tests/harness/capture.sh [output dir]   (default: the repository)
#
# Runs the "demo" scenario of run.sh, coloured from a stock Omarchy theme's
# colors.toml (the active theme is left alone), which saves the whole
# overlay window about fifteen times a second on a transparent background,
# and one "hero" frame in the middle of the LLM scan. Then it composites:
#
#   preview.png  1600x900, the hero frame on one of the theme's own
#                wallpapers, the card at 58 % of the width, so it still
#                reads at the marketplace's 720-pixel card size
#   demo.gif     800x440, one whole dictation (recording, the STT scan, the
#                LLM scan, typing, the fade) on the same wallpaper, cropped
#                closer, looping
#
# Environment:
#   CAPTURE_THEME      stock theme name (default tokyo-night)
#   CAPTURE_WALLPAPER  file name in that theme's backgrounds/ (default
#                      0-winding-road.webp)
#   CAPTURE_WORK       scratch directory (default
#                      ~/.cache/voxscope-capture), wiped first
#
# Needs ImageMagick (magick) and ffmpeg. The frames are drawn at the
# focused screen's scale; they are resized to the sizes above, so a scale
# near 1.6 gives the sharpest result.

set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
out=${1:-$repo}
theme=${CAPTURE_THEME:-tokyo-night}
wallpaper=/usr/share/omarchy/themes/$theme/backgrounds/${CAPTURE_WALLPAPER:-0-winding-road.webp}
home=${HOME:?HOME is not set}
work=${CAPTURE_WORK:-$home/.cache/voxscope-capture}

[[ $theme =~ ^[a-z0-9-]+$ ]] || { echo "$0: bad theme name: $theme" >&2; exit 2; }
[[ -f $wallpaper ]] || { echo "$0: no such wallpaper: $wallpaper" >&2; exit 2; }
# The scratch directory is wiped, so it must be somewhere of this user's own
# under the home directory, and not the home directory itself.
case $work in
  "$home"/?*) ;;
  *) echo "$0: CAPTURE_WORK must be under $home: $work" >&2; exit 2 ;;
esac
[[ $work != *..* ]] || { echo "$0: CAPTURE_WORK must not contain ..: $work" >&2; exit 2; }

rm -rf -- "$work"
mkdir -p -- "$work/comp" "$out"

VOXSCOPE_THEME=$theme VOXSCOPE_SETTINGS='{}' VOXSCOPE_TEST_DIR=$work/runs "$here/run.sh" demo >"$work/run.txt"
frames=$work/runs/demo/frames
if grep -q FAIL "$work/run.txt" || [[ ! -f $frames/hero.png ]]; then
  cat "$work/run.txt" >&2
  echo "$0: the demo run failed; see $work/runs/demo/log.txt" >&2
  exit 1
fi

# The window is the card plus 40 logical pixels all round (Hud.qml), 660
# logical pixels wide, and the card is 580 of them.
window_px=$(magick identify -format '%w' "$frames/hero.png")

# The hero: the card 928 pixels wide (58 % of 1600).
hero_scale=$(awk -v w="$window_px" 'BEGIN { printf "%.4f", 928 * 660 / 580 / w * 100 }')
magick \( "$wallpaper" -resize 1600x900^ -gravity center -extent 1600x900 \) \
  \( "$frames/hero.png" -resize "$hero_scale%" \) -gravity center -composite \
  -strip -define png:compression-level=9 "$out/preview.png"

# The GIF: the same wallpaper at 65 % of the hero, cropped round the card.
gif_scale=$(awk -v s="$hero_scale" 'BEGIN { printf "%.4f", s * 0.65 }')
magick \( "$wallpaper" -resize 1600x900^ -gravity center -extent 1600x900 \) -resize 1040x585 \
  -gravity center -crop 800x440+0+0 +repage "$work/comp/base.png"

# The harness saves a frame every 66 ms (demoFrameMs in shell.qml), and in
# practice nearly every gap is 65 to 67 ms, so the GIF plays them at that
# fixed rate. The loop opens on the bare wallpaper for 0.4 s and closes on
# it for 0.8 s, as repeated frames, which cost next to nothing in a GIF.
mapfile -t demo_frames < <(find "$frames" -maxdepth 1 -name 'demo-*.png' | sort)
((${#demo_frames[@]} > 10)) || { echo "$0: only ${#demo_frames[@]} demo frames" >&2; exit 1; }
n=0
hold() { # count
  local i
  for ((i = 0; i < $1; i++)); do
    cp -- "$work/comp/base.png" "$work/comp/f$(printf '%04d' "$n").png"
    n=$((n + 1))
  done
}
hold 6
for f in "${demo_frames[@]}"; do
  magick "$work/comp/base.png" \( "$f" -resize "$gif_scale%" \) -gravity center -composite \
    "$work/comp/f$(printf '%04d' "$n").png"
  n=$((n + 1))
done
hold 12

ffmpeg -loglevel error -y -framerate 1000/66 -i "$work/comp/f%04d.png" \
  -vf "split[a][b];[a]palettegen=max_colors=96:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 "$out/demo.gif"

echo "preview: $out/preview.png ($(stat -c %s "$out/preview.png") bytes)"
echo "demo:    $out/demo.gif ($(stat -c %s "$out/demo.gif") bytes, ${#demo_frames[@]} frames)"
