#!/bin/bash
# Рендер шаблона в PNG під Kindle 4: headless Chrome 800x600 ->
# поворот у портрет 600x800 -> grayscale.
# Використання: ./render.sh [out.png]
# ROTATE=90|270 — якою стороною книга стоїть на столі (дефолт 90;
# якщо картинка догори ногами — постав 270).
# TEMPLATE=шлях.html — рендерити інший шаблон (дефолт template.html).
#
# Кросплатформний: macOS (Google Chrome + sips) і Linux/Docker
# (chromium + ImageMagick). Той самий скрипт крутиться на маку і на NAS,
# щоб конвеєр не роздвоївся на дві версії, які розʼїжджаються.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$DIR/out/dash.png}"
ROT="${ROTATE:-90}"
TEMPLATE="${TEMPLATE:-$DIR/template.html}"
# відносний шлях (TEMPLATE=./night.html) → абсолютний, інакше file:// не відкриється
case "$TEMPLATE" in /*) ;; *) TEMPLATE="$(cd "$(dirname "$TEMPLATE")" && pwd)/$(basename "$TEMPLATE")" ;; esac

mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp -d)"
# Убитий за таймаутом Chrome лишає по собі дітей (zygote/renderer/gpu): вони
# висять до кінця життя контейнера і їдять ту саму память, через яку рендер і
# не вклався. Мітка для відстрілу — власний user-data-dir, він унікальний.
cleanup() {
  if command -v pkill >/dev/null 2>&1; then
    pkill -9 -f "user-data-dir=$TMP/chrome" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

find_chrome() {
  [ -n "${CHROME_BIN:-}" ] && { echo "$CHROME_BIN"; return; }
  local c
  for c in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  echo "render.sh: не знайдено Chrome/Chromium (постав CHROME_BIN)" >&2; exit 1
}
CHROME="$(find_chrome)"

# --allow-file-access-from-files: інакше CSS mask-image з file:// не вантажиться
# і Chrome взагалі не малює замасковані елементи (текстура зносу .worn)
FLAGS=(--headless --disable-gpu --allow-file-access-from-files --hide-scrollbars
       --window-size=800,600 --virtual-time-budget=10000)
if [ "$(uname -s)" = Linux ]; then
  # у контейнері: пісочниця недоступна без CAP_SYS_ADMIN, а дефолтний
  # /dev/shm на 64 МБ валить рендерер на середині сторінки
  FLAGS+=(--no-sandbox --disable-dev-shm-usage --disable-software-rasterizer
          --user-data-dir="$TMP/chrome")
fi

# Таймаут — не косметика, а головний запобіжник конвеєра. Коли NAS іде у своп
# (скани медіатек Plex/Jellyfin на 1.7 ГБ RAM), рендер росте з секунд до 4-6
# хвилин. Без таймауту live-push.sh чекає синхронно й стоїть годинами, а його
# лічильник збоїв не росте — бо збою нема, є ступор. З таймаутом ступор стає
# звичайним збоєм, який watchdog уміє лікувати. (Діагноз 2026-08-30.)
RENDER_TIMEOUT="${RENDER_TIMEOUT:-90}"
TIMEOUT_BIN=""
for t in timeout gtimeout; do   # на маку coreutils-timeout зветься gtimeout
  command -v "$t" >/dev/null 2>&1 && { TIMEOUT_BIN="$t"; break; }
done

rc=0
if [ -n "$TIMEOUT_BIN" ]; then
  # -k 10: не відповів на TERM за 10 с — добиваємо KILL
  "$TIMEOUT_BIN" -k 10 "$RENDER_TIMEOUT" \
    "$CHROME" "${FLAGS[@]}" --screenshot="$TMP/shot.png" "file://$TEMPLATE" 2>/dev/null || rc=$?
else
  "$CHROME" "${FLAGS[@]}" --screenshot="$TMP/shot.png" "file://$TEMPLATE" 2>/dev/null || rc=$?
fi
if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
  echo "render.sh: Chrome не вклався у ${RENDER_TIMEOUT}s — убитий (сервер у свопі?)" >&2
  exit 1
fi
# Код виходу Chrome навмисно не перевіряємо окремо: він буває ненульовим і на
# вдалому знімку. Джерело правди — сам файл.
[ -s "$TMP/shot.png" ] || { echo "render.sh: Chrome не віддав скріншот (код $rc)" >&2; exit 1; }

if [ "$(uname -s)" = Darwin ]; then
  sips -r "$ROT" "$TMP/shot.png" >/dev/null
  sips -m "/System/Library/ColorSync/Profiles/Generic Gray Profile.icc" \
       -s format png "$TMP/shot.png" --out "$OUT" >/dev/null
  [ -n "${QUIET:-}" ] || sips -g pixelWidth -g pixelHeight -g space "$OUT"
else
  # Мета — збігтися з мак-рендером: дизайн приймався саме на ньому, а на
  # e-ink (16 градацій) зсув півтонів одразу зʼїдає фактуру пергаменту.
  #   -grayscale Rec709Luma — яскравість по гамма-кодованих значеннях
  #     ("-colorspace Gray" дає те саме; Rec709Luminance рахує по лінійному
  #     світлу й вирубає картинку в темряву — середня 46 проти 89);
  #   -gamma 0.83 — підібрано емпірично під ICC-перетворення sips у
  #     «Generic Gray». Без нього кадр світліший на ~15 рівнів (103 проти
  #     89), з ним різниця 1.75 рівня і 0.2% пікселів понад 8 рівнів.
  #     Міряно по нижній третині кадру (портрет — чистий арт без тексту).
  IM=(); command -v magick >/dev/null && IM=(magick) || IM=(convert)
  "${IM[@]}" "$TMP/shot.png" -rotate "$ROT" -grayscale Rec709Luma -gamma 0.83 \
             -depth 8 -strip "png:$OUT"
  [ -n "${QUIET:-}" ] || identify -format '%f  %wx%h  %[colorspace] %z-bit\n' "$OUT"
fi
