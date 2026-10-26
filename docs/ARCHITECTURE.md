# Архитектура vpsctl

Источник требований — docs/SPEC.md; стандарт сервера — docs/SERVER-STANDARD.md. Документ описывает целевую структуру; пакеты появляются по мере выполнения задач из docs/PLAN.md. Пометка `[Q-n]` — зависит от открытого вопроса в PLAN.md.

## 1. Компоненты

```
┌────────────── клиент (Linux, один бинарник) ──────────────┐
│  TUI (Bubble Tea)  ──►  app/service  ──►  sshx (x/crypto/ssh)│──── SSH ────►┌──────── VPS ────────────────────┐
│        ▲                     │                               │              │ коллектор  → JSON в stdout      │
│        └── модели состояния ◄┘  config (YAML), journal       │◄─── stdout ──│ vpsctl-deploy → построчный лог  │
└──────────────────────────────────────────────────────────────┘              │ docker / nginx / certbot / ufw  │
                                                                              └─────────────────────────────────┘
GitHub Actions ── SSH (ключ из secrets) ──► vpsctl-deploy        GHCR ◄── docker compose pull (сервер)
```

- Постоянного агента на сервере нет (ADR-006).
- Клиент не парсит вывод системных утилит: всё состояние — JSON коллектора.
- Изменения на сервере выполняют только скрипты из `scripts/` (bootstrap, `vpsctl-deploy`) — один код для TUI и CI.

## 2. Структура репозитория

| Путь | Содержимое |
| --- | --- |
| `cmd/vpsctl/` | `main`: разбор флагов (`--version`), запуск TUI |
| `internal/config/` | Реестр серверов и настройки клиента: загрузка/сохранение YAML, валидация, атомарная запись |
| `internal/sshconfig/` | Чтение `~/.ssh/config` (Host, HostName, Port, User, IdentityFile) для импорта/переиспользования |
| `internal/sshx/` | SSH-клиент: ключи, ssh-agent, пароль (только в памяти), known_hosts, таймауты, выполнение команд со стримингом stdout/stderr, загрузка файлов через stdin |
| `internal/collector/` | Go-типы JSON коллектора, декодирование, проверка `schema_version`, доставка/обновление скрипта на сервер |
| `internal/poller/` | Параллельный опрос серверов, изоляция ошибок, кэш последнего состояния |
| `internal/manifest/` | Типы и валидация `vpsctl.yml` |
| `internal/templates/` | `embed` шаблонов из `templates/` и их рендер |
| `internal/bootstrap/` | Запуск bootstrap (способы А и Б), генерация однострочника |
| `internal/deploy/` | Вызов `vpsctl-deploy`, deploy keys, `.env`, логи, управление проектом |
| `internal/journal/` | Локальный журнал действий (F-20) |
| `internal/tui/` | Корневая модель, роутинг экранов, keymap, стили (fallback 16 цветов) |
| `internal/tui/screens/{servers,server,project,logs,wizard}/` | Экраны из SPEC §8 |
| `scripts/bootstrap.sh` | Bootstrap VPS |
| `scripts/vpsctl-deploy` | Скрипт деплоя (ставится в `/usr/local/bin/`) |
| `scripts/vpsctl-collect` | Коллектор `[Q-7]` |
| `scripts/lib/` | Общие bash-функции (лог, проверка ОС, идемпотентные хелперы) |
| `templates/{bot,web,web-db,static}/` | `compose.yml`, `vpsctl.yml`, при необходимости `Dockerfile`, nginx-шаблон |
| `templates/github-actions/` | Workflow автодеплоя (этап 5) |
| `tests/scripts/` | Тесты скриптов в Docker `ubuntu:24.04` / `ubuntu:26.04` |

Каталог шаблона `web+db` называется `web-db`: `+` неудобен в путях и именах Go-embed; имя шаблона в манифесте остается `web+db`.

Зависимости (кандидаты, добавляются в задачах с обоснованием): `github.com/charmbracelet/bubbletea`, `bubbles`, `lipgloss`, `golang.org/x/crypto/ssh` (+ `knownhosts`, `agent`), YAML-библиотека, парсер `ssh_config`.

## 3. Потоки данных

### 3.1 Обзор сервера (F-05…F-09)

1. `poller` для каждого сервера параллельно (с ограничением конкурентности) открывает SSH-сессию через `sshx`.
2. `sshx` проверяет отпечаток по `known_hosts` (F-02); несовпадение — ошибка `HostKeyChanged`, подключение блокируется до подтверждения в UI.
3. Клиент запускает `vpsctl-collect --version`; если версия отличается от встроенной в бинарник — передает новый скрипт через stdin и устанавливает `[Q-7]`.
4. Запуск коллектора; stdout — один JSON-документ, stderr — диагностика.
5. `collector` декодирует JSON; ошибки отдельных секций приходят в `errors[]` и не ломают остальные.
6. Результат отправляется в TUI сообщением `ServerStateMsg{server, state, err}`; ошибка одного сервера отображается только в его строке.

