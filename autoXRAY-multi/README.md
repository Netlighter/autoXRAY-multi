# Скрипты autoXRAY-multi

Краткая справка по файлам. **Полная инструкция** — в [корневом README](../README.md).

## Установка на сервер

```bash
cp -r autoXRAY-multi/* /usr/local/etc/xray/
chmod +x /usr/local/etc/xray/*.sh
/usr/local/etc/xray/init_server_env.sh    # один раз
/usr/local/etc/xray/update_clients.sh    # после каждой правки
```

## Файлы в `/usr/local/etc/xray/`

| Файл | Вы правите? | Назначение |
|------|-------------|------------|
| `clients.txt` | да | Имена клиентов, по одному в строке |
| `enabled_configs` | да | Цифры 1–6, опционально `no-socks` |
| `options.conf` | да | `show_socks=0/1` |
| `update_clients.sh` | запуск | Синхронизация всего |
| `server.env` | нет | Ключи сервера (создаёт `init_server_env.sh`) |
| `clients/*.env` | нет | UUID на клиента |
| `clients_urls.txt` | нет | Сводка ссылок |

Шаблоны `clients.txt`, `enabled_configs`, `options.conf` лежат в этой папке репозитория.
