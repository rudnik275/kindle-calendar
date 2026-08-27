# Рендер-конвеєр на NAS (Synology DSM 7)

Штатне місце життя конвеєра. Мак більше не точка відмови: він може спати,
перезавантажуватись і їхати у відпустку — годинник на книзі тікає далі.

```
Google Calendar (приватні iCal) ─┐
Open-Meteo (погода) ─────────────┤
                                 ▼
   NAS · Docker «kindle-dash» · щохвилини
   ical-sync.py → local-data.js ┐
   curl → local-weather.js      ├→ chromium 800×600 → ImageMagick → PNG 600×800
                                ┘                              │
                                                               ▼
                              ssh root@kindle: cat > /tmp/dash-live.png; eips -g
```

## Розгортання й оновлення

З мака, з каталогу репозиторію:

```
dashboard/nas/install-nas.sh              # деплой + збірка образу + старт
dashboard/nas/install-nas.sh --no-build   # тільки оновити бандл і рестарт
```

Скрипт ідемпотентний — ганяй після кожної правки `template.html`, `render.sh`
чи `live-push.sh`. Він не чіпає рантайм-стан: `app/state`, `app/secret`,
`app/ssh`, `app/local-data.js`, `app/local-weather.js`.

Образ збирається **на самому NAS**: мак — arm64, NAS — x86_64.

## Розкладка на NAS

```
/volume1/docker/kindle-dash/
├── docker-compose.yml   Dockerfile   entrypoint.sh   healthcheck.sh
└── app/                     ← бінд-маунт у контейнер як /app
    ├── template.html night.html render.sh live-push.sh ical-sync.py art/
    ├── local-data.js        ← генерує ical-sync.py (у git не йде)
    ├── local-weather.js     ← генерує live-push.sh (у git не йде)
    ├── live-push.log
    ├── ssh/                 ← ключ NAS→книга (0600) + known_hosts
    ├── secret/ical-urls     ← приватні iCal-URL, 0600 (у git не йде)
    └── state/               ← мітки часу, heartbeat, лок
```

Увесь стан — на `/volume1`, тому перестворення контейнера чи ребут NAS
нічого не втрачають.

## Календар: увімкнути живі події

Поки файлу `secret/ical-urls` немає, на екрані висить снапшот подій, залитий
при першому деплої. Щоб події оновлювались самі, треба покласти приватні
iCal-URL Google Calendar.

Де взяти: Google Calendar → налаштування потрібного календаря → «Інтеграція
календаря» → **Приватна адреса в форматі iCal**.

> ⚠️ Такий URL = пароль на читання календаря. Канонічне місце зберігання —
> 1Password; на NAS він лежить у файлі 0600 і ніде більше. У логи він не
> потрапляє: `ical-sync.py` друкує лише порядковий номер фіда, не адресу.
> Не вставляй ці URL у чат і не коміть у репозиторій — він публічний.

Один раз, руками на маку (по одному URL у рядок):

```
ssh nas "sudo -n tee /volume1/docker/kindle-dash/app/secret/ical-urls >/dev/null && sudo -n chmod 600 /volume1/docker/kindle-dash/app/secret/ical-urls"
```

…далі вставити URL-и, `Ctrl-D`. Конвеєр підхопить їх наступним циклом
(не пізніше 15 хв), рестарт не потрібен.

## Живучість при перезавантаженні NAS

П'ять незалежних шарів — жоден не вимагає ручних дій після ребуту:

| Шар | Що дає |
|---|---|
| `restart: always` | демон Docker піднімає контейнер, щойно стартує сам |
| Container Manager стартує з DSM | демон Docker узагалі зʼявляється після ребуту |
| стан на `/volume1` (бінд-маунт) | події, погода, лог, мітки часу переживають усе |
| все зашите в образ | на старті не потрібні ні інтернет, ні реєстр: NAS вантажиться швидше за роутер |
| watchdog у `live-push.sh` | серія збоїв рендера (5) або година без книги → `exit 1` → Docker піднімає з чистим Chrome |

Плюс `healthcheck.sh`: у `docker ps` видно `healthy`/`unhealthy` за свіжістю
`state/heartbeat` (поріг 5 хв). Це індикатор, лікування робить watchdog.

Книга з іншого боку теж самостійна: cron-супервізор, мережевий watchdog,
щотижневий профілактичний ребут, фолбек на NAND-копію кадру. Якщо конвеєр
мовчить, екран не гасне — просто завмирає на останньому кадрі.

### Перевірка після змін

```
ssh nas "sudo -n docker kill kindle-dash"     # має піднятися сам за секунди
ssh nas "sudo -n docker ps --filter name=kindle-dash"
```

## Щоденне

```
# лог конвеєра
ssh nas "sudo -n docker exec kindle-dash tail -f /app/live-push.log"

# стан і здоровʼя
ssh nas "sudo -n docker ps --filter name=kindle-dash --format '{{.Status}}'"

# памʼять (на NAS її ~1.7 ГБ на всіх, ліміт контейнера 640 МБ)
ssh nas "sudo -n docker stats --no-stream kindle-dash"

# разовий рендер без пуша (подивитись, що вийшло)
ssh nas "sudo -n docker exec kindle-dash bash -c 'QUIET= /app/render.sh /tmp/t.png'"
```

## Мак як резервний шлях

Старий launchd-конвеєр нікуди не подівся — `dashboard/install-live.sh`.
Обидва одночасно вмикати НЕ можна: вони битимуться за екран, e-ink
блиматиме. Перемикання:

```
launchctl bootout gui/$(id -u)/com.rudnik.kindle-dash        # вимкнути мак
ssh nas "cd /volume1/docker/kindle-dash && sudo -n docker compose stop"   # вимкнути NAS
```
