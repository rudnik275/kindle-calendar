#!/bin/bash
# Розгортання/оновлення живого конвеєра на Synology NAS. Запускати з мака:
#     dashboard/nas/install-nas.sh            # деплой + збірка + старт
#     dashboard/nas/install-nas.sh --no-build # тільки оновити бандл і рестарт
#
# Ідемпотентний:ганяти після кожної правки шаблону чи скриптів.
# Образ збирається НА NAS (x86_64) — з мака (arm64) він не переносний.
#
# Що НЕ чіпає: app/state, app/secret, app/ssh, app/local-data.js,
# app/local-weather.js — це рантайм-стан і секрети, вони живуть на NAS.
set -euo pipefail

NAS="${NAS:-nas}"
REMOTE="${REMOTE:-/volume1/docker/kindle-dash}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"      # dashboard/
DOCKER="sudo -n /usr/local/bin/docker"
BUILD=yes
[ "${1:-}" = --no-build ] && BUILD=no

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# Передаємо tar-ом через ssh, а не rsync: macOS від Sonoma підсовує openrsync
# (protocol 29), який не домовляється з rsync 3.1.2 на DSM — деплой падав із
# «unexpected end of file». tar ні з ким не домовляється.
# sudo на тому боці — бо в /app пише root із контейнера, і без нього наступний
# деплой не зміг би перезаписати його файли.
# COPYFILE_DISABLE — щоб bsdtar не насипав ._-файли з xattr.
push() {  # push <локальна-база> <віддалений-каталог> <шлях...>
  local base="$1" dst="$2"; shift 2
  COPYFILE_DISABLE=1 tar --no-xattrs -czf - -C "$base" "$@" \
    | ssh "$NAS" "sudo -n tar xzf - -C $dst"
}

say "1/6  каталоги на NAS"
ssh "$NAS" "sudo -n mkdir -p $REMOTE/app/ssh $REMOTE/app/secret $REMOTE/app/state && sudo -n chmod 755 $REMOTE $REMOTE/app && sudo -n chmod 700 $REMOTE/app/secret $REMOTE/app/ssh"

say "2/6  бандл рендера -> $NAS:$REMOTE/app"
ssh "$NAS" "sudo -n rm -rf $REMOTE/app/art"      # арт заливаємо начисто
push "$SRC" "$REMOTE/app" template.html night.html render.sh live-push.sh ical-sync.py art
ssh "$NAS" "sudo -n chmod +x $REMOTE/app/render.sh $REMOTE/app/live-push.sh $REMOTE/app/ical-sync.py"

say "3/6  обвʼязка контейнера -> $NAS:$REMOTE"
push "$SRC/nas" "$REMOTE" Dockerfile docker-compose.yml entrypoint.sh healthcheck.sh

say "4/6  ключ NAS -> книга"
# Приватний ключ генерується НА NAS і звідти не виїжджає: мак свій ключ
# нікуди не копіює, компрометація NAS не тягне за собою мак.
ssh "$NAS" "sudo -n test -f $REMOTE/app/ssh/kindle-dash || sudo -n ssh-keygen -t rsa -b 2048 -N '' -C 'kindle-dash@nas' -f $REMOTE/app/ssh/kindle-dash >/dev/null; sudo -n chmod 600 $REMOTE/app/ssh/kindle-dash"
PUB="$(ssh "$NAS" "sudo -n cat $REMOTE/app/ssh/kindle-dash.pub")"
# ⚠️ ГРАБЛЯ: бінар dropbear із пакета kindle-usbnetwork зібраний із ЗАШИТИМ
# шляхом /mnt/us/usbnet/etc/authorized_keys і $HOME/.ssh/authorized_keys НЕ
# читає взагалі. Ключ, дописаний у /var/local/sshd/authorized_keys (звідки
# cron-супервізор копіює в $HOME), мовчки ігнорується: dropbear відповідає
# «0 fails», а ssh — «Permission denied». Перевірено: із порожнім
# $HOME/.ssh/authorized_keys старий ключ усе одно пускає.
# Пишемо в обидва: usbnet — той, що працює; /var/local/sshd — на випадок,
# якщо колись повернеться стоковий dropbear.
AK_REAL=/mnt/us/usbnet/etc/authorized_keys
AK_AUX=/var/local/sshd/authorized_keys
if ssh -F "$HOME/.ssh/kindle.conf" -o ConnectTimeout=10 kindle true 2>/dev/null; then
  ssh -F "$HOME/.ssh/kindle.conf" kindle "
    for F in $AK_REAL $AK_AUX; do
      [ -f \"\$F\" ] || continue
      grep -q 'kindle-dash@nas' \"\$F\" 2>/dev/null && continue
      cp \"\$F\" \"\$F.bak-preNAS\" 2>/dev/null
      echo '$PUB' >> \"\$F\"
    done
    printf 'ключі у %s: ' $AK_REAL; sed 's/.* //' $AK_REAL | tr '\n' ' '; echo"
else
  echo "книга недосяжна — допиши сам, коли зʼявиться:"
  echo "  ssh -F ~/.ssh/kindle.conf kindle \"echo '$PUB' >> $AK_REAL\""
fi

say "5/6  стартовий local-data.js (щоб екран не був порожній до першого iCal-синку)"
ssh "$NAS" "sudo -n test -s $REMOTE/app/local-data.js" 2>/dev/null \
  || if [ -s "$SRC/local-data.js" ]; then
       ssh "$NAS" "sudo -n tee $REMOTE/app/local-data.js >/dev/null" < "$SRC/local-data.js"
       echo "залито снапшот із $SRC"
     else
       ssh "$NAS" "echo 'window.DASH_DATA = { events: [] };' | sudo -n tee $REMOTE/app/local-data.js >/dev/null"; echo "порожня заглушка"
     fi

say "6/6  збірка й старт"
if [ "$BUILD" = yes ]; then
  # Збираємо ОКРЕМО і класичним білдером, а не `compose up --build`:
  # на DSM 7.3 compose-збірка вішається намертво (BuildKit не піднімається —
  # ні проміжних контейнерів, ні мережевого трафіку, CPU нуль).
  # Перша збірка на Celeron NAS — 15–25 хв: chromium тягне пів-гіга залежностей.
  echo "перша збірка займе 15–25 хв (chromium), далі — секунди з кешу"
  ssh -o ServerAliveInterval=30 "$NAS" \
    "cd $REMOTE && sudo -n env DOCKER_BUILDKIT=0 /usr/local/bin/docker build -t kindle-dash:local ."
fi
# compose бачить готовий kindle-dash:local і не перезбирає
ssh "$NAS" "cd $REMOTE && $DOCKER compose up -d && $DOCKER restart kindle-dash"

sleep 5
ssh "$NAS" "$DOCKER ps --filter name=kindle-dash --format '{{.Names}}  {{.Status}}'"
echo
echo "лог:      ssh $NAS '$DOCKER exec kindle-dash tail -f /app/live-push.log'"
echo "календар: поклади приватні iCal-URL (по одному в рядок) у"
echo "          $REMOTE/app/secret/ical-urls  (chmod 600) — див. nas/README.md"
