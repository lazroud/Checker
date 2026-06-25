# MTU end-to-end check

Скрипт `check.sh` валидирует, что **MTU 1500 проходит end-to-end** от тестируемой ноды до публичного интернета. Детектирует overlay-сети (VXLAN, SDN), CGNAT-туннели и MSS clamping — те причины, по которым TCP-фингерпринт ноды начинает выглядеть как VPN-подключение.

## Зачем нужно

Часть VPS-хостингов использует overlay-сети между виртуалкой и публичной сетью: VXLAN, GENEVE, CGNAT с инкапсуляцией. На таких нодах MTU режется ещё до выхода в интернет, что:

- понижает throughput из-за фрагментации,
- даёт характерный TCP-фингерпринт (MTU < 1500, MSS < 1448), по которому внешние сервисы могут детектировать подключение как VPN,
- **не лечится** sysctl-настройками на стороне ОС — overlay физически дропает фреймы > 1500.

Этот скрипт — go/no-go проверка перед вводом ноды в продакшен.

## Запуск

### Одноразово (без установки)

```bash
curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh | sudo bash
```

С аргументами:

```bash
curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh | sudo bash -s -- --json
```

### Постоянная установка

```bash
sudo curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh \
    -o /usr/local/bin/mtu-check
sudo chmod +x /usr/local/bin/mtu-check
sudo mtu-check
```

## Что проверяется

| Проверка | Что ищет | На что указывает |
|---|---|---|
| **Interface MTU** | MTU на default-интерфейсе | Базовый уровень — должен быть 1500 |
| **Gateway analysis** | CGNAT (`100.64.0.0/10`), RFC1918 как default gw | Признак overlay у провайдера |
| **Tunnel interfaces** | tun / vxlan / geneve / gre / wireguard | Скрытые туннели |
| **MSS clamping** | iptables / nftables MSS-правила | Локальные ограничения firewall |
| **Cached PMTU** | `ip route get` cache | Что ядро уже выучило с маршрутов |
| **Tracepath PMTU** | Поэтапная просадка PMTU вдоль пути | Локализация — где именно режется |
| **DF ping** | Пакеты 1472B + DF до Cloudflare/Google/Quad9 | **Главная проверка** — реально ли проходит 1500B |
| **Active TCP MSS** | MSS в живых соединениях | Что Xray/системные процессы получают по факту |

**Главная проверка — don't-fragment ping.** Если 1500-байтные пакеты с флагом DF не доходят до публичных целей, никакие `sysctl`-настройки не помогут — это physical-layer ограничение от провайдера.

## Интерпретация результатов

### PASS (exit 0)

Все ✓:

- Interface MTU = 1500
- Gateway в публичном диапазоне (не CGNAT)
- Скрытых туннелей нет
- DF ping 1500B проходит ко всем целям
- Active MSS ≥ 1448

Нода готова для продакшена.

### WARN (exit 1)

Есть ⚠. Типичные причины:

| Warning | Что делать |
|---|---|
| Gateway в RFC1918 (10.x / 192.168.x) | Проверить DF ping — если он PASS, всё ок, провайдер просто использует внутреннюю адресацию |
| Active MSS 1400–1447 | Лёгкая просадка. Допустимо для chain-нод, нежелательно для exit. |
| MSS clamping в iptables | Проверить, кто поставил правило. Снять, если не нужно. |

### FAIL (exit 2)

Есть ✗. Нода непригодна для exit-трафика.

| Failure | Действие |
|---|---|
| Gateway в CGNAT (100.64.x.x) | Сменить тариф или провайдера. Provider-side, не лечится. |
| DF ping не проходит к 0/3 целей | Overlay физически режет фреймы. Смена провайдера обязательна. |
| Cached PMTU < 1500 после flush | Подтверждение overlay. |
| Tracepath показывает pmtu drop внутри сети провайдера | То же самое. |

## Интеграции

### Cloud-init / Ansible bootstrap

Запустить проверку сразу после установки системы, ДО подключения ноды к продакшену:

```yaml
# cloud-init
runcmd:
  - |
    if ! curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh | bash -s -- --quiet; then
      echo "MTU CHECK FAILED — DO NOT USE THIS NODE" | tee /etc/motd
      exit 1
    fi
```

### Cron-аудит

`/etc/cron.weekly/mtu-audit`:

```bash
#!/bin/bash
LOG=/var/log/mtu-audit.log
RESULT=$(/usr/local/bin/mtu-check --json)
echo "$(date -Iseconds) $RESULT" >> "$LOG"

# Алерт при изменении статуса
VERDICT=$(echo "$RESULT" | jq -r .verdict)
LAST=$(cat /var/lib/mtu-last 2>/dev/null || echo "UNKNOWN")
if [[ "$VERDICT" != "$LAST" ]]; then
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" \
    -d "text=⚠️ MTU status on $(hostname): ${LAST} → ${VERDICT}"
  echo "$VERDICT" > /var/lib/mtu-last
fi
```

### Pre-checkout перед заказом нового VPS

Перед оплатой новой ноды — заказать минимальный тариф, прогнать проверку, и только при PASS масштабироваться:

```bash
ssh root@new-vps.example.com 'bash <(curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh)'
```

### GitHub Actions

Пример для self-hosted runners на нодах:

```yaml
name: MTU Audit
on:
  schedule:
    - cron: '0 3 * * 1'
  workflow_dispatch:

jobs:
  audit:
    strategy:
      matrix:
        node: [msk-1, fi-1, de-1, de-2, nl-1]
    runs-on: [self-hosted, "${{ matrix.node }}"]
    steps:
      - name: Run MTU check
        run: |
          curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh \
            | sudo bash -s -- --json > mtu-${{ matrix.node }}.json
      - uses: actions/upload-artifact@v4
        with:
          name: mtu-results
          path: mtu-${{ matrix.node }}.json
```

## Известные ограничения

- IPv4 only (IPv6-валидация не делается)
- Не различает легитимные туннели (свой WireGuard для mesh) и провайдерские — выдаст WARN
- `tracepath` может зависать на 15 секунд, если провайдер блокирует ICMP — это нормально, проверка просто пропустится

## Что НЕ проверяет (намеренно)

- Скорость / пропускную способность — это другой инструмент (`iperf3`, Smokeping)
- TLS / Reality / Xray-конфигурацию — уровень приложения
- DNS leak

Скрипт сфокусирован только на L3/L4 сетевой характеристике ноды.
