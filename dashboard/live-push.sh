#!/bin/bash
# Живий конвеєр «сервер → Kindle»: щохвилини рендерить template.html і пушить
# кадр на книгу. Один і той самий скрипт крутиться:
#   - на NAS у Docker-контейнері (штатний режим, restart: always) — nas/;
#   - на маку як launchd-демон (резервний шлях) — install-live.sh.
# Рантайм навмисно відвʼязаний від git-дерева, щоб гілки й мерджі не ламали
# працюючий демон.
#
# Довговічність:
#   - кадр пишеться у /tmp книги (tmpfs=RAM) — NAND не зношується;
#     раз на годину копія у /mnt/us/.../local/screen.png (фолбек на ребут);
#   - книга недоступна → лог і наступна спроба за хвилину, цикл не вмирає;
#   - повний e-ink refresh кожні FULL_EVERY хвилин (ghosting), решта часткові;
#   - працює 24/7 — нічного режиму немає, годинник тікає завжди
#     (night.html існує лише як джерело sleeping.png-фолбека на книзі);
#   - раз на добу синк годинника книги з сервером (RTC дрейфує роками);
#   - погода Open-Meteo кожні 15 хв, атомарно у local-weather.js;
#     без інтернету лишається останнє значення;
#   - курс долара (обмінники Києва: minfin, фолбек monobank) 2 рази на
#     добу, атомарно у local-rates.js — той самий контракт живучості;
#   - події з приватних iCal кожні CAL_EVERY секунд (ical-sync.py), теж
#     атомарно і теж із збереженням попереднього значення при збої;
#   - серія збоїв рендера -> вихід із кодом 1: підняти нас заново має
#     супервізор (docker restart: always / launchd KeepAlive). Це лікує
#     клас «завис Chrome», який зсередини не розгребти;
#   - окремо від лічильників збоїв — сторож за heartbeat: ловить ступор
#     (команда, що не повертається), якого лічильники не бачать.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

SSH_CONF="${SSH_CONF:-$HOME/.ssh/kindle.conf}"
SSH="ssh -F $SSH_CONF -o ConnectTimeout=6 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 kindle"
LIVE_PNG=/tmp/dash-live.png                    # на книзі, tmpfs
NAND_PNG=/mnt/us/dashboard/local/screen.png    # фолбек-копія на книзі
FULL_EVERY=30          # хвилин між повними refresh
NAND_EVERY=60          # хвилин між копіями на NAND
# Погода: Київ (постав свої координати й перезапусти інсталятор)
WEATHER_LAT="${WEATHER_LAT:-50.45}" WEATHER_LON="${WEATHER_LON:-30.52}"
WEATHER_EVERY=900      # секунд
RATES_EVERY=43200      # секунд: курс долара 2 рази на добу
RATES_URL="https://minfin.com.ua/currency/kiev/"
RATES_UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
CAL_EVERY="${CAL_EVERY:-900}"        # секунд між синками календаря
CAL_URLS="${CAL_URLS:-$DIR/secret/ical-urls}"  # приватні iCal-URL (0600, поза git)
TIMESYNC_EVERY=86400   # секунд
RENDER_FAILS_MAX=5     # поспіль -> вихід, хай супервізор перезапустить
PUSH_FAILS_MAX=60      # поспіль (≈1 год) -> те саме: чистимо мережевий стан
HEARTBEAT_STALL="${HEARTBEAT_STALL:-420}"  # секунд без відмітки -> цикл завис

LOG="$DIR/live-push.log"
STATE="$DIR/state"; mkdir -p "$STATE" out

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
trim_log() {
  local n; n=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 4000 ] && { tail -n 1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
}

# Єдиний екземпляр (mkdir-лок із перевіркою живості PID).
# Лок НАВМИСНО не в $STATE, а на тимчасовій ФС: у контейнері цей скрипт
# завжди PID 1, і переживший SIGKILL лок із записом «pid 1» на бінд-маунті
# означав би, що наступний екземпляр бачить «сам себе» як чужого живого
# демона й одразу виходить — вічний рестарт-цикл без жодного кадру.
# Лок має жити рівно стільки, скільки живе машина/контейнер.
LOCK="${TMPDIR:-/tmp}/kindle-dash.lock"
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

