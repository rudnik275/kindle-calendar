#!/bin/bash
# Кладе приватний iCal-URL Google Calendar на NAS, не показуючи його нікому:
# значення береться з буфера обміну (або вводиться приховано) і йде одразу
# в файл 0600 на NAS. Воно не друкується, не потрапляє в історію шелу
# і не проходить через сесію Клода.
#
# Використання:
#   1) у Google Calendar: Налаштування календаря -> Інтеграція календаря ->
#      «Закрита адреса у форматі iCal» -> око (показати) -> кнопка копіювання;
#   2) одразу після цього:  dashboard/nas/add-ical-url.sh
#      (без аргументів бере з буфера; --ask — спитає прихованим вводом)
#
# Ганяти по разу на кожен календар: файл доповнюється, дублікати відсіюються.
set -euo pipefail

NAS="${NAS:-nas}"
SSH=(ssh -o LogLevel=ERROR)   # глушимо банер клієнта, щоб не засмічував вивід
REMOTE="${REMOTE:-/volume1/docker/kindle-dash}"
DEST="$REMOTE/app/secret/ical-urls"
DOCKER="sudo -n /usr/local/bin/docker"

URL=""
if [ "${1:-}" = --ask ]; then
  printf 'Встав приватний iCal-URL (не відображається), Enter: '
  read -rs URL; echo
else
  command -v pbpaste >/dev/null || { echo "pbpaste недоступний — запусти з --ask"; exit 1; }
  URL="$(pbpaste)"
fi
URL="$(printf '%s' "$URL" | tr -d '[:space:]')"

# Валідація без показу значення. Приймаємо і приватний Google-фід, і будь-який
# інший https-ICS (Outlook/Exchange теж такі віддають — ical-sync.py загальний).
if printf '%s' "$URL" | grep -qE '^https://calendar\.google\.com/calendar/ical/.+/private-.+/basic\.ics$'; then
  KIND="приватний Google-фід"
elif printf '%s' "$URL" | grep -qE '^https://.+\.ics(\?.*)?$'; then
  KIND="зовнішній ICS-фід"
else
  echo "❌ У буфері не схоже на iCal-URL (нічого не показую і нічого не змінюю)."
  echo "   Скопіюй саме «Закриту адресу у форматі iCal» і запусти ще раз."
  exit 1
fi
echo "✅ Розпізнано: $KIND (значення не показую)"

"${SSH[@]}" "$NAS" "sudo -n mkdir -p $REMOTE/app/secret && sudo -n touch $DEST && sudo -n chmod 600 $DEST"
# дублікат? порівнюємо на тому боці, сюди значення не повертається
if printf '%s\n' "$URL" | "${SSH[@]}" "$NAS" "sudo -n grep -qxFf - $DEST" 2>/dev/null; then
  echo "ℹ️  Такий URL уже є — не додаю вдруге."
else
  printf '%s\n' "$URL" | "${SSH[@]}" "$NAS" "sudo -n tee -a $DEST >/dev/null && sudo -n chmod 600 $DEST"
  echo "✅ Додано на NAS ($DEST, права 600)"
fi
unset URL

echo
echo "── синк календаря просто зараз ──"
"${SSH[@]}" "$NAS" "$DOCKER exec kindle-dash rm -f /app/state/cal-ts" 2>/dev/null || true
"${SSH[@]}" "$NAS" "$DOCKER exec kindle-dash /app/ical-sync.py --urls /app/secret/ical-urls --out /app/local-data.js" 2>&1 | sed -E 's#https?://[^ ]+#<URL>#g'
echo
echo "── що поїде на екран ──"
"${SSH[@]}" "$NAS" "$DOCKER exec kindle-dash sh -c 'grep -c title /app/local-data.js || true'" 2>/dev/null \
  | sed 's/^/подій у файлі: /'
echo "Кадр із новими подіями зʼявиться на книзі протягом хвилини."
echo
echo "⚠️  Буфер обміну ще містить секрет — скопіюй щось інше або виконай: pbcopy </dev/null"
