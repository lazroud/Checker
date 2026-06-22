# FLOWXE — Runbook: проверка MTU нод

Автоматический скрипт `flowxe-mtu-check.sh` для валидации сетевой конфигурации нод. Подтверждает, что MTU 1500 проходит end-to-end, определяет наличие overlay-сетей, CGNAT и MSS clamping.

## Зачем это нужно

Часть выходных нод FLOWXE сидит на хостингах с провайдерскими overlay-сетями (VXLAN, SDN, CGNAT). На таких нодах MTU режется ещё до публичной сети, что:

- понижает реальный throughput из-за фрагментации,
- даёт характерный TCP-фингерпринт (MTU < 1500), по которому внешние сервисы детектируют подключение как VPN,
- не лечится никаким тюнингом на стороне ОС — overlay физически дропает большие фреймы.

Этот скрипт — go/no-go проверка для:

- ввода новой ноды в продакшен (запускать ДО подключения к Remnawave),
- периодического аудита существующих нод (cron раз в неделю),
- быстрой диагностики жалоб на скорость.

## Что проверяется

| Проверка | Что ищет | На что влияет |
|---|---|---|
| Interface MTU | MTU на default-интерфейсе | База — должен быть 1500 |
| Gateway analysis | CGNAT (`100.64.0.0/10`), RFC1918 как default gw | Признак overlay у провайдера |
| Tunnel interfaces | tun / vxlan / geneve / gre / wireguard | Скрытые туннели |
| MSS clamping | iptables / nftables MSS-правила | Локальные ограничения |
| Cached PMTU | `ip route get` cache | Что ядро уже выучило |
| Tracepath PMTU | Где в пути PMTU проседает | Локализация проблемы |
| **DF ping** | **1472B + DF до публичных целей** | **Главная проверка** |
| Active TCP MSS | MSS в живых соединениях | Что реально получают Xray/системные процессы |

Главная — **don't-fragment ping**. Если 1500-байтные пакеты с DF не доходят до Cloudflare/Google/Quad9, никакие `sysctl`-настройки не помогут.

## Установка

На каждой ноде (RU, FI, DE и т.д.):

```bash
sudo curl -fsSL https://raw.githubusercontent.com/lazroud/flowxe-ops/main/scripts/flowxe-mtu-check.sh \
    -o /usr/local/bin/flowxe-mtu-check
sudo chmod +x /usr/local/bin/flowxe-mtu-check

# Зависимости (обычно уже стоят)
sudo apt-get update -qq
sudo apt-get install -y iputils-ping iputils-tracepath iproute2
```

## Использование

### Интерактивный запуск

```bash
sudo flowxe-mtu-check
```

Цветной вывод с подробностями по каждой проверке и итоговым вердиктом.

### Тихий режим (для cron)

```bash
sudo flowxe-mtu-check --quiet
# Вывод: [FAIL] pass=4 warn=1 fail=3
```

### JSON-режим (для автоматизации)

```bash
sudo flowxe-mtu-check --json
# Вывод: {"hostname":"...","verdict":"FAIL","results":[...]}
```

### Без цвета (для логов)

```bash
sudo flowxe-mtu-check --no-color
```

## Exit-коды

| Код | Вердикт | Действие |
|---|---|---|
| `0` | PASS | Нода чистая, MTU 1500 end-to-end. Готова к продакшену. |
| `1` | WARN | Работает, но есть отклонения. Проверить вручную, использовать с осторожностью. |
| `2` | FAIL | Overlay / MTU < 1500. Не использовать для exit-трафика. |

## Интеграции

### 1. После развёртывания новой ноды (cloud-init)

Добавить в `cloud-init` или Ansible playbook сразу после bootstrap, ДО присоединения к Remnawave-панели:

```yaml
# cloud-init: runcmd
runcmd:
  - curl -fsSL https://raw.githubusercontent.com/lazroud/flowxe-ops/main/scripts/flowxe-mtu-check.sh -o /usr/local/bin/flowxe-mtu-check
  - chmod +x /usr/local/bin/flowxe-mtu-check
  - /usr/local/bin/flowxe-mtu-check --json > /var/log/flowxe-mtu-initial.json
  - |
    if ! /usr/local/bin/flowxe-mtu-check --quiet; then
      echo "MTU CHECK FAILED — DO NOT ATTACH TO REMNAWAVE" | tee /etc/motd
      exit 1
    fi
```

Если проверка падает — нода не подключается к панели, и ты получаешь ясный сигнал, что хостинг непригоден.

### 2. Периодический аудит (cron)

`/etc/cron.weekly/flowxe-mtu-audit`:

```bash
#!/bin/bash
LOG=/var/log/flowxe-mtu-audit.log
RESULT=$(/usr/local/bin/flowxe-mtu-check --json)
echo "$(date -Iseconds) $RESULT" >> "$LOG"

# Алерт в Telegram при изменении статуса
VERDICT=$(echo "$RESULT" | jq -r .verdict)
LAST_VERDICT=$(cat /var/lib/flowxe-mtu-last 2>/dev/null || echo "UNKNOWN")
if [[ "$VERDICT" != "$LAST_VERDICT" ]]; then
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" \
    -d "text=⚠️ MTU status changed on $(hostname): ${LAST_VERDICT} → ${VERDICT}"
  echo "$VERDICT" > /var/lib/flowxe-mtu-last
fi
```

