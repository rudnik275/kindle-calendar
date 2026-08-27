#!/usr/bin/env python3
"""Приватні iCal-фіди Google Calendar -> local-data.js (контракт window.DASH_DATA).

Замінює ручний MCP-снапшот: конвеєр на NAS сам тягне календарі й переписує
local-data.js, тож нова подія доїжджає на екран за один цикл синку.

Секрет: приватні iCal-URL живуть у файлі --urls (chmod 600, поза git, поза
логами). URL НЕ друкується ніде — ні в лозі, ні в повідомленнях про помилку:
приватний фід — це, по суті, пароль на читання календаря.

Вивід атомарний (tmp + rename). Будь-який збій -> ненульовий код і НЕ чіпаємо
наявний local-data.js: показати вчорашні події краще, ніж порожній екран.
"""
import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request
from zoneinfo import ZoneInfo

import icalendar
import recurring_ical_events

WINDOW_DAYS = 14
MAX_EVENTS = 8
UA = "kindle-dash/1.0 (+https://github.com/rudnik275/kindle-calendar)"


def log(msg):
    print(f"ical-sync: {msg}", file=sys.stderr)


# Емодзі в назвах подій («🎂 День народження») локальні шрифти не мають, і
# Chrome малює порожній квадрат-tofu просто перед текстом. Своїх гліфів у
# Cormorant/PT Serif/Forum для них немає, а тягнути емодзі-шрифт заради
# монохромного e-ink безглуздо — вони б однаково виглядали чужорідно.
# Тому ріжемо: емодзі-площини, стрілки/дінгбати, селектори варіацій і ZWJ.
_DROP = re.compile(
    "[\U0001F000-\U0001FAFF"      # емодзі та пікторграми
    "←-⯿"               # стрілки, геометрія, дінгбати
    "☀-➿"
    "︀-️"               # селектори варіацій (VS15/VS16)
    "‍⃣]"               # ZWJ і keycap
)


def clean(text):
    """Прибирає те, що шрифти дашборда не намалюють, і чистить пробіли."""
    return re.sub(r"\s{2,}", " ", _DROP.sub("", text)).strip(" -–—·•\t")


def read_urls(path):
    """Читає URL-и по одному на рядок; '#' — коментар."""
    with open(path, encoding="utf-8") as fh:
        urls = [ln.strip() for ln in fh]
    return [u for u in urls if u and not u.startswith("#")]


def fetch(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def local_naive(value, tz):
    """DTSTART -> naive datetime у локальній зоні + прапорець «на весь день»."""
    if isinstance(value, dt.datetime):
        if value.tzinfo is not None:
            value = value.astimezone(tz)
        return value.replace(tzinfo=None), False
    # icalendar віддає date для VALUE=DATE — це подія на весь день
    return dt.datetime(value.year, value.month, value.day), True


def collect(raw, tz, since, until):
    cal = icalendar.Calendar.from_ical(raw)
    out = []
    for ev in recurring_ical_events.of(cal).between(since, until):
        start = ev.get("DTSTART")
        if start is None:
            continue
        start_dt, all_day = local_naive(start.dt, tz)
        end = ev.get("DTEND")
        end_dt = local_naive(end.dt, tz)[0] if end is not None else start_dt
        title = clean(str(ev.get("SUMMARY") or ""))
        if not title:
            continue
        sub = clean(str(ev.get("LOCATION") or "")).splitlines()[:1]
        out.append({
            "start": start_dt.strftime("%Y-%m-%dT%H:%M"),
            "allDay": all_day,
            "title": title,
            "sub": sub[0] if sub else "",
            "_end": end_dt,
        })
    return out


def relevant(events, now):
    """Лишає те, що ще попереду: минулі зустрічі зі списку прибираємо,
    але подію «на весь день» тримаємо до кінця її дня."""
    today = now.date()
    keep = []
    for e in events:
        if e["allDay"]:
            if dt.date.fromisoformat(e["start"][:10]) >= today:
                keep.append(e)
        elif e["_end"] > now:
            keep.append(e)
    return keep


def dedupe(events):
    seen, out = set(), []
    for e in events:
        key = (e["start"], e["title"])
        if key not in seen:
            seen.add(key)
            out.append(e)
    return out


def render_js(events, tz_name):
    stamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M")
    lines = [
        f"// ЗГЕНЕРОВАНО ical-sync.py {stamp} ({tz_name}).",
        f"// Джерело: приватні iCal-фіди Google Calendar. Вікно: {WINDOW_DAYS} днів.",
        "// Файл у git не йде і руками не правиться — його перезапише конвеєр.",
        "window.DASH_DATA = {",
        "  events: [",
    ]
    for e in events:
        row = {k: e[k] for k in ("start", "allDay", "title", "sub")}
        if not row["sub"]:
            del row["sub"]
        lines.append("    " + json.dumps(row, ensure_ascii=False) + ",")
    lines += ["  ]", "};", ""]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--urls", required=True, help="файл зі списком приватних iCal-URL")
    ap.add_argument("--out", required=True, help="куди писати local-data.js")
    ap.add_argument("--tz", default=os.environ.get("TZ", "Europe/Kyiv"))
    ap.add_argument("--timeout", type=int, default=20)
    args = ap.parse_args()

    try:
        urls = read_urls(args.urls)
    except OSError as exc:
        log(f"немає файлу з URL ({exc.strerror}) — календар не синкається")
        return 2
    if not urls:
        log("список URL порожній — календар не синкається")
        return 2

    tz = ZoneInfo(args.tz)
    now = dt.datetime.now(tz).replace(tzinfo=None)
    since = dt.datetime.combine(now.date(), dt.time.min)
    until = since + dt.timedelta(days=WINDOW_DAYS)

    events, failed = [], 0
    for idx, url in enumerate(urls, 1):
        # у повідомленнях лише порядковий номер: сам URL — секрет
        try:
            raw = fetch(url, args.timeout)
        except urllib.error.HTTPError as exc:
            log(f"календар {idx}/{len(urls)}: HTTP {exc.code}")
            failed += 1
            continue
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            log(f"календар {idx}/{len(urls)}: мережа недоступна ({type(exc).__name__})")
            failed += 1
            continue
        try:
            got = collect(raw, tz, since, until)
        except Exception as exc:  # битий ICS не має валити решту календарів
            log(f"календар {idx}/{len(urls)}: не розібрався ({type(exc).__name__})")
            failed += 1
            continue
        log(f"календар {idx}/{len(urls)}: {len(got)} подій у вікні")
        events += got

    if failed == len(urls):
        log("жоден календар не відповів — лишаємо попередній local-data.js")
        return 1

    events = dedupe(sorted(relevant(events, now), key=lambda e: e["start"]))[:MAX_EVENTS]
    tmp = args.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(render_js(events, args.tz))
    os.replace(tmp, args.out)
    log(f"записано {len(events)} подій -> {os.path.basename(args.out)}"
        + (f" ({failed} календар(ів) не відповіли)" if failed else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
