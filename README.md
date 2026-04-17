# crowdsecinstall.sh

Автоматическая установка CrowdSec на Ubuntu/Debian:
- Security Engine (`crowdsec`)
- Firewall Bouncer (iptables/nftables — выбирается автоматически)
- Опциональная L7-защита для Nginx (коллекции и acquisition)

## Быстрый старт (curl + bash)

### Вариант 1 (рекомендуется, в файл)
```bash
curl -fsSL https://raw.githubusercontent.com/biggikos/crowdsecinstall.sh/main/crowdsecinstall.sh -o crowdsecinstall.sh
chmod +x crowdsecinstall.sh
sudo bash crowdsecinstall.sh
```

### Вариант 2 (одной командой)
```bash
curl -fsSL https://raw.githubusercontent.com/biggikos/crowdsecinstall.sh/main/crowdsecinstall.sh | sudo bash
```

## Что делает скрипт

1. Проверяет root, ОС и зависимости.
2. Добавляет официальный репозиторий CrowdSec (`https://install.crowdsec.net`).
3. Устанавливает `crowdsec`.
4. Проверяет и при необходимости меняет LAPI-порт.
5. Определяет backend фаервола:
   - `iptables` → ставит `crowdsec-firewall-bouncer-iptables`
   - `nftables` → ставит `crowdsec-firewall-bouncer-nftables`
6. Создаёт/обновляет конфиг bouncer.
7. По запросу добавляет Nginx-коллекции и acquisition.
8. Перезапускает сервисы и выводит итоговую сводку.

## Поддерживаемые ОС

- Ubuntu: `22.04`, `24.04`
- Debian: `11`, `12`

На других версиях скрипт попросит подтверждение продолжения.

## Проверка после установки

```bash
sudo systemctl status crowdsec --no-pager
sudo systemctl status crowdsec-firewall-bouncer --no-pager
sudo cscli bouncers list
sudo cscli decisions list
sudo cscli metrics
```

Логи:
```bash
sudo journalctl -u crowdsec -f
sudo journalctl -u crowdsec-firewall-bouncer -f
sudo tail -f /var/log/crowdsec-install.log
```

## Ревью кода (что проверено)

По документации CrowdSec были проверены: установка движка, установка firewall bouncer, регистрация bouncer-ключа, базовая пост-инсталляционная верификация.

В рамках ревью уже исправлено:
- переход на официальный инсталлятор репозитория CrowdSec (`install.crowdsec.net`);
- использование более безопасной формы `curl -fsSL ... | sh`;
- авто-выбор пакета bouncer под `iptables`/`nftables`;
- синхронизация `mode` bouncer с выбранным backend.

## Важные замечания

- Скрипт меняет системные настройки и требует `root`.
- Перед запуском на production рекомендуется прогнать на staging.
- Если вы защищаете веб-приложение, firewall bouncer лучше дополнять WAF-capable bouncer (nginx/openresty/traefik/haproxy) согласно документации CrowdSec.
