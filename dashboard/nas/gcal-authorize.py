#!/usr/bin/env python3
"""Одноразова авторизація: обміняти згоду Google на refresh-токен.

Навіщо: робочий календар Novaposhta не віддає приватний iCal (адмін вимкнув
зовнішній доступ), але власнику ніхто не забороняв читати власний календар.
Тож конвеєр стає звичайним календарним клієнтом — рівно як застосунок на
планшеті — і ходить в API під самим робочим акаунтом.

Запускати на маку (потрібен браузер для згоди), один раз на акаунт:

    dashboard/nas/gcal-authorize.py \
        --client dashboard/secret/google-oauth-client.json \
        --out    dashboard/secret/gcal-token-work.json \
        --label  work

Далі токен їде на NAS через nas/install-nas.sh (або вручну, `tee`).

Секрети: ні client_secret, ні код, ні токени НЕ друкуються — у stdout іде
тільки URL згоди (у ньому лише client_id, він не секретний) і статус.
Файл результату створюється з правами 0600.
"""
import argparse
import http.server
import json
import os
import secrets
import socket
import threading
import urllib.parse
import urllib.request

SCOPE = "https://www.googleapis.com/auth/calendar.readonly"
AUTH = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN = "https://oauth2.googleapis.com/token"

_result = {}


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        _result.update({k: v[0] for k, v in q.items()})
        ok = "code" in q and q.get("state", [None])[0] == _result.get("_state")
        body = ("<h2>Готово. Можна закрити вкладку.</h2>" if ok
                else "<h2>Щось пішло не так — подивись у термінал.</h2>")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(body.encode())
        threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, *a):
        pass          # не світимо код авторизації в логах


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--client", required=True, help="JSON OAuth-клієнта з Google Cloud")
    ap.add_argument("--out", required=True, help="куди покласти токен (0600)")
    ap.add_argument("--label", default="", help="підпис акаунта, лише для читабельності")
    ap.add_argument("--login-hint", default="", help="який акаунт підставити у форму згоди")
    args = ap.parse_args()

    with open(args.client, encoding="utf-8") as fh:
        conf = json.load(fh)
    conf = conf.get("installed") or conf.get("web") or conf
    cid, csec = conf["client_id"], conf["client_secret"]

    port = free_port()
    redirect = f"http://127.0.0.1:{port}"
    state = secrets.token_urlsafe(24)
    _result["_state"] = state

    params = {
        "client_id": cid,
        "redirect_uri": redirect,
        "response_type": "code",
        "scope": SCOPE,
        "access_type": "offline",     # без цього refresh-токена не буде
        "prompt": "consent",          # примусово, інакше Google його не поверне вдруге
        "state": state,
    }
    if args.login_hint:
        params["login_hint"] = args.login_hint

    print("Відкрий цей URL і дай згоду потрібним акаунтом:\n")
    print(f"{AUTH}?{urllib.parse.urlencode(params)}\n")
    print(f"Чекаю на відповідь на {redirect} ...")

    srv = http.server.HTTPServer(("127.0.0.1", port), Handler)
    srv.serve_forever()

    if "error" in _result:
        print(f"Google відмовив: {_result['error']}")
        return 1
    if "code" not in _result:
        print("Код не отримано.")
        return 1

    data = urllib.parse.urlencode({
        "code": _result["code"], "client_id": cid, "client_secret": csec,
        "redirect_uri": redirect, "grant_type": "authorization_code",
    }).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(TOKEN, data=data), timeout=30) as r:
            tok = json.load(r)
    except urllib.error.HTTPError as e:
        # тіло помилки може містити чутливе — показуємо лише код
        print(f"Обмін коду не вдався: HTTP {e.code}")
        return 1

    if "refresh_token" not in tok:
        print("Google не віддав refresh_token. Найчастіша причина — згода вже "
              "давалась раніше; відкликай доступ на myaccount.google.com/permissions "
              "і повтори.")
        return 1

    out = {
        "label": args.label,
        "client_id": cid,
        "client_secret": csec,
        "refresh_token": tok["refresh_token"],
    }
    fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=2)
    print(f"✅ refresh-токен збережено -> {args.out} (0600). Значення не друкую.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
