# autoXRAY-multi

**Форк** [xVRVx/autoXRAY](https://github.com/xVRVx/autoXRAY) с главной доработкой: **отдельный xray-прокси на каждого пользователя** — своя подписка и своя страница конфигов, без 3x-ui и без панелей.

Оригинальная документация автора: [old/README-upstream.md](old/README-upstream.md)

---

## Что даёт эта версия

| Было (оригинал) | Стало (этот форк) |
|-----------------|-------------------|
| Один UUID на всех | У каждого клиента свой UUID |
| Одна случайная ссылка подписки | Понятные ссылки: `https://ДОМЕН/имя.json` |
| Одна HTML-страница | Своя страница на клиента: `https://ДОМЕН/имя.html` |
| Ручное правление xray | Одна команда: `update_clients.sh` |

Подходит для семьи, друзей, нескольких устройств — когда нужны **разные ключи**, но не нужна админка с трафиком.

---

## Быстрый старт (с нуля)

### 1. Установите базовый autoXRAY (один раз)

На чистом Debian 12 с root, домен уже смотрит на VPS:

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/Netlighter/autoXRAY-multi/main/autoXRAY1.sh)" -- вашДОМЕН.com
```

### 2. Поставьте модуль мульти-клиентов (один раз)

```bash
cd /root
git clone https://github.com/Netlighter/autoXRAY-multi.git
cp -r autoXRAY-multi/autoXRAY-multi/* /usr/local/etc/xray/
chmod +x /usr/local/etc/xray/*.sh
/usr/local/etc/xray/init_server_env.sh
/usr/local/etc/xray/update_clients.sh
```

После этого первый клиент — **`default`**:

- подписка: `https://вашДОМЕН/default.json`
- конфиги:  `https://вашДОМЕН/default.html`

---

## Где что лежит (не запутаться)

**На сервере всё управление — в одной папке:**

```
/usr/local/etc/xray/
├── clients.txt          ← КОГО добавить/убрать (имена)
├── enabled_configs      ← Что включить: цифры 1–7 (7 = Socks5 в HTML)
├── update_clients.sh    ← ЗАПУСКАТЬ после любых правок
├── clients_urls.txt     ← сводка ссылок (генерируется сам)
├── server.env           ← ключи сервера (не трогать руками)
└── clients/
    ├── default.env      ← UUID клиента (создаётся сам)
    └── phone.env
```

**В репозитории на GitHub:**

```
autoXRAY-multi/          ← скрипты мульти-клиента (копируете на сервер)
autoXRAY1.sh             ← базовая установка (из оригинала)
old/README-upstream.md   ← полный мануал оригинального autoXRAY
```

---

## Два файла, которые вы редактируете

Все правки — через `nano` (или любой редактор). **После каждого изменения** запускайте:

```bash
/usr/local/etc/xray/update_clients.sh
```

> Скрипт **не перезаписывает** ваши `clients.txt` и `enabled_configs` — можно спокойно оставлять пустые строки в конце.

---

### `clients.txt` — список людей / устройств

```bash
nano /usr/local/etc/xray/clients.txt
```

Пример:

```text
# комментарии через # — можно
default
phone
laptop
```

Правила имён: латиница, цифры, `-`, `_` (например `my-phone`).

Применить:

```bash
/usr/local/etc/xray/update_clients.sh
```

Новый клиент `phone` получит:

- `https://вашДОМЕН/phone.json`
- `https://вашДОМЕН/phone.html`

Удалили имя из файла → снова `update_clients.sh` → клиент и его файлы удалятся.

---

### `enabled_configs` — какие конфиги отдавать

```bash
nano /usr/local/etc/xray/enabled_configs
```

```text
# 1 — XHTTP REALITY (для моста)
# 2 — RAW REALITY VISION  ← обычно самый удобный
# 3 — RAW TLS VISION
# 4 — XHTTP TLS
# 5 — gRPC TLS
# 6 — WS TLS
# 7 — Socks5 (TG) на HTML-странице
2
4
7
```

Оставьте только нужные **цифры 1–7**. Пункт **7** — блок Socks5 в HTML (серверный Socks на 10443 работает и без семёрки).

---

## Посмотреть все ссылки разом

```bash
cat /usr/local/etc/xray/clients_urls.txt
```

Или откройте в браузере страницу клиента, например `https://вашДОМЕН/phone.html` — там Copy / QR / Add to HAPP.

---

## Подключение на телефон / ПК

1. Установите [Happ](https://www.happ.su/main/ru) (или v2rayTun / v2rayN).
2. Скопируйте ссылку подписки `https://вашДОМЕН/имя.json` или нажмите **Add to HAPP** на HTML-странице.
3. Маршрутизацию в приложении лучше **выключить** — в подписке уже встроена.

---

## Обновить скрипты мульти-клиента

Когда вышла новая версия на GitHub:

```bash
cd /root/autoXRAY-multi && git pull
cp -r autoXRAY-multi/* /usr/local/etc/xray/
/usr/local/etc/xray/update_clients.sh
```

---

## Частые команды (шпаргалка)

| Задача | Команда |
|--------|---------|
| Добавить/убрать клиента | `nano .../clients.txt` → `update_clients.sh` |
| Включить/выключить тип конфига xray | `nano .../enabled_configs` → `update_clients.sh` |
| Скрыть Socks5 в HTML | убрать `7` из `enabled_configs` → `update_clients.sh` |
| Все ссылки | `cat .../clients_urls.txt` |
| Проверить xray | `xray -test -config /usr/local/etc/xray/config.json` |
| Перезапуск xray | `systemctl restart xray` |

Полный путь к скрипту, если не в PATH:

```bash
/usr/local/etc/xray/update_clients.sh
```

---

## Что не покрывает этот форк

- Учёт трафика, лимиты, срок действия — нужны панели (3x-ui, Remnawave).
- Полная переустановка с нуля — снова `autoXRAY1.sh`, потом `init_server_env.sh` и `update_clients.sh`.

---

## Структура репозитория

| Путь | Зачем |
|------|-------|
| [autoXRAY-multi/](autoXRAY-multi/) | Скрипты для сервера |
| [autoXRAY1.sh](autoXRAY1.sh) | Первая установка xray-прокси |
| [old/README-upstream.md](old/README-upstream.md) | Оригинальный README (WARP, мост RU→EU, хостинги) |
| [test/](test/) | Тестовые сборки оригинала |

---

Форк: **Netlighter/autoXRAY-multi** · база: **xVRVx/autoXRAY**