fetch_rates() {
  # Долар у обмінниках Києва -> local-rates.js (атомарно; без інтернету
  # лишається останнє значення). Джерело — JSON-LD (schema.org) зі сторінки
  # minfin «курс у Києві»: «Средний наличный курс» = середнє по обмінниках.
  # Розмітка для пошуковиків, тому стабільніша за HTML-верстку. Фолбек —
  # API monobank (безкоштовне, без ключа; курс близький до готівкового).
  local now last; now=$(date +%s); last=$(cat "$STATE/rates-ts" 2>/dev/null || echo 0)
  [ $((now - last)) -lt "$RATES_EVERY" ] && return 0
  local out
  out=$(curl -sf -m 15 -A "$RATES_UA" "$RATES_URL" 2>/dev/null | python3 -c '
import sys, re, json
html = sys.stdin.read()
for m in re.finditer(r"<script[^>]*application/ld\+json[^>]*>(.*?)</script>", html, re.S):
    try: data = json.loads(m.group(1))
    except ValueError: continue
    stack = [data]; buy = sell = None
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            if (node.get("@type") == "ExchangeRateSpecification"
                    and node.get("currency") == "USD"
                    and "наличн" in node.get("name", "")):
                price = float(node["currentExchangeRate"]["price"])
                if "покупки" in node.get("description", ""): buy = price
                elif "продажи" in node.get("description", ""): sell = price
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
    if buy and sell:
        print("window.DASH_RATES = { usd: { buy: %.2f, sell: %.2f }, source: \"minfin/kyiv\" };" % (buy, sell))
        sys.exit(0)
sys.exit(1)
' 2>/dev/null)
  if [ -z "$out" ]; then
    out=$(curl -sf -m 10 "https://api.monobank.ua/bank/currency" 2>/dev/null | python3 -c '
import sys, json
for r in json.load(sys.stdin):
    if r.get("currencyCodeA") == 840 and r.get("currencyCodeB") == 980:
        print("window.DASH_RATES = { usd: { buy: %.2f, sell: %.2f }, source: \"monobank\" };" % (r["rateBuy"], r["rateSell"]))
        break
' 2>/dev/null)
  fi
  if [ -z "$out" ]; then
    # обидва джерела мовчать — повторити за 30 хв, не молотити щохвилини
    log "rates: fetch failed (minfin+mono)"
    echo $((now - RATES_EVERY + 1800)) > "$STATE/rates-ts"
    return 1
  fi
  printf '%s\n' "$out" > "$DIR/local-rates.js.tmp" && mv "$DIR/local-rates.js.tmp" "$DIR/local-rates.js"
  echo "$now" > "$STATE/rates-ts"
  log "rates: $out"
}

sync_calendar() {
  [ -s "$CAL_URLS" ] || return 0            # немає фідів — лишаємо снапшот як є
  [ -x "$DIR/ical-sync.py" ] || return 0
  local now last; now=$(date +%s); last=$(cat "$STATE/cal-ts" 2>/dev/null || echo 0)
  [ $((now - last)) -lt "$CAL_EVERY" ] && return 0
  local out rc
  # stderr ical-sync.py — без URL усередині (див. шапку скрипта), тому в лог можна
  out=$("$DIR/ical-sync.py" --urls "$CAL_URLS" --out "$DIR/local-data.js" 2>&1); rc=$?
  log "calendar: $(printf '%s' "$out" | tr '\n' '; ')"
  if [ $rc -eq 0 ]; then
    echo "$now" > "$STATE/cal-ts"
  else
    # не відповів — повторити за 2 хв, а не через повний CAL_EVERY і не
    # щохвилини (щоб битий URL не молотив Google по колу)
    echo $((now - CAL_EVERY + 120)) > "$STATE/cal-ts"
  fi
  return 0
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
  QUIET=1 TEMPLATE="$DIR/$1" "$DIR/render.sh" "$2" >/dev/null 2>&1
}

log "=== live-push daemon started (pid $$) ==="

# ── Сторож проти ЗАВИСАННЯ ────────────────────────────────────────────────
# Лічильники нижче ловлять ПАДІННЯ (рендер повернув помилку). Мовчазний
# ступор вони не бачать: цикл просто стоїть на команді, що не повертається,
# лічильник не росте, і екран книги лишається з давнім кадром, поки не
# спрацює запобіжник «година без книги». Саме так 2026-08-30 екран простояв
# 1.5 години на 16:32, коли скани медіатек загнали NAS у своп.
#
# Вбити PID 1 зсередини контейнера сигналом не можна: ядро не доставляє
# SIGKILL/SIGTERM ініту namespace'у, поки нема обробника. Тому порядок такий:
# спершу відстрілюємо зависле піддерево (це звільняє цикл із блокуючої
# команди), далі шлемо USR1 — його обробник і робить штатний exit 1.
MAIN_PID=$$
trap 'log "watchdog: примусовий вихід — цикл завис"; exit 1' USR1

children_of() {  # $1=ppid. procps в образі може не бути — тоді читаємо /proc
  local p ppid
  if command -v pgrep >/dev/null 2>&1; then pgrep -P "$1" 2>/dev/null; return 0; fi
  for p in /proc/[0-9]*; do
    [ -r "$p/stat" ] || continue
    # comm у дужках і з пробілами — тому відрізаємо все до останньої ')'
    ppid=$(sed 's/.*) //' "$p/stat" 2>/dev/null | awk '{print $2}')
    [ "$ppid" = "$1" ] && echo "${p#/proc/}"
  done
  return 0
}

date +%s > "$STATE/heartbeat"   # інакше сторож візьме старий файл за ступор
(
  me=$BASHPID
  kill_tree() {   # знизу вгору, щоб chromium не осиротів і не пережив render.sh
    local c
    for c in $(children_of "$1"); do
      [ "$c" = "$me" ] && continue
      kill_tree "$c"
    done
    [ "$1" = "$MAIN_PID" ] || kill -9 "$1" 2>/dev/null
  }
  while sleep 60; do
    kill -0 "$MAIN_PID" 2>/dev/null || exit 0        # головний помер — і ми теж
    age=$(( $(date +%s) - $(cat "$STATE/heartbeat" 2>/dev/null || echo 0) ))
    [ "$age" -le "$HEARTBEAT_STALL" ] && continue
    log "watchdog: heartbeat протух ${age}s (>${HEARTBEAT_STALL}s) — знімаємо завислих"
    kill_tree "$MAIN_PID"
    sleep 5
    kill -USR1 "$MAIN_PID" 2>/dev/null
    exit 0
  done
) &

render_fails=0 push_fails=0 first=yes

while true; do
  trim_log
  min=$((10#$(date +%M)))

  fetch_weather
  fetch_rates
  sync_calendar
  sync_kindle_clock

  if render template.html out/dash.png; then
    render_fails=0
  else
    render_fails=$((render_fails + 1))
    log "render FAILED ($render_fails/$RENDER_FAILS_MAX)"
    if [ "$render_fails" -ge "$RENDER_FAILS_MAX" ]; then
      log "рендер мертвий $render_fails разів поспіль — виходимо, хай супервізор підніме"
      exit 1
    fi
    sleep 30; continue
  fi

  # Перший кадр після старту — повний refresh: чистить ghosting, залишений
  # тим, хто малював до нас (фолбек книги / попередній екземпляр демона).
  # NAND тут свідомо НЕ чіпаємо: якщо ми колись потрапимо в рестарт-цикл,
  # копія на кожному старті вигризала б флеш книги. Годинна копія й так буде.
  mode=part; nand=no
  [ "$first" = yes ] && { mode=full; first=no; }
  [ $((min % FULL_EVERY)) -eq 0 ] && mode=full
  [ $((min % NAND_EVERY)) -eq 0 ] && nand=yes

  if push_frame out/dash.png "$mode" "$nand"; then
    push_fails=0
    [ "$mode" = full ] && log "pushed (full, nand=$nand)"
  else
    push_fails=$((push_fails + 1))
    log "push FAILED ($push_fails, kindle unreachable?)"
    if [ "$push_fails" -ge "$PUSH_FAILS_MAX" ]; then
      log "книга недосяжна $push_fails хвилин — виходимо, хай супервізор підніме"
      exit 1
    fi
  fi

  date +%s > "$STATE/heartbeat"     # для docker healthcheck
  # вирівнювання на початок хвилини (10# — бо date дає 08/09 з нулем)
  s=$(date +%S); sleep $((60 - 10#$s)) 2>/dev/null || sleep 30
done
