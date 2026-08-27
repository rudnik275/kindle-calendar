# Дашборд Kindle-календаря — dark fantasy v2 (2026-08-27)

Дизайн v2 на ассетах користувача: фон «вежа + портрет» (`art/bg2.png`),
гранжева плашка активної дати (`art/today-plate.png`), текстура зносу
шрифтів (`art/ink-mask.png`, альфа-маска — клас `.worn`, ТІЛЬКИ на великих
цифрах: дрібний текст із дірками e-ink розриває). Шрифти: Cormorant Garamond
(цифри/дисплей) + Forum (капс-лейбли) + PT Serif (текст), повна укр.
кирилиця, **локально** в `art/fonts/` — рендер не залежить від інтернету.
Екран 800×600 landscape → на панель іде портрет 600×800 (ROTATE=90).

Живі дані: температура на вежі + маленька цифра «відчувається як» під нею
(Open-Meteo, координати в `live-push.sh`), годинник, дата, події з
`local-data.js`, тижнева стрічка з плашкою на сьогодні.

## Архітектура: живе оновлення (з 2026-08-27)

**NAS — рендерер і пушер** (`live-push.sh` у Docker-контейнері `kindle-dash`,
ставиться `nas/install-nas.sh`, деталі — `nas/README.md`). Мак робить те саме
й тим самим скриптом, але тільки як резервний шлях (`install-live.sh`,
launchd-демон `com.rudnik.kindle-dash`) — **разом їх вмикати не можна**,
битимуться за екран.

Цикл конвеєра (однаковий на обох):

- щохвилини (вирівняно на початок хвилини): рендер → push у
  `/tmp/dash-live.png` книги (tmpfs = RAM, NAND не зношується) →
  `eips -g` (частковий refresh, без блимання);
- кожні 30 хв — повний refresh (`eips -f -g`) проти ghosting;
- щогодини — копія кадру в `/mnt/us/dashboard/local/screen.png` (NAND):
  єдине, що переживає ребут книги;
- кожні 15 хв — погода Open-Meteo → `local-weather.js` (атомарно; без
  інтернету лишається останнє значення);
- кожні 15 хв — події з приватних iCal-фідів Google Calendar
  (`ical-sync.py` → `local-data.js`, теж атомарно; фіди не відповіли —
  лишаються попередні події). Тільки на NAS: на маку файлу з URL немає,
  і синк тихо пропускається;
- раз на добу — синк годинника книги (`date -u -s` + `hwclock -w`,
  RTC книги дрейфує роками);
- працює **24/7** — нічного режиму немає (рішення 2026-08-27), годинник
  тікає завжди;
- **watchdog**: 5 збоїв рендера поспіль або година без книги → вихід із
  кодом 1, щоб супервізор (`restart: always` / launchd `KeepAlive`) підняв
  процес із чистим Chrome. Це лікує клас «завис Chrome», який зсередини
  не розгребти.

Рантайм навмисно **поза git** — на NAS це `/volume1/docker/kindle-dash/app`,
на маку деплой-копія `~/kindle-dash-live/`: перемикання гілок, мерджі й
чистки worktree не чіпають працюючий демон. Після зміни шаблону чи скриптів
— перезапустити відповідний інсталятор.

**Книга — тупий e-ink дисплей із фолбеком** (kindle-dash, `dash.sh`):

- цикл `*/15 * * * *` цілодобово: `fetch-dashboard.sh` бере
  `/tmp/dash-live.png`, якщо він свіжіший за NAND-копію, інакше
  `local/screen.png` — конвеєр упав/мережа зникла → екран живе далі з
  останнім кадром;
- `FULL_DISPLAY_REFRESH_RATE=96` — свій повний refresh лише раз на добу
  (основні робить мак);
- `sleeping.png` = нічний арт (сток «Kindle is sleeping» у
  `sleeping.png.bak-stock`); при 24/7-розкладі книга сама його не малює —
  чистий фолбек;
- супервізор `/var/local/sshd/start-ssh.sh` (cron `*/5`): sshd + dash по
  PID-файлах + **мережевий watchdog** — 3 страйки (~15 хв) без пінгу
  шлюзу → рестарт радіо (`wirelessEnable 0/1`), 24 страйки (~2 год) →
  ребут (все відроджується з cron; наступний ребут не раніше ніж за 6 год
  — без ребут-шторму при мертвому роутері);
- DEBUG=true (без suspend) — книга на постійному живленні, не спить;
- профілактичний тижневий ребут (cron: пн 01:45 UTC ≈ 04:45 Києва) —
  проти повільних витоків прошивки 2011 року; екран повертається сам
  за ~2 хв.

## Файли

- `template.html` — єдине джерело правди дизайну; JS на момент рендера:
  годинник, дата, події (`local-data.js`, gitignored, контракт у шапці),
  погода (`local-weather.js`, пише live-push), тиждень. Плашка сьогодні —
  `art/today-plate.png`.
- `night.html` — джерело sleeping.png-фолбека (чистий арт + орнамент);
  у живому циклі НЕ використовується (нічного режиму немає).
- `render.sh` — headless Chrome/Chromium (**--allow-file-access-from-files**
  — інакше CSS-маска з file:// не рендериться) → ROTATE → grayscale.
  Кросплатформний: на маку Google Chrome + `sips`, на Linux/NAS
  `chromium` + ImageMagick (`-grayscale Rec709Luma` — голий
  `-colorspace Gray` рахує по лінійному світлу й висвітлює півтони).
- `live-push.sh` — живий конвеєр (вище), один на обидві платформи.
- `ical-sync.py` — приватні iCal-фіди → `local-data.js`. URL-и лежать у
  `secret/ical-urls` (0600, поза git) і **ніколи не друкуються в лог**.
- `nas/` — Docker-обвʼязка для Synology: `install-nas.sh`, `Dockerfile`,
  `docker-compose.yml`, `entrypoint.sh`, `healthcheck.sh` + `nas/README.md`.
- `install-live.sh` — резервний launchd-шлях на маку.
- `push-to-kindle.sh` — разова ручна заливка (діагностика).
- `calibration.html` — калібрувальна карточка e-ink.

## Ручні операції

```
ROTATE=0 ./render.sh out/preview.png        # подивитись макет (landscape)
./render.sh && ./push-to-kindle.sh          # разова заливка вручну

nas/install-nas.sh                          # ШТАТНО: перевстановити на NAS
ssh nas "sudo -n docker exec kindle-dash tail -f /app/live-push.log"

./install-live.sh                           # РЕЗЕРВ: підняти конвеєр на маку
launchctl bootout gui/$(id -u)/com.rudnik.kindle-dash   # зупинити мак-демона
```

⚠️ Одночасно на NAS і на маку конвеєр не вмикати — два пушери битимуться
за екран, e-ink блиматиме.
