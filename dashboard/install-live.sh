#!/bin/bash
# Деплой живого конвеєра «мак → Kindle»:
#   1) копіює рендер-бандл із цього git-каталогу в ~/kindle-dash-live
#      (рантайм навмисно відв'язаний від git-дерева — перемикання гілок,
#      мерджі й worktree-чистки не чіпають працюючий демон);
#   2) ставить launchd-агента com.rudnik.kindle-dash (RunAtLoad + KeepAlive):
#      старт при логіні, рестарт при падінні.
# Перевстановлення після зміни шаблону/скриптів: просто запусти ще раз.
# Зняти повністю: launchctl bootout gui/$(id -u)/com.rudnik.kindle-dash
#                 && rm -rf ~/kindle-dash-live ~/Library/LaunchAgents/com.rudnik.kindle-dash.plist
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$HOME/kindle-dash-live"
PLIST="$HOME/Library/LaunchAgents/com.rudnik.kindle-dash.plist"
LABEL="com.rudnik.kindle-dash"

mkdir -p "$DEPLOY"
cp "$SRC/template.html" "$SRC/night.html" "$SRC/render.sh" "$SRC/live-push.sh" "$DEPLOY/"
rsync -a --delete "$SRC/art/" "$DEPLOY/art/"
# дані подій: беремо з git-каталогу, якщо там свіжіші (файл gitignored)
[ -f "$SRC/local-data.js" ] && cp "$SRC/local-data.js" "$DEPLOY/"
[ -f "$DEPLOY/local-data.js" ] || echo 'window.DASH_DATA = { events: [] };' > "$DEPLOY/local-data.js"
chmod +x "$DEPLOY/render.sh" "$DEPLOY/live-push.sh"

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>$DEPLOY/live-push.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardErrorPath</key><string>$DEPLOY/live-push.launchd.log</string>
</dict></plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
launchctl print "gui/$(id -u)/$LABEL" | grep -E "state|pid" | head -3
echo "OK: демон працює, лог: $DEPLOY/live-push.log"
