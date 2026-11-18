# autoXRAY-multi

Обёртка над актуальным [autoXRAY](https://github.com/xVRVx/autoXRAY). Своего установщика здесь нет: при установке скачивается свежий `autoXRAY2.sh`, он поднимает сервер, а multi копирует уже готовую подписку каждому клиенту.

Выбор VPS, домен, мост RU → EU, WARP и удаление базового стека описаны в [README оригинала](https://github.com/xVRVx/autoXRAY/blob/main/README.md).

## Суть

Multi не ставит свой Xray и не держит копию скриптов оригинала. `install` скачивает текущий [autoXRAY2.sh](https://github.com/xVRVx/autoXRAY/blob/main/autoXRAY2.sh) и запускает его как есть: те же вопросы про fingerprint и Telegram Web Proxy, тот же Nginx, сертификат и `config.json`.

Установщик создаёт одну подписку со случайным путём, например `https://домен/AbCdEf….json`, и одного пользователя. Обёртка забирает эту подписку как образец и больше не собирает протоколы сама.

Дальше для каждого имени из `clients.txt` меняются только три вещи:

- UUID;
- пароль Hysteria2;
- путь ссылки.

Первый клиент, обычно `default`, получает ключи, которые только что выдал установщик. Поэтому напечатанная им ссылка продолжает открывать подписку `default`. У `alice` будут `https://домен/alice.json` и `https://домен/alice.html`.

В `config.json` те же люди дописываются во все VLESS-входы. Если у образца был `flow` (RAW TLS VISION), он сохраняется. У XHTTP его нет. У Hysteria2 у каждого свой пароль.

Сейчас установщик поднимает на 443 порту VLESS XHTTP TLS, VLESS RAW TLS VISION, Hysteria2 и по желанию Telegram Web Proxy. Этот список в обёртку не зашит. Что оказалось в подписке после установки, то и получат клиенты. Когда автор autoXRAY поменяет набор, новая установка подхватит его без правки multi.

## Пункты 1–7 больше не используются

Раньше отдельное меню включало и выключало конфиги номерами: REALITY, gRPC, WS, порт 8443, Socks5. Этого набора в текущем autoXRAY2 нет, поэтому меню убрано.

Профиль есть у клиента, если он есть в шаблоне подписки. Лишний убирается в `/usr/local/etc/xray/multi/template.json`, после этого нужен `sync`. Исходный UUID внутри шаблона не заменять: обёртка подставляет клиентские UUID сама.

## Установка

Нужны чистый Debian 12/13, root и домен, чья A-запись уже смотрит на VPS. Требования к серверу и домену — в [README оригинала](https://github.com/xVRVx/autoXRAY/blob/main/README.md).

```bash
install -d /usr/local/etc/xray
curl -fsSL https://raw.githubusercontent.com/Netlighter/autoXRAY-multi/main/autoxray-multi.sh \
  -o /usr/local/etc/xray/autoxray-multi.sh
chmod +x /usr/local/etc/xray/autoxray-multi.sh
/usr/local/etc/xray/autoxray-multi.sh install вашДОМЕН.com
```

Скрипт скачивает свежий autoXRAY2, задаёт его вопросы, ставит сервер, снимает шаблон и заводит клиента `default`.

Повторный `install` без `--force` останавливается: полная переустановка заново выпускает ключи установщика. Свой файл установщика вместо скачивания:

```bash
AUTOXRAY_SCRIPT=/path/autoXRAY2.sh /usr/local/etc/xray/autoxray-multi.sh install вашДОМЕН.com
```

## Сервер уже стоит

Если autoXRAY2 уже установлен и нужен только список клиентов:

```bash
/usr/local/etc/xray/autoxray-multi.sh adopt
```

Команда снимает шаблон с живого сервера и применяет `clients.txt`. Если списка ещё нет, создаётся `default` с уже выданными ключами. Исходная ссылка установщика при этом не ломается.

## Возможности

| Команда | Что делает |
|:--|:--|
| `install <домен>` | Скачать свежий autoXRAY2, поставить сервер, завести клиентов |
| `install <домен> --force` | Поставить заново, даже если конфиг уже есть |
| `adopt` | Снять шаблон с уже стоящего autoXRAY2 и разложить клиентов |
| `sync` | Заново применить `clients.txt` и шаблон |
| `add <имя>` | Добавить клиента и сразу выдать ему ссылки |
| `remove <имя>` | Удалить клиента, его файлы и доступ |
| `list` | Показать подписки, страницы, UUID и пароли Hysteria2 |
| `update-core` | Обновить только бинарник Xray, не трогая ключи и шаблон |

Имя клиента: латиница, цифры, `_` и `-`. В ссылке оно всегда в нижнем регистре, поэтому `Alice` и `alice` — один и тот же путь. Последнего клиента удалить нельзя: сервер не остаётся без пользователей.

```bash
/usr/local/etc/xray/autoxray-multi.sh add alice
/usr/local/etc/xray/autoxray-multi.sh remove alice
/usr/local/etc/xray/autoxray-multi.sh list
/usr/local/etc/xray/autoxray-multi.sh sync
```

`sync` нужен после ручной правки `clients.txt` или шаблона. Он заново собирает JSON и HTML, правит клиентов в `config.json` и дописывает `location` в nginx с теми заголовками Happ, которые записал установщик.

### Ссылки

| Клиент | Подписка | Страница |
|:--|:--|:--|
| первый, обычно `default` | `https://домен/<случайный-путь>.json` и `https://домен/default.json` | те же пути с `.html` |
| остальные | `https://домен/<имя>.json` | `https://домен/<имя>.html` |

В подписке лежит клиентский JSON с роутингом из установщика. На HTML-странице те же ссылки и QR плюс имя клиента.

Telegram Web Proxy, если его включили при установке, один на всех. Это сервис сервера, не пароль человека.

### Что можно править

| Файл | Править | Зачем |
|:--|:--|:--|
| `/usr/local/etc/xray/clients.txt` | да | имена, по одному в строке |
| `/usr/local/etc/xray/multi/template.json` | если нужно убрать профиль | образец подписки. Исходный UUID не менять |
| `/usr/local/etc/xray/multi/template.html` | нет | страница, снятая с установщика |
| `/usr/local/etc/xray/multi/clients/<имя>.json` | нет | UUID и пароль Hysteria2 этого клиента |
| `/usr/local/etc/xray/multi/server.json` | нет | домен, исходный путь подписки и исходные ключи |
| `/usr/local/etc/xray/config.json` | маршруты и сайт | массивы `clients` перезаписывает `sync` |
| `/usr/local/etc/xray/clients_urls.txt` | нет | последняя сводка ссылок |

После правки шаблона или списка снова запустите `sync`.

## Обновление

Только ядро Xray, без смены ключей и шаблона:

```bash
/usr/local/etc/xray/autoxray-multi.sh update-core
```

Это официальный установщик XTLS и актуальный релиз. Версию, с которой собран текущий autoXRAY2, выбирает сам установщик во время `install`.

Если заново запустили `autoXRAY2.sh` и он перезаписал конфиг и nginx, верните клиентов так:

```bash
/usr/local/etc/xray/autoxray-multi.sh adopt
/usr/local/etc/xray/autoxray-multi.sh list
```

UUID в `multi/clients/` сохраняются, шаблон снимается заново. Ключи, которые установщик напечатал в этом прогоне, не используются. Новый случайный путь становится ещё одной ссылкой первого клиента. Актуальные адреса показывает `list`.

## Чего обёртка не делает

- не считает трафик и не отключает клиента по лимиту; для этого нужны 3x-ui, RemnaWave или PasarGuard;
- не ставит мост RU → EU и не настраивает `bridgeTLSxhttp.sh` или `caddyBridge.sh` — они остаются в [оригинале](https://github.com/xVRVx/autoXRAY);
- не выпускает отдельный Telegram Web Proxy на каждого клиента;
- не переживает ручную замену UUID внутри `template.json`: после этого `sync` останавливается.