### 3. GitHub Actions (для self-hosted runners на нодах)

`.github/workflows/mtu-audit.yml`:

```yaml
name: MTU Audit
on:
  schedule:
    - cron: '0 3 * * 1'  # Каждый понедельник 03:00 UTC
  workflow_dispatch:

jobs:
  audit:
    strategy:
      matrix:
        node: [msk-1, fi-1, de-1, de-2, nl-1]
    runs-on: [self-hosted, "${{ matrix.node }}"]
    steps:
      - name: Run MTU check
        run: sudo /usr/local/bin/flowxe-mtu-check --json | tee mtu-${{ matrix.node }}.json
      - name: Upload result
        uses: actions/upload-artifact@v4
        with:
          name: mtu-results
          path: mtu-${{ matrix.node }}.json
```

### 4. Pre-checkout для нового тарифа у хостера

Перед оплатой нового VPS — заказать минимальный тариф у того же провайдера, прогнать скрипт, и только если PASS — масштабироваться.

```bash
ssh root@new-vps.example.com 'bash <(curl -fsSL https://raw.githubusercontent.com/lazroud/flowxe-ops/main/scripts/flowxe-mtu-check.sh)'
```

## Интерпретация результатов

### PASS — что значит и что делать

Все ✓, exit 0. Нода готова для продакшена:

- Interface MTU = 1500
- Gateway в публичном диапазоне (не CGNAT)
- Скрытых туннелей нет
- DF ping 1500B проходит ко всем целям
- Active MSS ≥ 1448

Можно подключать к Remnawave и пускать exit-трафик.

### WARN — что значит и что делать

Есть желтые ⚠, exit 1. Типичные причины:

| Warning | Что делать |
|---|---|
| Gateway в RFC1918 (10.x / 192.168.x) | Проверить DF ping — если он PASS, всё ок, провайдер просто использует внутреннюю адресацию |
| Active MSS 1400–1447 | Нода работает, но есть лёгкая просадка. Допустимо для chain-нод, нежелательно для exit. |
| MSS clamping в iptables | Проверить, кто поставил правило (часто остаётся от ансиблов "по гайду"). Снять, если не нужно. |

### FAIL — что значит и что делать

Есть красные ✗, exit 2. Нода непригодна для exit-трафика.

| Failure | Действие |
|---|---|
| Gateway в CGNAT (100.64.x.x) | **Сменить тариф или провайдера.** Это provider-side, не лечится. |
| DF ping не проходит к 0/3 целей | Overlay физически режет фреймы. Смена провайдера обязательна. |
| Cached PMTU < 1500 после flush | Подтверждение overlay. Смена провайдера. |
| Tracepath показывает pmtu drop внутри сети провайдера | То же самое. |

## Известные хорошие / плохие провайдеры

На основе текущего опыта FLOWXE и общих наблюдений (это список нужно поддерживать самостоятельно — состав сети у хостеров меняется):

### Обычно PASS (clean L3, MTU 1500)

- Hetzner Cloud (Falkenstein, Nuremberg, Helsinki)
- Hetzner Dedicated (любая локация)
- OVH bare-metal / Eco / Advance
- FranTech (BuyVM)
- Path.net
- DigitalOcean Droplets (большинство регионов)
- u1host: некоторые тарифы с gateway 10.0.0.1 (как `vm1085717`)

### Часто FAIL (overlay / CGNAT)

- u1host: тарифы с gateway 100.64.0.1 (как `vm904211`)
- Beget Cloud (если за NAT)
- Многие "VDS с NAT IP" дешёвые хостеры
- Любой провайдер AS202226 (Great Flower) — подтверждённый overlay

### Проверять перед закупкой

Любой провайдер не из этих списков — обязательный pre-checkout через скрипт.

## Дополнительно

### Известные ограничения

- Скрипт проверяет только IPv4. Для IPv6 нужно дополнить (опционально, не критично — большая часть трафика идёт по v4).
- Не различает legit-туннели (например, специально настроенный WireGuard для mesh) и провайдерские. При наличии собственного туннеля скрипт выдаст WARN — это ожидаемо.
- `tracepath` может зависнуть на 15+ секунд на нодах, где провайдер блокирует ICMP. Это нормально, проверка просто пропустится.

### Что НЕ проверяет (намеренно)

- Скорость / пропускную способность (это другой инструмент — `iperf3` или Smokeping)
- TLS/Reality-конфигурацию Xray (это уровень приложения)
- DNS-leak (для этого есть отдельные тесты)

Скрипт сфокусирован только на L3/L4 сетевой характеристике ноды.

---

*FLOWXE · Internal ops · v1.0*
