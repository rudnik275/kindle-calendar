# Рендер-конвеєр Kindle-дашборда для Synology DSM (x86_64).
# Збирається НА NAS (mac — arm64, образ не переносний): див. install-nas.sh.
#
# Все потрібне зашите в образ навмисно: після ребуту NAS контейнер мусить
# піднятися й малювати навіть якщо інтернету ще немає (роутер вантажиться
# довше за NAS). Жодних apk/pip на старті.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium \
        imagemagick \
        openssh-client \
        python3 python3-pip \
        curl ca-certificates tzdata fontconfig fonts-liberation \
    && pip3 install --no-cache-dir --break-system-packages \
        icalendar recurring-ical-events \
    && apt-get purge -y python3-pip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* /root/.cache

# Europe/Kyiv — валідна зона у сучасній tzdata. (Обережно: на самій книзі
# next-wakeup знає Київ лише як Europe/Kiev — це стосується прошивки 2011,
# не цього контейнера.)
ENV TZ=Europe/Kyiv \
    CHROME_BIN=/usr/bin/chromium \
    PYTHONUNBUFFERED=1

COPY entrypoint.sh healthcheck.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

WORKDIR /app
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
