#!/bin/bash
# Здоровий = конвеєр відмітився в heartbeat не пізніше ніж MAX_AGE тому.
# Показується в `docker ps`; саме лікування робить watchdog у live-push.sh
# (вихід із кодом 1) плюс restart: always.
set -u
MAX_AGE="${HEARTBEAT_MAX_AGE:-300}"
HB=/app/state/heartbeat
[ -f "$HB" ] || { echo "heartbeat ще не зʼявився"; exit 1; }
age=$(( $(date +%s) - $(cat "$HB" 2>/dev/null || echo 0) ))
[ "$age" -le "$MAX_AGE" ] || { echo "heartbeat протух: ${age}s > ${MAX_AGE}s"; exit 1; }
echo "ok (${age}s)"
