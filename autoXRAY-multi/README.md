# autoXRAY-multi

Дополнение к [autoXRAY1.sh](../autoXRAY1.sh) для **нескольких клиентов** без GUI-панели.

После стандартной установки autoXRAY каждый клиент получает свой UUID, подписку и HTML-страницу с конфигами. Ссылки предсказуемые: `https://ДОМЕН/имя.json` и `https://ДОМЕН/имя.html`.

## Установка на сервер

```bash
cp -r autoXRAY-multi/* /usr/local/etc/xray/
chmod +x /usr/local/etc/xray/*.sh
/usr/local/etc/xray/init_server_env.sh
/usr/local/etc/xray/update_clients.sh
```

`init_server_env.sh` — один раз: сохраняет ключи текущей установки в `server.env` и мигрирует первого клиента как `default`.

## Файлы

| Файл | Назначение |
|------|------------|
| `clients.txt` | Имена клиентов (один на строку, `a-z A-Z 0-9 _ -`) |
| `enabled_configs` | Включённые типы конфигов: цифры **1–6**; опционально `no-socks` |
| `options.conf` | `show_socks=0` — скрыть Socks5 в HTML |
| `server.env` | Общие ключи сервера (создаётся `init_server_env.sh`, не коммитить) |
| `clients/*.env` | UUID и путь подписки на клиента (создаётся автоматически) |
| `clients_urls.txt` | Сводка ссылок (генерируется `update_clients.sh`) |
| `update_clients.sh` | Синхронизация xray, nginx, json и html |

## Типы конфигов (enabled_configs)

```
# 1 — VLESS XHTTP REALITY EXTRA (для моста)
# 2 — VLESS RAW REALITY VISION
# 3 — VLESS RAW TLS VISION
# 4 — VLESS XHTTP TLS EXTRA
# 5 — VLESS gRPC TLS
# 6 — VLESS WS TLS
1
2
3
4
5
6
```

Удалите ненужные номера. Пустые строки в конце файла игнорируются — **файл скриптом не перезаписывается**.

## Добавить клиента

1. Добавьте имя в `clients.txt`:
   ```
   default
   phone
   laptop
   ```
2. Запустите:
   ```bash
   /usr/local/etc/xray/update_clients.sh
   ```
3. Ссылки:
   - `https://вашДОМЕН/phone.json` — подписка
   - `https://вашДОМЕН/phone.html` — страница с vless-ссылками

## Убрать Socks5 из HTML

**Вариант 1** — `options.conf`:

```ini
show_socks=0
```

**Вариант 2** — в `enabled_configs`:

```text
no-socks
```

или `1 2 3 no-socks`, `1-no-socks`.

Серверный Socks5 на порту **10443** продолжит работать — скрывается только блок на веб-странице.

## Что делает update_clients.sh

1. Читает `clients.txt` (без изменения файла).
2. Создаёт UUID для новых клиентов, удаляет отсутствующих.
3. Прописывает все UUID в `config.json` (все vless-inbounds).
4. Генерирует для каждого клиента `.json` (подписка) и `.html` (ссылки).
5. Обновляет nginx (`location = /имя.json` с заголовками HAPP).
6. Проверяет `xray -test` и перезапускает xray.

## Обновление скриптов

```bash
cd /path/to/autoXRAY
git pull
cp -r autoXRAY-multi/* /usr/local/etc/xray/
/usr/local/etc/xray/update_clients.sh
```
