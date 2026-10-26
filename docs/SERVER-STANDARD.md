# Стандарт VPS и bootstrap

Нормативная спецификация для `scripts/bootstrap.sh`, `vpsctl-deploy` и коллектора. Источник — SPEC §6–7. Ключевые слова: **ДОЛЖЕН** — обязательно; **НЕ ДОЛЖЕН** — запрещено. Ссылки ADR-NNN — решения из docs/DECISIONS.md.

Версия стандарта: `1` (пишется в `/etc/vpsctl/server.yml`).

## 1. Поддерживаемые ОС

- Ubuntu 24.04 LTS, Ubuntu 26.04 LTS (`/etc/os-release`: `ID=ubuntu`, `VERSION_ID` ∈ {`24.04`, `26.04`}).
- На любой другой ОС bootstrap ДОЛЖЕН завершиться с ненулевым кодом и сообщением до любых изменений системы.

## 2. Пользователи и права

| Субъект | Требование |
| --- | --- |
| `deploy` | Существует; вход только по ключу; в группе `docker`; домашний каталог `/home/deploy`; `~/.ssh` 700, `authorized_keys` 600, владелец `deploy` |
| sudo для `deploy` | Только `/usr/local/sbin/vpsctl-root` (NOPASSWD), файл `/etc/sudoers.d/vpsctl-deploy` 440, проходит `visudo -c`. Других команд через sudo НЕ ДОЛЖНО быть (ADR-031) |
| `root` | Вход по SSH отключен после bootstrap |
| Группа `docker` | Эквивалентна root → доступ к `deploy` защищается как к root |

## 3. Файловая система

| Путь | Владелец | Права | Назначение |
| --- | --- | --- | --- |
| `/opt` | `deploy` | 755 | Корень проектов |
| `/opt/<проект>/app/` | `deploy` | 755 | git-клон: Dockerfile, compose.yml, vpsctl.yml |
| `/opt/<проект>/.env` | `deploy` | 600 | Секреты; подключается через `env_file` |
| `/opt/<проект>/data/` | `deploy` | 755 | Тома контейнеров |
| `/opt/<проект>/releases.log` | `deploy` | 644 | История деплоев |
| `/etc/vpsctl/server.yml` | `root` | 644 | Версия стандарта, дата bootstrap |
| `/usr/local/bin/vpsctl-deploy` | `root` | 755 | Единый скрипт деплоя |
| `/usr/local/bin/vpsctl-collect` | `root` | 755 | Коллектор состояния (ADR-035) |
| `/usr/local/sbin/vpsctl-root` | `root` | 755 | Привилегированные действия, фиксированные подкоманды (ADR-031) |
| `/usr/local/bin/yq` | `root` | 755 | Чтение YAML, фиксированная версия (ADR-033) |

`<проект>` — имя из `vpsctl.yml` (`name`); допустимые символы `[a-z0-9-]`, начинается с буквы. Ограничение вводится стандартом, т. к. имя используется в путях, именах compose-проектов и конфигов nginx.

### `/etc/vpsctl/server.yml`

```yaml
standard_version: 1          # версия стандарта
bootstrap_version: 0.1.0     # версия скрипта bootstrap из репозитория vpsctl
bootstrapped_at: 2026-10-26T12:00:00Z   # первый успешный bootstrap (UTC, RFC 3339)
updated_at: 2026-10-26T12:00:00Z        # последний успешный запуск
```

### `releases.log`

Одна строка на деплой, поля через табуляцию: `<RFC 3339 UTC>\t<commit sha>\t<result>\t<message>`; `result` ∈ {`ok`, `failed`, `rolled_back`}.

## 4. Запуск проектов

- Все проекты — Docker Compose; имя compose-проекта `vpsctl-<проект>`.
- Все сервисы ДОЛЖНЫ иметь `restart: unless-stopped`.
- Порты публикуются только на `127.0.0.1`.
- Отдельные systemd-юниты на проекты НЕ ДОЛЖНЫ создаваться; `docker.service` включен (`systemctl is-enabled docker` = `enabled`).

