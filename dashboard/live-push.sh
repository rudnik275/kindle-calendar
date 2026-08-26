#!/bin/bash
# Живий конвеєр «мак → Kindle»: щохвилини рендерить template.html і пушить
# кадр на книгу. Запускається як launchd-демон (KeepAlive) через
# install-live.sh із деплой-копії ~/kindle-dash-live — НЕ з git-дерева,
# щоб перемикання гілок/мерджі не ламали рантайм.
#
# Довговічність:
#   - кадр пишеться у /tmp книги (tmpfs=RAM) — NAND не зношується;
#     раз на годину копія у /mnt/us/.../local/screen.png (фолбек на ребут);
#   - книга недоступна → лог і наступна спроба за хвилину, цикл не вмирає;
#   - повний e-ink refresh кожні FULL_EVERY хвилин (ghosting), решта часткові;
#   - 02:00–06:00 — нічний арт (night.png), панель відпочиває;
#   - раз на добу синк годинника книги з мака (RTC дрейфує роками);
#   - погода Open-Meteo кожні 15 хв, атомарно у local-weather.js;
#     без інтернету лишається останнє значення.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

SSH="ssh -F $HOME/.ssh/kindle.conf -o ConnectTimeout=6 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 kindle"
LIVE_PNG=/tmp/dash-live.png                    # на книзі, tmpfs
NAND_PNG=/mnt/us/dashboard/local/screen.png    # фолбек-копія на книзі
FULL_EVERY=30          # хвилин між повними refresh
NAND_EVERY=60          # хвилин між копіями на NAND
NIGHT_START=2 NIGHT_END=6   # [START, END) — години нічного арту (панель відпочиває)
# Погода: Київ (постав свої координати й перезапусти install-live.sh)
WEATHER_LAT=50.45 WEATHER_LON=30.52
WEATHER_EVERY=900      # секунд
TIMESYNC_EVERY=86400   # секунд

LOG="$DIR/live-push.log"
STATE="$DIR/state"; mkdir -p "$STATE" out

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
trim_log() {
  local n; n=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 4000 ] && { tail -n 1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
}

# єдиний екземпляр (mkdir-лок зі перевіркою живості PID)
LOCK="$STATE/lock"
if mkdir "$LOCK" 2>/dev/null; then
  echo $$ > "$LOCK/pid"
else
  oldpid=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
    echo "live-push already running (pid $oldpid)"; exit 0
  fi
  echo $$ > "$LOCK/pid"
fi
trap 'rm -rf "$LOCK"' EXIT

fetch_weather() {
  local now last; now=$(date +%s); last=$(cat "$STATE/weather-ts" 2>/dev/null || echo 0)
  [ $((now - last)) -lt "$WEATHER_EVERY" ] && return 0
  local json temp
  local json out
  json=$(curl -sf -m 10 "https://api.open-meteo.com/v1/forecast?latitude=$WEATHER_LAT&longitude=$WEATHER_LON&current=temperature_2m,apparent_temperature" 2>/dev/null) || { log "weather: fetch failed"; return 1; }
  out=$(printf '%s' "$json" | python3 -c '
import sys, json
c = json.load(sys.stdin)["current"]
print("window.DASH_WEATHER = { temp: %s, feels: %s };" % (c["temperature_2m"], c["apparent_temperature"]))
' 2>/dev/null) || { log "weather: parse failed"; return 1; }
  printf '%s\n' "$out" > "$DIR/local-weather.js.tmp" && mv "$DIR/local-weather.js.tmp" "$DIR/local-weather.js"
  echo "$now" > "$STATE/weather-ts"
  log "weather: $out"
}

sync_kindle_clock() {
  local now last; now=$(date +%s); last=$(cat "$STATE/timesync-ts" 2>/dev/null || echo 0)
  [ $((now - last)) -lt "$TIMESYNC_EVERY" ] && return 0
  # busybox 1.7.2: date -u -s MMDDhhmmCCYY.ss; hwclock -w зберігає через ребут
  local stamp; stamp=$(date -u '+%m%d%H%M%Y.%S')
  if $SSH "date -u -s $stamp >/dev/null 2>&1 && hwclock -w 2>/dev/null; echo SYNCED" 2>/dev/null | grep -q SYNCED; then
    echo "$now" > "$STATE/timesync-ts"
    log "timesync: ok ($stamp)"
  else
    log "timesync: FAILED"
  fi
}

push_frame() {  # $1=файл  $2=full|part  $3=також скопіювати на NAND (yes|no)
  local eips_flags="-g" extra=""
  [ "$2" = full ] && eips_flags="-f -g"
  [ "$3" = yes ] && extra=" && cp $LIVE_PNG $NAND_PNG"
  $SSH "cat > $LIVE_PNG && /usr/sbin/eips $eips_flags $LIVE_PNG >/dev/null 2>&1$extra && echo PUSHED" < "$1" 2>/dev/null | grep -q PUSHED
}

render() {  # $1=template  $2=out
  TEMPLATE="$DIR/$1" "$DIR/render.sh" "$2" >/dev/null 2>&1
}

log "=== live-push daemon started (pid $$) ==="
NIGHT_SENT=""

while true; do
  # вирівнювання на початок хвилини (10# — бо date дає 08/09 з нулем)
  s=$(date +%S); sleep $((60 - 10#$s)) 2>/dev/null || sleep 30
  trim_log
  hour=$((10#$(date +%H)))
  min=$((10#$(date +%M)))

  # ── ніч: один раз пушимо нічний арт повним refresh'ем і мовчимо ──
  if [ "$hour" -ge "$NIGHT_START" ] && [ "$hour" -lt "$NIGHT_END" ]; then
    if [ -z "$NIGHT_SENT" ]; then
      if render night.html out/night.png && push_frame out/night.png full yes; then
        NIGHT_SENT=1; log "night screen pushed"
      else
        log "night: render/push failed, retry next minute"
      fi
    fi
    continue
  fi
  NIGHT_SENT=""

  fetch_weather
  sync_kindle_clock

  if ! render template.html out/dash.png; then
    log "render FAILED"; continue
  fi

  mode=part; nand=no
  [ $((min % FULL_EVERY)) -eq 0 ] && mode=full
  [ $((min % NAND_EVERY)) -eq 0 ] && nand=yes
  if push_frame out/dash.png "$mode" "$nand"; then
    [ "$mode" = full ] && log "pushed (full, nand=$nand)"
  else
    log "push FAILED (kindle unreachable?)"
  fi
done
