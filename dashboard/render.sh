#!/bin/bash
# Рендер шаблона в PNG під Kindle 4: headless Chrome 800x600 ->
# поворот у портрет 600x800 -> grayscale (Generic Gray).
# Використання: ./render.sh [out.png]
# ROTATE=90|270 — якою стороною книга стоїть на столі (дефолт 90;
# якщо картинка догори ногами — постав 270).
# TEMPLATE=шлях.html — рендерити інший шаблон (дефолт template.html).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$DIR/out/dash.png}"
ROT="${ROTATE:-90}"
TEMPLATE="${TEMPLATE:-$DIR/template.html}"
# відносний шлях (TEMPLATE=./night.html) → абсолютний, інакше file:// не відкриється
case "$TEMPLATE" in /*) ;; *) TEMPLATE="$(cd "$(dirname "$TEMPLATE")" && pwd)/$(basename "$TEMPLATE")" ;; esac
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
GRAY_PROFILE="/System/Library/ColorSync/Profiles/Generic Gray Profile.icc"

mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --allow-file-access-from-files: інакше CSS mask-image з file:// не вантажиться
# і Chrome взагалі не малює замасковані елементи (текстура зносу .worn)
"$CHROME" --headless --disable-gpu --allow-file-access-from-files --hide-scrollbars --window-size=800,600 \
  --screenshot="$TMP/shot.png" "file://$TEMPLATE" \
  --virtual-time-budget=10000 2>/dev/null

sips -r "$ROT" "$TMP/shot.png" >/dev/null
sips -m "$GRAY_PROFILE" -s format png "$TMP/shot.png" --out "$OUT" >/dev/null

sips -g pixelWidth -g pixelHeight -g space "$OUT"