| Шаблон | Compose | Доступ снаружи |
| --- | --- | --- |
| `bot` | Один контейнер, без `ports` | Нет |
| `web` | Приложение, `127.0.0.1:<port>:<port>` | nginx → домен + SSL |
| `web+db` | Приложение + PostgreSQL; данные БД в `data/`; БД без `ports`, только внутренняя сеть | nginx → домен |
| `static` | Multi-stage Dockerfile, nginx-контейнер на `127.0.0.1:<port>` | nginx → домен + SSL |

Проект без домена (F-16, ADR-032): внешний порт из диапазона 8100–8199 (первый свободный при первом деплое, далее не меняется); host-nginx слушает его и проксирует на `127.0.0.1:<port>`; порт открывается в ufw и закрывается при удалении проекта; без SSL.

`web+db` (ADR-039): при первом деплое `vpsctl-deploy` генерирует случайный `POSTGRES_PASSWORD` и `DATABASE_URL` и дописывает в `.env`, если их нет; существующие значения не перезаписываются.

## 5. Сеть

- nginx — reverse proxy; один файл на проект: `/etc/nginx/sites-available/vpsctl-<проект>.conf`. Способ активации (symlink в `sites-enabled`) в SPEC не указан — принимается стандартный для Ubuntu symlink `/etc/nginx/sites-enabled/vpsctl-<проект>.conf`.
- Перед reload nginx ДОЛЖЕН выполняться `nginx -t`; при ошибке конфиг откатывается.
- SSL — certbot (Let's Encrypt), автообновление системным таймером `certbot.timer`.
- Перед выпуском сертификата ДОЛЖНО проверяться, что A-запись домена указывает на IP сервера; иначе выпуск не выполняется (F-17).
- ufw включен; разрешены: текущий SSH-порт (bootstrap его не меняет, ADR-040), 80/tcp, 443/tcp, порты проектов без домена из 8100–8199; политика по умолчанию — deny incoming.
- Изменения nginx, ufw и certbot выполняются только через `sudo vpsctl-root <подкоманда>`.

## 6. Bootstrap

Запуск: от root по SSH из `vpsctl`. Способ А — вход по root-паролю или ключу хостера. Способ Б — пользователь вставляет в веб-консоль хостера однострочник, который только добавляет его публичный ключ в `authorized_keys` root; дальше как способ А (ADR-034).

Повторный запуск после отключения root-входа — под `deploy`: `sudo vpsctl-root bootstrap` (ADR-031).

Общие требования:

- bash, `set -euo pipefail`, `shellcheck` без предупреждений.
- Каждый шаг: «проверить → если уже сделано, вывести `skip` → иначе сделать → проверить результат». Повторный запуск на готовом сервере ДОЛЖЕН завершаться с кодом 0 без изменений (F-04).
- Вывод построчный, с префиксом шага (`[step N] ...`), чтобы клиент мог показывать его в реальном времени.
- Входные параметры — аргументы/переменные окружения, без интерактивных вопросов: публичный ключ `deploy`; флаг отключения unattended-upgrades (по умолчанию включены, ADR-040).
- Пароли НЕ ДОЛЖНЫ записываться на диск или в лог.

| Шаг | Действие | Проверка «уже сделано» |
| --- | --- | --- |
| 1 | Проверить ОС (раздел 1) | — (всегда) |
| 2 | `apt-get update`; установить git, nginx, certbot, ufw, curl; Docker Engine и `docker-compose-plugin` из официального репозитория Docker; `yq` фиксированной версии с проверкой sha256 | `dpkg-query` по каждому пакету; наличие apt-источника Docker и ключа; `yq --version` совпадает |
| 3 | Создать `deploy`, положить ключ, добавить в `docker`, sudoers на `vpsctl-root` по разделу 2 | `id deploy`; ключ присутствует в `authorized_keys` (без дублей); членство в группе; содержимое sudoers совпадает |
| 4 | ufw: SSH-порт, 80, 443; включить | `ufw status` содержит правила; статус active |
| 5 | `sshd_config`: `PermitRootLogin no`, `PasswordAuthentication no` (drop-in `/etc/ssh/sshd_config.d/`); `sshd -t`; проверить вход под `deploy` по ключу; только потом перезапустить sshd | Значения в `sshd -T`; если вход под `deploy` не подтвержден — НЕ перезапускать sshd и завершиться с ошибкой |
| 6 | `/opt` (владелец `deploy`), `/etc/vpsctl/server.yml`, установить `vpsctl-deploy`, `vpsctl-collect`, `vpsctl-root` | Владелец/права; версия установленного скрипта совпадает с версией в репозитории |
| 7 | Включить unattended-upgrades для обновлений безопасности (по умолчанию; флаг отключает) | Пакет установлен, `/etc/apt/apt.conf.d/20auto-upgrades` настроен |

## 7. `vpsctl-deploy`

Единая точка деплоя для TUI и GitHub Actions. Запускается под `deploy`.

- Вход: имя проекта (+ URL репозитория и ветка при первом деплое).
- Читает `/opt/<проект>/app/vpsctl.yml` через `yq` (ADR-033).
- nginx, SSL и откат добавляются в этапе 4 (ADR-037).
- Если `image` задан — `docker compose pull` + `up -d`; иначе — сборка на сервере (`up -d --build`).
- Проверяет наличие всех ключей `env` в `.env`; при отсутствии — ошибка до запуска.
- Пишет строку в `releases.log` при любом исходе.
- Код выхода 0 — только при успешном запуске (и healthcheck, если задан — F-12).

## 8. Манифест `vpsctl.yml` (формат v1)

| Поле | Тип | Обязательное | Описание |
| --- | --- | --- | --- |
| `name` | string | да | Имя проекта (правило из раздела 3) |
| `template` | enum | да | `bot` \| `web` \| `web+db` \| `static` |
| `compose` | string | да | Путь к compose-файлу относительно корня репозитория |
| `image` | string \| null | нет | Образ в GHCR; `null` или нет поля — сборка на сервере |
| `env` | string[] | нет | Ключи, которые запрашиваются при деплое; формат `[A-Z_][A-Z0-9_]*` |
| `domain` | string \| null | нет | Домен (hostname); `null` — доступ по IP:порт (ADR-032) |
| `port` | int \| null | для `web`, `web+db`, `static` | Порт 1–65535 на 127.0.0.1 для nginx; у `bot` — `null` |
| `healthcheck` | string \| null | нет | URL, например `http://127.0.0.1:8080/health` |

Пример (шаблон `bot`, `templates/bot/vpsctl.yml`):

```yaml
name: my-bot
template: bot
compose: compose.yml
image: null
env:
  - BOT_TOKEN
domain: null
port: null
healthcheck: null
```

Требования к compose-файлу проекта (шаблоны — `templates/<шаблон>/compose.yml`):

- Запускается из `/opt/<проект>/app/` под именем проекта `vpsctl-<проект>`; поле `name:` в compose не задается.
- У каждого сервиса `restart: unless-stopped`.
- Сервисы приложения подключают секреты через `env_file: ../.env` (файл `/opt/<проект>/.env`).
- Порты — только `127.0.0.1:<port>:<container-port>`; у `bot` портов нет; для `web`, `web+db`, `static` один из портов публикуется на `port` из манифеста.
- Образ приложения: `build: .` и `image: ${VPSCTL_IMAGE:-vpsctl-<проект>:local}` (ADR-048). `vpsctl-deploy` передает `VPSCTL_IMAGE` из поля `image` манифеста и делает `pull` + `up -d`; при `image: null` переменная не задается, образ собирается на сервере (`up -d --build`) с тегом по умолчанию.

Проверка шаблонов — `tests/templates/check.sh` (CI-job `templates`).
