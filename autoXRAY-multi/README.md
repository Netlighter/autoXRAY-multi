# autoXRAY-multi

Обёртка над актуальным [autoXRAY2](https://github.com/xVRVx/autoXRAY). Она не хранит свой установщик и не собирает протоколы заново. `install` скачивает свежий `autoXRAY2.sh`, даёт ему поднять сервер, а затем копирует уже готовую подписку каждому клиенту.

Сейчас установщик поднимает на 443 порту VLESS XHTTP TLS, VLESS RAW TLS VISION, Hysteria2 и по желанию Telegram Web Proxy. Этот список в обёртку не зашит. Что оказалось в подписке после установки, то и получат клиенты. Когда автор autoXRAY поменяет набор, новая установка подхватит его без правки multi.

## Пункты 1–7 больше не используются

Раньше `enabled_configs` перечислял конфиги номерами: REALITY, gRPC, WS, порт 8443 и отдельный Socks5. Этого набора в текущем autoXRAY2 нет, поэтому меню убрано.

Профиль включается тем, что он есть в шаблоне подписки. Убрать лишний можно в `/usr/local/etc/xray/multi/template.json`, затем выполнить `sync`. Исходный UUID внутри шаблона не заменять: обёртка подставляет клиентские UUID сама.

## Как это работает

1. `autoXRAY2.sh` ставит Xray, Nginx, сертификат и одну подписку со случайным путём, например `/AbCdEf….json`.
2. `adopt` снимает с этой установки шаблон: JSON, HTML и заголовки Happ из nginx.
3. Первое имя из `clients.txt` (обычно `default`) получает UUID и пароль Hysteria2, которые только что сгенерировал установщик. Его исходная ссылка продолжает работать.
4. `sync` клонирует шаблон остальным. Меняются только UUID, пароль Hysteria2 и путь: `/alice.json`, `/alice.html`.
5. Те же люди дописываются во все VLESS-входы. `flow` остаётся, если он был у образца (RAW TLS VISION). У XHTTP его нет. У Hysteria2 у каждого свой `auth`.

Мост `bridgeTLSxhttp.sh` и `caddyBridge.sh` обёртка не настраивает.

## Установка с нуля

Нужны чистый Debian 12/13, root и домен, чья A-запись уже смотрит на VPS.

```bash
install -d /usr/local/etc/xray
curl -fsSL https://raw.githubusercontent.com/Netlighter/autoXRAY-multi/main/autoXRAY-multi/autoxray-multi.sh \
  -o /usr/local/etc/xray/autoxray-multi.sh
chmod +x /usr/local/etc/xray/autoxray-multi.sh
/usr/local/etc/xray/autoxray-multi.sh install вашДОМЕН.com
```

Скрипт задаёт те же вопросы, что оригинал: fingerprint и нужен ли Telegram Web Proxy. Затем создаёт клиента `default` и печатает его ссылки.

Повторный `install` без `--force` останавливается. Полная переустановка заново выпускает ключи установщика.

Свой файл установщика вместо скачивания:

```bash
AUTOXRAY_SCRIPT=/path/autoXRAY2.sh /usr/local/etc/xray/autoxray-multi.sh install вашДОМЕН.com
```

## Сервер уже стоит

```bash
/usr/local/etc/xray/autoxray-multi.sh adopt
```

Команда снимает шаблон с текущего autoXRAY2 и применяет `clients.txt`. Если списка ещё нет, создаётся `default` с уже выданными ключами.

## Команды

| Команда | Действие |
|:--|:--|
| `install <домен>` | Скачать свежий autoXRAY2, поставить, завести клиентов |
| `install <домен> --force` | Поставить заново, даже если конфиг уже есть |
| `adopt` | Снять шаблон с живой установки и разложить клиентов |
| `sync` | Заново применить `clients.txt` и шаблон |
| `add <имя>` | Добавить клиента |
| `remove <имя>` | Удалить клиента |
| `list` | Показать ссылки, UUID и пароли Hysteria2 |
| `update-core` | Обновить только бинарник Xray |

Имя клиента: латиница, цифры, `_` и `-`. В ссылке оно всегда в нижнем регистре, поэтому `Alice` и `alice` — один путь.

```bash
/usr/local/etc/xray/autoxray-multi.sh add alice
/usr/local/etc/xray/autoxray-multi.sh remove alice
/usr/local/etc/xray/autoxray-multi.sh list
```

Последнего клиента удалить нельзя.

## Ссылки

| Клиент | Подписка | Страница |
|:--|:--|:--|
| первый, обычно `default` | `https://домен/<случайный-путь>.json` и `https://домен/default.json` | те же пути с `.html` |
| остальные | `https://домен/<имя>.json` | `https://домен/<имя>.html` |

В подписке лежит клиентский JSON с роутингом. На HTML-странице те же ссылки и QR, что собрал установщик, плюс имя клиента.

Telegram Web Proxy, если его включили при установке, один на всех: это сервис сервера, не пароль человека.

## Файлы

| Файл | Кто правит | Зачем |
|:--|:--|:--|
| `/usr/local/etc/xray/clients.txt` | вы | имена, по одному в строке |
| `/usr/local/etc/xray/multi/template.json` | при необходимости | убрать профиль из подписки |
| `/usr/local/etc/xray/multi/template.html` | нет | страница, снятая с установщика |
| `/usr/local/etc/xray/multi/clients/<имя>.json` | нет | UUID и пароль Hysteria2 |
| `/usr/local/etc/xray/multi/server.json` | нет | домен, путь исходной подписки, исходные ключи |
| `/usr/local/etc/xray/config.json` | маршруты | массивы `clients` перезаписывает `sync` |
| `/usr/local/etc/xray/clients_urls.txt` | нет | последняя сводка `list` |

После правки `clients.txt` или `template.json` нужен `sync`.

## Обновление

Только ядро, без смены ключей и шаблона:

```bash
/usr/local/etc/xray/autoxray-multi.sh update-core
```

Это официальный установщик XTLS и актуальный релиз. Версию, с которой собран текущий autoXRAY2, по-прежнему выбирает сам установщик в команде `install`.

Если заново запустили `autoXRAY2.sh` и он перезаписал конфиг и nginx:

```bash
/usr/local/etc/xray/autoxray-multi.sh adopt
/usr/local/etc/xray/autoxray-multi.sh list
```

UUID в `multi/clients/` сохраняются, шаблон снимается заново. Ключи, которые установщик напечатал в этом прогоне, не используются. Новый случайный путь становится ещё одной ссылкой первого клиента.

## Чего обёртка не делает

- не считает трафик и не отключает человека по лимиту;
- не ставит мост RU → EU;
- не выпускает отдельный Telegram Web Proxy на клиента;
- не переживает ручную замену UUID внутри `template.json`: после этого `sync` останавливается.
