# Checker

Набор автоматических проверок инфраструктуры. Каждая проверка — один скрипт, который можно запустить через `curl | bash`, получает осмысленный exit-код и работает в любом из трёх режимов (`interactive`, `quiet`, `json`) — для интерактивного запуска, cron'а и CI соответственно.

## Доступные проверки

| Категория | Скрипт | Что делает |
|---|---|---|
| `checks/mtu/` | [`check.sh`](checks/mtu/check.sh) | Валидация MTU 1500 end-to-end: detect overlay, CGNAT, MSS clamping |

Подробности по каждой проверке — в README соответствующей подпапки.

## Быстрый запуск

Одноразово, без установки:

```bash
curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh | sudo bash
```

С аргументами:

```bash
curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh | sudo bash -s -- --quiet
curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh | sudo bash -s -- --json
```

Постоянная установка:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh \
    -o /usr/local/bin/mtu-check
sudo chmod +x /usr/local/bin/mtu-check
sudo mtu-check
```

## Общие соглашения

Каждый скрипт в этом репозитории следует одним и тем же конвенциям, чтобы их можно было унифицированно интегрировать в cloud-init, cron и CI.

### Режимы вывода

| Флаг | Назначение |
|---|---|
| (по умолчанию) | Интерактивный цветной вывод с подробностями |
| `--quiet` | Одна строка в формате `[VERDICT] pass=N warn=N fail=N` |
| `--json` | Структурированный JSON-вывод для парсинга |
| `--no-color` | Без ANSI-кодов (для логов) |
| `--help` | Краткое описание скрипта |

### Exit-коды

| Код | Вердикт | Что означает |
|---|---|---|
| `0` | PASS | Все проверки прошли |
| `1` | WARN | Есть отклонения, но не критичные |
| `2` | FAIL | Критичные проблемы, нужно действие |

### Зависимости

Скрипты рассчитаны на типичные Linux-серверы (Ubuntu 22.04+/24.04, Debian 12+). Обычно достаточно того, что уже стоит в базе:

```
iproute2, iputils-ping, iputils-tracepath
```

Каждый скрипт явно сообщает о недостающих зависимостях при запуске.

## Структура репозитория

```
.
├── README.md                       # этот файл
├── LICENSE
└── checks/
    └── mtu/
        ├── check.sh                # сам скрипт
        └── README.md               # подробная документация и runbook
```

Новые проверки добавляются как `checks/<имя>/check.sh` + `checks/<имя>/README.md`.

## Лицензия

MIT — см. [LICENSE](LICENSE).