Целевое время: ≤ 3 с на сервер (SPEC §10).

### 3.2 Bootstrap (F-03, F-04)

Способ А: подключение под root (пароль или ключ хостера) → подтверждение отпечатка → `bootstrap.sh` передается через stdin `bash -s -- <args>` → stdout стримится в TUI → проверка входа под `deploy` → чтение `/etc/vpsctl/server.yml` → статус «готов».
Способ Б: генерация однострочника `[Q-6]`.

### 3.3 Деплой (F-10…F-17)

Мастер собирает репозиторий, ветку, значения `.env`, домен → `.env` передается через stdin и записывается с правами 600 (значения не попадают в журнал и на диск клиента) → вызов `vpsctl-deploy` → построчный вывод в TUI → журнал.

## 4. Формат JSON коллектора (черновик, schema_version 1)

```json
{
  "schema_version": 1,
  "collector_version": "0.1.0",
  "collected_at": "2026-10-26T12:00:00Z",
  "host": {
    "hostname": "vps-1",
    "os": "Ubuntu 24.04.1 LTS",
    "kernel": "6.8.0-45-generic",
    "uptime_seconds": 123456,
    "standard": { "standard_version": 1, "bootstrap_version": "0.1.0" },
    "pending_updates": { "total": 12, "security": 3 }
  },
  "resources": {
    "cpu": { "cores": 2, "load1": 0.15, "load5": 0.10, "load15": 0.05 },
    "memory": { "total_bytes": 2147483648, "used_bytes": 1073741824, "available_bytes": 1073741824 },
    "swap": { "total_bytes": 0, "used_bytes": 0 },
    "disks": [ { "mount": "/", "fs": "ext4", "total_bytes": 32212254720, "used_bytes": 8589934592 } ],
    "docker": { "root_dir": "/var/lib/docker", "used_bytes": 4294967296 }
  },
  "projects": [
    {
      "name": "my-bot",
      "path": "/opt/my-bot",
      "managed": true,
      "template": "bot",
      "domain": null,
      "size_bytes": 104857600,
      "git": { "branch": "main", "commit": "a1b2c3d", "commit_date": "2026-10-25T10:00:00Z", "subject": "fix: ..." },
      "status": "running",
      "containers": [ { "name": "vpsctl-my-bot-app-1", "service": "app", "state": "running", "health": "healthy", "restarts": 0 } ]
    }
  ],
  "unmanaged": {
    "dirs": [ { "path": "/opt/legacy", "size_bytes": 1048576 } ],
    "containers": [ { "name": "old-app", "image": "nginx:1.27", "state": "running", "compose_project": "legacy" } ]
  },
  "domains": [
    { "domain": "app.example.com", "nginx_file": "/etc/nginx/sites-enabled/vpsctl-my-web.conf", "project": "my-web", "ssl_not_after": "2027-01-20T00:00:00Z" }
  ],
  "ports": [
    { "proto": "tcp", "address": "0.0.0.0", "port": 443, "process": "nginx", "container": null }
  ],
  "errors": [ { "section": "ports", "message": "permission denied" } ]
}
```

Правила:

- `status` проекта: `running` (все контейнеры running), `stopped` (нет запущенных), `failed` (есть exited с ненулевым кодом / restarting / unhealthy).
- `managed: true` ⇔ есть `/opt/<проект>/app/vpsctl.yml` (ADR-021); иначе папка попадает в `unmanaged.dirs`. Контейнеры без compose-проекта `vpsctl-*` — в `unmanaged.containers`.
- Размеры — байты, время — RFC 3339 UTC, отсутствующее значение — `null`.
- Чтение сертификатов и процессов портов под `deploy` `[Q-5]`.

## 5. Конфиги клиента

`~/.config/vpsctl/` (учитывается `$XDG_CONFIG_HOME`):

```yaml
# servers.yml — реестр (F-01); без секретов
version: 1
servers:
  - name: vps-1
    host: 203.0.113.10
    port: 22
    user: deploy
    identity_file: ~/.ssh/id_ed25519   # опционально; иначе ssh-agent
    ssh_config_host: null               # опционально: имя Host из ~/.ssh/config
```

```yaml
# config.yml — настройки клиента
version: 1
known_hosts: ~/.ssh/known_hosts
parallelism: 4
connect_timeout: 5s
```

- Кэш состояния: `$XDG_CACHE_HOME/vpsctl/state/<server>.json` — только для быстрого старта (ADR-008).
- Журнал (F-20): `$XDG_STATE_HOME/vpsctl/journal.log`, JSON Lines: `{"time","server","project","action","result","error"}`; значения секретов не пишутся.
- Запись конфигов атомарная (временный файл + rename), права 600.

## 6. Манифест и стандарт сервера

Формат `vpsctl.yml`, `/etc/vpsctl/server.yml`, `releases.log` — docs/SERVER-STANDARD.md, разделы 3 и 8.
