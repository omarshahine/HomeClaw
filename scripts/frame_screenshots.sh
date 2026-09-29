#!/usr/bin/env bash
# Composite raw window-grab screenshots into framed App Store screenshots
# (gradient backdrop + rounded screenshot + drop shadow + tagline).
#
# Inputs:  appstore/screenshots/en-US/*.png (bare 2880x1800 window grabs)
# Outputs: appstore/framed/en-US/*.png      (App Store ready; what
#          `scripts/release.sh upload-screenshots` uploads)
#
# Usually run as `scripts/release.sh frame`.
#
# Override per-file taglines by exporting `HC_TAGLINES_FILE=<path>` to a
# `basename<TAB>tagline` TSV. Otherwise the defaults below are used.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${SRC_DIR:-$REPO_ROOT/appstore/screenshots/en-US}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/appstore/framed/en-US}"
CANVAS_W=2880
CANVAS_H=1800
SHOT_W=2200          # ~76% of canvas width
CORNER_RADIUS=40
GRADIENT_TOP="#2c3e50"
GRADIENT_BOT="#4ca1af"
TAGLINE_FONT="/System/Library/Fonts/SFNS.ttf"
TAGLINE_SIZE=92
TAGLINE_COLOR="#ffffff"
TAGLINE_Y=120        # pixels from top
SHOT_Y_OFFSET=80     # downward offset from gravity-center placement

# Default taglines keyed by file basename (no .png). Edit freely.
# Implemented as a case statement so this script works on macOS's stock
# bash 3.2 (no `declare -A` available).
default_tagline() {
  case "$1" in
    01_Onboarding)    echo "Native HomeKit access on your Mac" ;;
    02_Settings_Home) echo "One place for every preference" ;;
    03_TUI)           echo "A terminal UI for power users" ;;
    04_CLI_List)      echo "Every accessory, one command away" ;;
    05_CLI_Toggle)    echo "Control anything from the command line" ;;
    *)                echo "HomeClaw" ;;
  esac
}

