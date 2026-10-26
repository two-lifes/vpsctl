# Стандарт VPS и bootstrap

Нормативная спецификация для `scripts/bootstrap.sh`, `vpsctl-deploy` и коллектора. Источник — SPEC §6–7. Ключевые слова: **ДОЛЖЕН** — обязательно; **НЕ ДОЛЖЕН** — запрещено. Пункты, помеченные `[Q-n]`, зависят от открытого вопроса из docs/PLAN.md «Вопросы» и до ответа не реализуются.

Версия стандарта: `1` (пишется в `/etc/vpsctl/server.yml`).

## 1. Поддерживаемые ОС

- Ubuntu 24.04 LTS, Ubuntu 26.04 LTS (`/etc/os-release`: `ID=ubuntu`, `VERSION_ID` ∈ {`24.04`, `26.04`}).
- На любой другой ОС bootstrap ДОЛЖЕН завершиться с ненулевым кодом и сообщением до любых изменений системы.

## 2. Пользователи и права

| Субъект | Требование |
| --- | --- |
| `deploy` | Существует; вход только по ключу; в группе `docker`; домашний каталог `/home/deploy`; `~/.ssh` 700, `authorized_keys` 600, владелец `deploy` |
| sudo для `deploy` | Только `nginx -t`, reload nginx, `certbot` (NOPASSWD), файл `/etc/sudoers.d/vpsctl-deploy` 440, проходит `visudo -c`. Shell под root НЕ ДОЛЖЕН быть доступен. `[Q-1]` `[Q-2]` |
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
| Коллектор | `root` | 755 | Путь не определен в SPEC `[Q-7]` |

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

Проект без домена (F-16): доступ по `http://IP:порт` через nginx, порт открывается в ufw, без SSL. `[Q-3]`

## 5. Сеть

- nginx — reverse proxy; один файл на проект: `/etc/nginx/sites-available/vpsctl-<проект>.conf`. Способ активации (symlink в `sites-enabled`) в SPEC не указан — принимается стандартный для Ubuntu symlink `/etc/nginx/sites-enabled/vpsctl-<проект>.conf`.
- Перед reload nginx ДОЛЖЕН выполняться `nginx -t`; при ошибке конфиг откатывается.
- SSL — certbot (Let's Encrypt), автообновление системным таймером `certbot.timer`.
- Перед выпуском сертификата ДОЛЖНО проверяться, что A-запись домена указывает на IP сервера; иначе выпуск не выполняется (F-17).
- ufw включен; разрешены: текущий SSH-порт `[Q-12]`, 80/tcp, 443/tcp; политика по умолчанию — deny incoming.

## 6. Bootstrap

Запуск: от root (способ А — из `vpsctl` по SSH; способ Б — однострочник в веб-консоли хостера `[Q-6]`).

Общие требования:

- bash, `set -euo pipefail`, `shellcheck` без предупреждений.
- Каждый шаг: «проверить → если уже сделано, вывести `skip` → иначе сделать → проверить результат». Повторный запуск на готовом сервере ДОЛЖЕН завершаться с кодом 0 без изменений (F-04).
- Вывод построчный, с префиксом шага (`[step N] ...`), чтобы клиент мог показывать его в реальном времени.
- Входные параметры — аргументы/переменные окружения, без интерактивных вопросов: публичный ключ `deploy`, флаг unattended-upgrades `[Q-12]`.
- Пароли НЕ ДОЛЖНЫ записываться на диск или в лог.

| Шаг | Действие | Проверка «уже сделано» |
| --- | --- | --- |
| 1 | Проверить ОС (раздел 1) | — (всегда) |
| 2 | `apt-get update`; установить git, nginx, certbot, ufw, curl; Docker Engine и `docker-compose-plugin` из официального репозитория Docker | `dpkg-query` по каждому пакету; наличие apt-источника Docker и ключа |
| 3 | Создать `deploy`, положить ключ, добавить в `docker`, sudoers по разделу 2 | `id deploy`; ключ присутствует в `authorized_keys` (без дублей); членство в группе; содержимое sudoers совпадает |
| 4 | ufw: SSH-порт, 80, 443; включить | `ufw status` содержит правила; статус active |
| 5 | `sshd_config`: `PermitRootLogin no`, `PasswordAuthentication no` (drop-in `/etc/ssh/sshd_config.d/`); `sshd -t`; проверить вход под `deploy` по ключу; только потом перезапустить sshd | Значения в `sshd -T`; если вход под `deploy` не подтвержден — НЕ перезапускать sshd и завершиться с ошибкой |
| 6 | `/opt` (владелец `deploy`), `/etc/vpsctl/server.yml`, установить `vpsctl-deploy` (и коллектор `[Q-7]`) | Владелец/права; версия установленного скрипта совпадает с версией в репозитории |
| 7 | По флагу: включить unattended-upgrades для обновлений безопасности | Пакет установлен, `/etc/apt/apt.conf.d/20auto-upgrades` настроен |

Повторный запуск после шага 5 (root-вход отключен) `[Q-1]`.

## 7. `vpsctl-deploy`

Единая точка деплоя для TUI и GitHub Actions. Запускается под `deploy`.

- Вход: имя проекта (+ URL репозитория и ветка при первом деплое).
- Читает `/opt/<проект>/app/vpsctl.yml` `[Q-4]`.
- Если `image` задан — `docker compose pull` + `up -d`; иначе — сборка на сервере (`up -d --build`).
- Проверяет наличие всех ключей `env` в `.env`; при отсутствии — ошибка до запуска.
- Пишет строку в `releases.log` при любом исходе.
- Код выхода 0 — только при успешном запуске (и healthcheck, если задан — F-12).

## 8. Манифест `vpsctl.yml` (формат v1, черновик SPEC)

| Поле | Тип | Обязательное | Описание |
| --- | --- | --- | --- |
| `name` | string | да | Имя проекта (правило из раздела 3) |
| `template` | enum | да | `bot` \| `web` \| `web+db` \| `static` |
| `compose` | string | да | Путь к compose-файлу в репозитории |
| `image` | string \| null | нет | Образ в GHCR; `null` — сборка на сервере |
| `env` | string[] | нет | Ключи, которые запрашиваются при деплое |
| `domain` | string \| null | нет | Домен; `null` — доступ по IP:порт |
| `port` | int \| null | для `web`, `web+db`, `static` | Порт на 127.0.0.1 для nginx |
| `healthcheck` | string \| null | нет | URL, например `http://127.0.0.1:8080/health` |
