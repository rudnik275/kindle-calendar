#!/bin/bash
# Заливка PNG на Kindle і перемальовка e-ink повним refresh'ем.
# Книга: 192.168.0.150, алiас `kindle` у ~/.ssh/kindle.conf (legacy-алгоритми).
# scp на книзі немає — заливаємо через `cat >`. Джерело екрана для dash-циклу:
# /mnt/us/dashboard/local/screen.png (його копіює fetch-dashboard.sh).
# Використання: ./push-to-kindle.sh [file.png]
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
F="${1:-$DIR/out/dash.png}"

ssh -F ~/.ssh/kindle.conf kindle 'cat > /mnt/us/dashboard/local/screen.png' < "$F"
ssh -F ~/.ssh/kindle.conf kindle \
  'cp /mnt/us/dashboard/local/screen.png /mnt/us/dashboard/dash.png && /usr/sbin/eips -f -g /mnt/us/dashboard/dash.png && echo OK'
