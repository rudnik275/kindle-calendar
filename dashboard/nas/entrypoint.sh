#!/bin/bash
# Готує оточення й віддає керування живому конвеєру.
#
# Ключ копіюємо з бінд-маунта у власну ФС контейнера: на шарі Synology діють
# ACL, і 0600 там не гарантований, а ssh відмовиться брати «занадто відкритий»
# приватний ключ. Копія всередині контейнера — завжди 0600.
set -euo pipefail

install -d -m 700 /root/.ssh

if [ -f /app/ssh/kindle-dash ]; then
  install -m 600 /app/ssh/kindle-dash /root/.ssh/kindle-dash
else
  echo "entrypoint: немає /app/ssh/kindle-dash — пушити на книгу нічим" >&2
  exit 1
fi

# known_hosts лежить на бінд-маунті, щоб пережити перестворення контейнера
touch /app/ssh/kindle_known_hosts 2>/dev/null || true

cat > /root/.ssh/kindle.conf <<'CONF'
# dropbear 0.53 (2011) вміє лише алгоритми, які сучасний OpenSSH вимикає
# за замовчуванням — звідси явний легасі-набір.
Host kindle
    HostName 192.168.0.150
    User root
    IdentityFile /root/.ssh/kindle-dash
    IdentitiesOnly yes
    UserKnownHostsFile /app/ssh/kindle_known_hosts
    StrictHostKeyChecking accept-new
    ConnectTimeout 15
    ServerAliveInterval 20
    KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
    Ciphers +aes128-ctr,aes128-cbc,3des-cbc
    MACs +hmac-sha1
CONF
chmod 600 /root/.ssh/kindle.conf

# Хост книги можна перевизначити, не перезбираючи образ
if [ -n "${KINDLE_HOST:-}" ]; then
  sed -i "s/^    HostName .*/    HostName $KINDLE_HOST/" /root/.ssh/kindle.conf
fi

export SSH_CONF=/root/.ssh/kindle.conf
exec bash /app/live-push.sh