# Optional override file: TSV of `basename<TAB>tagline`. First matching line wins.
lookup_tagline() {
  local base="$1"
  if [[ -n "${HC_TAGLINES_FILE:-}" && -f "$HC_TAGLINES_FILE" ]]; then
    local line
    line=$(awk -F'\t' -v key="$base" '$1 == key {print $2; exit}' "$HC_TAGLINES_FILE")
    if [[ -n "$line" ]]; then
      echo "$line"
      return
    fi
  fi
  default_tagline "$base"
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
require_cmd magick

mkdir -p "$OUT_DIR"
TMP_DIR=$(mktemp -d -t homeclaw_frame.XXXXXX)
cleanup() { trash "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

# 1. Generate gradient backdrop once
BG="$TMP_DIR/bg.png"
magick -size "${CANVAS_W}x${CANVAS_H}" \
  "gradient:${GRADIENT_TOP}-${GRADIENT_BOT}" \
  "$BG"

# Returns 0 if the source already has a dark, baked-in window frame
# (e.g. CleanShot's "Background & shadow" mode) — sampled by checking that
# all four corner pixels are close to the same dark color. In that case we
# skip my added rounded-corner + drop-shadow steps so we don't double-frame.
is_preframed() {
  local src="$1"
  local w h tl tr bl br
  w=$(magick identify -format "%w" "$src")
  h=$(magick identify -format "%h" "$src")
  # Sample 50px inside each corner.
  tl=$(magick "$src" -format "%[fx:int(255*((r+g+b)/3)+.5)]" -define identify:sample-point="50,50" info: 2>/dev/null)
  # Fallback approach: use -crop + average, more reliable
  tl=$(magick "$src" -crop 40x40+10+10 +repage -resize 1x1 -format "%[fx:int(255*(r+g+b)/3+.5)]" info:)
  tr=$(magick "$src" -crop 40x40+$((w-50))+10 +repage -resize 1x1 -format "%[fx:int(255*(r+g+b)/3+.5)]" info:)
  bl=$(magick "$src" -crop 40x40+10+$((h-50)) +repage -resize 1x1 -format "%[fx:int(255*(r+g+b)/3+.5)]" info:)
  br=$(magick "$src" -crop 40x40+$((w-50))+$((h-50)) +repage -resize 1x1 -format "%[fx:int(255*(r+g+b)/3+.5)]" info:)
  # All four corners dark (<60 avg) → likely a pre-framed shot.
  if (( tl < 60 && tr < 60 && bl < 60 && br < 60 )); then
    return 0
  fi
  return 1
}

for src in "$SRC_DIR"/*.png; do
  [[ -e "$src" ]] || continue
  base=$(basename "$src" .png)
  tagline=$(lookup_tagline "$base")
  out="$OUT_DIR/$base.png"

  if is_preframed "$src"; then
    mode="pre-framed"
  else
    mode="raw"
  fi
  echo "Framing: $base ($mode) -> $(basename "$out")  [\"$tagline\"]"

  if [[ "$mode" == "pre-framed" ]]; then
    # The source has a baked-in dark CleanShot bezel + padding around the
    # actual macOS window. Cleanest fix: convert the bezel color directly
    # to transparent. The alpha channel then carries the macOS window's
    # native rounded corner shape — no mask hacks, no leftover pockets.
    # Bezel `(24,24,28)` is close in color to the Terminal body
    # `(34,39,51)` (~28 Euclidean distance in 8-bit space), so fuzz must
    # stay below 7% — at 7%+ the body itself goes transparent. 6% catches
    # bezel + antialiased curve pixels without touching real content.
    alpha="$TMP_DIR/${base}_alpha.png"
    magick "$src" -fuzz 6% -transparent "#18181c" +repage "$alpha"

    # `-trim` on the alpha image removes the transparent surround; what
    # remains is just the macOS window, with its real rounded corners
    # preserved as alpha (showing the backdrop through).
    trimmed="$TMP_DIR/${base}_trimmed.png"
    magick "$alpha" -trim +repage "$trimmed"

    resized="$TMP_DIR/${base}_resized.png"
    magick "$trimmed" -resize "${SHOT_W}x" "$resized"

    # Composite directly onto the gradient — the alpha channel does all
    # the corner-rounding work for us.
    magick "$BG" "$resized" \
      -gravity center -geometry "+0+${SHOT_Y_OFFSET}" -composite \
      -gravity north -fill "$TAGLINE_COLOR" \
      -font "$TAGLINE_FONT" -pointsize "$TAGLINE_SIZE" \
      -annotate "+0+${TAGLINE_Y}" "$tagline" \
      "$out"
    continue
  fi

  # Raw window grab — add rounded corners + drop shadow so the screenshot
  # reads as a discrete window on the gradient backdrop.
  resized="$TMP_DIR/${base}_resized.png"
  magick "$src" -resize "${SHOT_W}x" "$resized"

  # Build alpha mask via `roundrectangle` draw — cleaner than the
  # polygon+circle technique, which can leave a 1px sliver at the
  # antialiasing boundary and produce visible dark wedges in the
  # corners. `roundrectangle` is drawn at the same resolution as the
  # screenshot so the mask edges line up perfectly with the content.
  rw=$(magick identify -format "%w" "$resized")
  rh=$(magick identify -format "%h" "$resized")
  rounded="$TMP_DIR/${base}_rounded.png"
  magick "$resized" \
    \( -size "${rw}x${rh}" canvas:none \
       -fill white \
       -draw "roundrectangle 0,0 $((rw-1)),$((rh-1)) ${CORNER_RADIUS},${CORNER_RADIUS}" \) \
    -alpha off -compose CopyOpacity -composite \
    "$rounded"

  shadowed="$TMP_DIR/${base}_shadowed.png"
  magick "$rounded" \
    \( +clone -background black -shadow 65x30+0+25 \) \
    +swap -background none -layers merge +repage \
    "$shadowed"

  magick "$BG" "$shadowed" \
    -gravity center -geometry "+0+${SHOT_Y_OFFSET}" -composite \
    -gravity north -fill "$TAGLINE_COLOR" \
    -font "$TAGLINE_FONT" -pointsize "$TAGLINE_SIZE" \
    -annotate "+0+${TAGLINE_Y}" "$tagline" \
    "$out"
done

echo "Done. Framed shots: $OUT_DIR"
