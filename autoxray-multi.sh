#!/bin/bash
# autoXRAY-multi — обёртка над актуальным autoXRAY2.
# Установщик не форкается: install скачивает свежий autoXRAY2.sh,
# enable подключает multi к уже стоящему серверу, sync размножает подписку по clients.txt.
set -euo pipefail

MULTI_VERSION=3
AX_DIR="${AX_DIR:-/usr/local/etc/xray}"
STATE_DIR="${AX_STATE_DIR:-$AX_DIR/multi}"
UPSTREAM_URL="${AUTOXRAY_UPSTREAM_URL:-https://raw.githubusercontent.com/xVRVx/autoXRAY/main/autoXRAY2.sh}"
XRAY_INSTALL_URL="${AUTOXRAY_XRAY_INSTALL_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
autoXRAY-multi ${MULTI_VERSION}

  install <домен>    поставить свежий autoXRAY и завести клиентов
  enable             подключить multi к уже стоящему autoXRAY
  add <имя>          добавить клиента
  remove <имя>       удалить клиента
  list               показать ссылки
  sync               применить правки clients.txt или шаблона
  update-core        обновить только бинарник Xray
  install <домен> --force     поставить заново и сменить ключи установщика

Каталог состояния: ${STATE_DIR}
Список клиентов:   ${AX_DIR}/clients.txt

AUTOXRAY_SCRIPT          свой autoXRAY2.sh вместо скачивания
AUTOXRAY_UPSTREAM_URL    другой URL установщика
AUTOXRAY_SKIP_RESTART=1  не вызывать nginx/xray/systemctl (проверки)
EOF
}

need_root() {
    if [[ "${AUTOXRAY_SKIP_RESTART:-}" == "1" ]]; then
        return 0
    fi
    [[ "${EUID}" -eq 0 ]] || { echo "Нужны права root" >&2; exit 1; }
}

need_python() {
    command -v python3 >/dev/null 2>&1 || { echo "Нужен python3" >&2; exit 1; }
}

ax_py() {
    need_python
    AX_DIR="$AX_DIR" \
    AX_STATE_DIR="$STATE_DIR" \
    AX_NGINX_CONFIG="${AX_NGINX_CONFIG:-}" \
    python3 - "$@" <<'PY'
import copy
import html
import json
import os
import re
import secrets
import shutil
import sys
import tempfile
import uuid

AX_DIR = os.environ["AX_DIR"]
STATE = os.environ["AX_STATE_DIR"]
CFG_PATH = os.path.join(AX_DIR, "config.json")
CLIENTS_TXT = os.path.join(AX_DIR, "clients.txt")
URLS_PATH = os.path.join(AX_DIR, "clients_urls.txt")
CLIENTS_DIR = os.path.join(STATE, "clients")
SERVER_JSON = os.path.join(STATE, "server.json")
TEMPLATE_JSON = os.path.join(STATE, "template.json")
TEMPLATE_HTML = os.path.join(STATE, "template.html")
LOCATION_JSON = os.path.join(STATE, "location.json")
LOCATION_HTML = os.path.join(STATE, "location.html")
GENERATED = os.path.join(STATE, "generated.json")

MARKER_START = "# AUTOXRAY_MULTI_SUB_START"
MARKER_END = "# AUTOXRAY_MULTI_SUB_END"
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")


def die(msg):
    print(msg, file=sys.stderr)
    raise SystemExit(1)


def log(msg):
    print(msg, file=sys.stderr)


def atomic_write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if isinstance(data, str):
        data = data.encode("utf-8")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    try:
        os.write(fd, data)
        os.fchmod(fd, mode)
    finally:
        os.close(fd)
    os.replace(tmp, path)


def load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def save_json(path, obj, mode=0o644):
    atomic_write(path, json.dumps(obj, ensure_ascii=False, indent=2) + "\n", mode)


def load_state():
    if not os.path.isfile(SERVER_JSON):
        return None
    return load_json(SERVER_JSON)


def parse_clients(path):
    names = []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if line:
                names.append(line)
    return names


def validate_names(names):
    if not names:
        die("clients.txt пуст — добавьте хотя бы одно имя")
    seen = {}
    for name in names:
        if not NAME_RE.fullmatch(name):
            die(f"недопустимое имя «{name}» (латиница, цифры, _ -; первый символ — буква или цифра)")
        sub = name.lower()
        if sub in seen:
            die(f"имена «{seen[sub]}» и «{name}» дают один путь /{sub}")
        seen[sub] = name
    return seen


def find_block_end(text, open_idx):
    depth = 0
    i = open_idx
    in_quote = False
    quote = ""
    while i < len(text):
        ch = text[i]
        if in_quote:
            if ch == "\\" and quote == '"':
                i += 2
                continue
            if ch == quote:
                in_quote = False
            i += 1
            continue
        if ch in ("'", '"'):
            in_quote = True
            quote = ch
            i += 1
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    die("в конфиге nginx не закрыта скобка location")


def extract_locations(text):
    pat = re.compile(
        r"^([ \t]*)location\s+=\s+/([A-Za-z0-9_-]+)\.(json|html)\s*\{",
        re.M,
    )
    found = []
    for match in pat.finditer(text):
        open_idx = match.end() - 1
        end = find_block_end(text, open_idx)
        found.append(
            {
                "indent": match.group(1),
                "name": match.group(2),
                "kind": match.group(3),
                "start": match.start(),
                "end": end + 1,
                "inner": text[open_idx + 1 : end],
            }
        )
    return found


def discover_site(text):
    domain = ""
    for raw in re.findall(r"^\s*server_name\s+([^;]+);", text, re.M):
        name = raw.split()[0].strip()
        if name and name != "_":
            domain = name
            break
    if not domain:
        die("в nginx не найден server_name домена")

    roots = [item.strip() for item in re.findall(r"^\s*root\s+([^;]+);", text, re.M)]
    web = ""
    preferred = "/var/www/" + domain
    for root in roots:
        if root == preferred:
            web = root
            break
    if not web:
        for root in roots:
            if root != "/var/www/html":
                web = root
                break
    if not web:
        die("в nginx не найден root сайта")

    path_xhttp = ""
    for match in re.finditer(r"location\s+/([A-Za-z0-9_-]+)\s*\{", text):
        open_idx = match.end() - 1
        end = find_block_end(text, open_idx)
        body = text[open_idx + 1 : end]
        if "grpc_pass" in body:
            path_xhttp = match.group(1)
            break
    return domain, web, path_xhttp


def find_nginx():
    override = os.environ.get("AX_NGINX_CONFIG") or ""
    if override:
        if not os.path.isfile(override):
            die(f"нет nginx-конфига {override}")
        return override
    state = load_state()
    if state and os.path.isfile(state.get("nginx_config", "")):
        return state["nginx_config"]
    for path in (
        "/etc/nginx/conf.d/default.conf",
        "/etc/nginx/sites-available/default",
        "/etc/nginx/sites-enabled/default",
    ):
        if os.path.isfile(path):
            return path
    die("не найден конфиг nginx")


def first_value(obj, key):
    if isinstance(obj, dict):
        if key in obj and isinstance(obj[key], str):
            return obj[key]
        for value in obj.values():
            found = first_value(value, key)
            if found:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = first_value(item, key)
            if found:
                return found
    return ""


def first_vless_uuid(cfg):
    for inbound in cfg.get("inbounds", []):
        if inbound.get("protocol") != "vless":
            continue
        clients = (inbound.get("settings") or {}).get("clients") or []
        if clients and isinstance(clients[0], dict) and clients[0].get("id"):
            return clients[0]["id"]
    return ""


def first_hy2(cfg):
    for inbound in cfg.get("inbounds", []):
        if inbound.get("protocol") != "hysteria":
            continue
        clients = (inbound.get("settings") or {}).get("clients") or []
        if clients and isinstance(clients[0], dict) and clients[0].get("auth"):
            return clients[0]["auth"]
    return ""


def read_text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def capture(force=False):
    if not os.path.isfile(CFG_PATH):
        die(f"нет {CFG_PATH} — сначала поставьте autoXRAY2")
    nginx_path = find_nginx()
    text = read_text(nginx_path)
    locs = extract_locations(text)
    json_locs = [item for item in locs if item["kind"] == "json"]
    html_locs = [item for item in locs if item["kind"] == "html"]
    marker = MARKER_START in text
    pristine = (
        not marker
        and len(json_locs) == 1
        and len(html_locs) == 1
        and json_locs[0]["name"] == html_locs[0]["name"]
    )
    state = load_state()
    domain, web, path_xhttp = discover_site(text)

    take_web = force or state is None or not os.path.isfile(TEMPLATE_JSON)
    if pristine and state is not None:
        legacy = json_locs[0]["name"]
        web_json = os.path.join(web, legacy + ".json")
        if os.path.isfile(web_json):
            try:
                web_id = first_value(load_json(web_json), "id")
            except json.JSONDecodeError:
                web_id = ""
            if web_id and web_id != state.get("seed_uuid"):
                take_web = True
        if legacy != state.get("legacy_subpage"):
            take_web = True

    if take_web:
        if not pristine:
            die(
                "нельзя снять шаблон: в nginx уже несколько подписок или нет "
                "исходной пары location. Верните конфиг установщика и повторите enable"
            )
        legacy = json_locs[0]["name"]
        web_json = os.path.join(web, legacy + ".json")
        web_html = os.path.join(web, legacy + ".html")
        if not os.path.isfile(web_json) or not os.path.isfile(web_html):
            die(f"установщик не оставил подписку {web_json}")
        cfg = load_json(CFG_PATH)
        template_doc = load_json(web_json)
        seed_uuid = first_vless_uuid(cfg)
        blob = json.dumps(template_doc)
        if not seed_uuid or seed_uuid not in blob:
            die("UUID из config.json не найден в подписке установщика")
        seed_hy2 = first_hy2(cfg)
        if seed_hy2 and seed_hy2 not in blob:
            die("пароль Hysteria2 из config.json не найден в подписке установщика")
        os.makedirs(STATE, exist_ok=True)
        shutil.copyfile(web_json, TEMPLATE_JSON)
        shutil.copyfile(web_html, TEMPLATE_HTML)
        os.chmod(TEMPLATE_JSON, 0o600)
        os.chmod(TEMPLATE_HTML, 0o600)
        html_inner = next(item["inner"] for item in html_locs if item["name"] == legacy)
        json_inner = next(item["inner"] for item in json_locs if item["name"] == legacy)
        atomic_write(LOCATION_HTML, html_inner, 0o600)
        atomic_write(LOCATION_JSON, json_inner, 0o600)
        save_json(
            SERVER_JSON,
            {
                "domain": domain,
                "web_path": web,
                "nginx_config": nginx_path,
                "legacy_subpage": legacy,
                "seed_uuid": seed_uuid,
                "seed_hy2": seed_hy2,
                "path_xhttp": path_xhttp,
                "location_indent": json_locs[0]["indent"],
            },
            0o600,
        )
        xhttp = f"/{path_xhttp}" if path_xhttp else "-"
        log(f"шаблон снят: {domain}, подписка /{legacy}.json, xhttp {xhttp}")
        return

    if not os.path.isfile(TEMPLATE_JSON) or not os.path.isfile(TEMPLATE_HTML):
        die("шаблон не найден — выполните enable на установке autoXRAY2")
    log("шаблон уже есть, оставляю его")


def client_record_path(name):
    return os.path.join(CLIENTS_DIR, name + ".json")


def load_records():
    records = {}
    if not os.path.isdir(CLIENTS_DIR):
        return records
    for filename in os.listdir(CLIENTS_DIR):
        if not filename.endswith(".json"):
            continue
        path = os.path.join(CLIENTS_DIR, filename)
        try:
            rec = load_json(path)
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(rec, dict) and rec.get("name"):
            records[rec["name"]] = rec
    return records


def transform(doc, seed_uuid, seed_hy2, user_uuid, user_hy2, name):
    def walk(node):
        if isinstance(node, dict):
            for key, value in list(node.items()):
                if isinstance(value, str):
                    if value == seed_uuid:
                        node[key] = user_uuid
                    elif seed_hy2 and key == "auth" and value == seed_hy2:
                        node[key] = user_hy2
                else:
                    walk(value)
            remark = node.get("remarks")
            suffix = f" [{name}]"
            if isinstance(remark, str) and suffix not in remark:
                node["remarks"] = remark + suffix
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(doc)


def render_html(template, state, user_uuid, user_hy2, subpath, name, keep_paths):
    page = template.replace(state["seed_uuid"], user_uuid)
    seed_hy2 = state.get("seed_hy2") or ""
    if seed_hy2 and user_hy2 and seed_hy2 != user_hy2:
        page = re.sub(
            rf"(hy2://){re.escape(seed_hy2)}(@)",
            rf"\g<1>{user_hy2}\g<2>",
            page,
        )
        page = re.sub(
            rf"(auth=){re.escape(seed_hy2)}(&|#|$)",
            rf"\g<1>{user_hy2}\g<2>",
            page,
        )
    legacy = state["legacy_subpage"]
    if not keep_paths and legacy != subpath:
        page = page.replace(f"/{legacy}.json", f"/{subpath}.json")
        page = page.replace(f"/{legacy}.html", f"/{subpath}.html")
    title = f"autoXRAY · {html.escape(name)}"
    page = page.replace("<title>autoXRAY configs</title>", f"<title>{title}</title>", 1)
    banner = f"<h2>Клиент: {html.escape(name)}</h2>"
    page = page.replace("<body>", "<body>\n" + banner, 1)
    return page


def patch_xray(cfg, users):
    vless = 0
    hy2 = 0
    for inbound in cfg.get("inbounds", []):
        settings = inbound.setdefault("settings", {})
        clients = settings.get("clients")
        if not isinstance(clients, list) or not clients or not isinstance(clients[0], dict):
            continue
        sample = clients[0]
        proto = inbound.get("protocol")
        if proto == "vless" or "id" in sample:
            cloned = []
            for user in users:
                item = copy.deepcopy(sample)
                item["id"] = user["uuid"]
                item["email"] = user["name"]
                cloned.append(item)
            settings["clients"] = cloned
            vless += 1
        elif proto == "hysteria" or "auth" in sample:
            cloned = []
            for user in users:
                item = copy.deepcopy(sample)
                item["auth"] = user["hy2"]
                item.pop("email", None)
                cloned.append(item)
            settings["clients"] = cloned
            hy2 += 1
    if vless == 0:
        die("в config.json нет vless-клиентов")
    return vless, hy2


def render_nginx_block(paths, indent, html_inner, json_inner):
    lines = [f"{indent}{MARKER_START}\n"]
    for path in paths:
        lines.append(f"{indent}location = /{path}.html {{{html_inner}}}\n")
        lines.append(f"{indent}location = /{path}.json {{{json_inner}}}\n")
    lines.append(f"{indent}{MARKER_END}\n")
    return "".join(lines)


def patch_nginx(text, block, legacy):
    marker_re = re.compile(
        rf"^[ \t]*{re.escape(MARKER_START)}.*?^[ \t]*{re.escape(MARKER_END)}[ \t]*\n?",
        re.M | re.S,
    )
    marker = marker_re.search(text)
    if marker:
        insert_at = marker.start()
        text = text[: marker.start()] + text[marker.end() :]
    else:
        locs = [
            item
            for item in extract_locations(text)
            if item["name"] == legacy and item["kind"] in ("json", "html")
        ]
        if not locs:
            die(f"в nginx нет location /{legacy}.json — выполните enable")
        start = min(item["start"] for item in locs)
        end = max(item["end"] for item in locs)
        if end < len(text) and text[end] == "\n":
            end += 1
        insert_at = start
        text = text[:start] + text[end:]
    return text[:insert_at] + block + text[insert_at:]


def safe_unlink(web, name):
    if name in ("", "index.html") or "/" in name or name.startswith("."):
        return
    path = os.path.realpath(os.path.join(web, name))
    root = os.path.realpath(web)
    if path != os.path.join(root, name):
        return
    if os.path.isfile(path):
        os.remove(path)
        log(f"удалён {path}")


def sync():
    state = load_state()
    if not state:
        die("нет снимка сервера — выполните enable")
    for path in (TEMPLATE_JSON, TEMPLATE_HTML, LOCATION_JSON, LOCATION_HTML, CFG_PATH):
        if not os.path.isfile(path):
            die(f"нет {path} — выполните enable")
    if not os.path.isfile(CLIENTS_TXT):
        die(f"нет {CLIENTS_TXT}")
    names = parse_clients(CLIENTS_TXT)
    validate_names(names)
    template_raw = read_text(TEMPLATE_JSON)
    if state["seed_uuid"] not in template_raw:
        die("template.json больше не содержит исходный UUID — верните его и запустите sync")
    template_doc = json.loads(template_raw)
    template_html = read_text(TEMPLATE_HTML)
    cfg = load_json(CFG_PATH)

    existing = load_records()
    seed_taken = any(rec.get("uuid") == state["seed_uuid"] for rec in existing.values())
    users = []
    os.makedirs(CLIENTS_DIR, exist_ok=True)
    for name in names:
        sub = name.lower()
        rec = existing.get(name)
        if rec and rec.get("uuid"):
            user_uuid = rec["uuid"]
            user_hy2 = rec.get("hy2") or ""
        else:
            if not seed_taken:
                user_uuid = state["seed_uuid"]
                user_hy2 = state.get("seed_hy2") or secrets.token_hex(8)
                seed_taken = True
                log(f"{name}: получает исходные ключи установщика")
            else:
                user_uuid = str(uuid.uuid4())
                user_hy2 = secrets.token_hex(8)
                log(f"новый клиент: {name}")
        if state.get("seed_hy2") and not user_hy2:
            user_hy2 = secrets.token_hex(8)
        record = {"name": name, "uuid": user_uuid, "hy2": user_hy2, "path": sub}
        save_json(client_record_path(name), record, 0o600)
        users.append(record)

    known = set(names)
    for name in list(existing):
        if name not in known:
            try:
                os.remove(client_record_path(name))
            except OSError:
                pass
            log(f"удалён клиент: {name}")

    vless_n, hy2_n = patch_xray(cfg, users)
    save_json(CFG_PATH, cfg, 0o644)

    web = state["web_path"]
    os.makedirs(web, exist_ok=True)
    # Исходная ссылка установщика — псевдоним клиента с его UUID.
    # После переустановки autoXRAY2 этот UUID уже ничей: ссылку получает первый клиент,
    # а ключи, которые установщик только что напечатал, не используются.
    alias = next((user for user in users if user["uuid"] == state["seed_uuid"]), users[0])
    paths = [state["legacy_subpage"]]
    for user in users:
        if user["path"] not in paths:
            paths.append(user["path"])

    written = []
    for user in users:
        doc = copy.deepcopy(template_doc)
        transform(doc, state["seed_uuid"], state.get("seed_hy2") or "", user["uuid"], user["hy2"], user["name"])
        page = render_html(
            template_html,
            state,
            user["uuid"],
            user["hy2"],
            user["path"],
            user["name"],
            keep_paths=False,
        )
        json_name = user["path"] + ".json"
        html_name = user["path"] + ".html"
        atomic_write(os.path.join(web, json_name), json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
        atomic_write(os.path.join(web, html_name), page)
        written.extend((json_name, html_name))
        log(f"подписка /{json_name} ({user['name']})")

    if state["legacy_subpage"] != alias["path"]:
        doc = copy.deepcopy(template_doc)
        transform(
            doc,
            state["seed_uuid"],
            state.get("seed_hy2") or "",
            alias["uuid"],
            alias["hy2"],
            alias["name"],
        )
        page = render_html(
            template_html,
            state,
            alias["uuid"],
            alias["hy2"],
            state["legacy_subpage"],
            alias["name"],
            keep_paths=True,
        )
        json_name = state["legacy_subpage"] + ".json"
        html_name = state["legacy_subpage"] + ".html"
        atomic_write(os.path.join(web, json_name), json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
        atomic_write(os.path.join(web, html_name), page)
        written.extend((json_name, html_name))

    old = []
    if os.path.isfile(GENERATED):
        try:
            old = load_json(GENERATED)
        except (OSError, json.JSONDecodeError):
            old = []
    new_set = set(written)
    for name in old:
        if name not in new_set:
            safe_unlink(web, name)
    save_json(GENERATED, written, 0o600)

    indent = state.get("location_indent") or "    "
    block = render_nginx_block(
        paths,
        indent,
        read_text(LOCATION_HTML),
        read_text(LOCATION_JSON),
    )
    nginx_path = state["nginx_config"]
    patched = patch_nginx(read_text(nginx_path), block, state["legacy_subpage"])
    atomic_write(nginx_path, patched, 0o644)

    lines = []
    domain = state["domain"]
    for user in users:
        lines.append(f"[{user['name']}]")
        lines.append(f"  подписка: https://{domain}/{user['path']}.json")
        lines.append(f"  страница: https://{domain}/{user['path']}.html")
        lines.append(f"  uuid:     {user['uuid']}")
        if user.get("hy2"):
            lines.append(f"  hy2:      {user['hy2']}")
        if user is alias and state["legacy_subpage"] != user["path"]:
            lines.append(
                f"  прежняя ссылка установщика: https://{domain}/{state['legacy_subpage']}.json"
            )
        lines.append("")
    atomic_write(URLS_PATH, "\n".join(lines), 0o600)
    log(f"xray: {len(users)} клиент(ов), vless-inbounds {vless_n}, hysteria-inbounds {hy2_n}")


def cmd_list():
    state = load_state()
    if not state:
        die("нет снимка сервера — выполните enable")
    if not os.path.isfile(URLS_PATH):
        die("нет сводки — выполните sync")
    sys.stdout.write(read_text(URLS_PATH))


def cmd_check_name(name):
    if not NAME_RE.fullmatch(name):
        die(f"недопустимое имя «{name}»")
    if not os.path.isfile(CLIENTS_TXT):
        die(f"нет {CLIENTS_TXT} — сначала enable")
    names = parse_clients(CLIENTS_TXT)
    sub = name.lower()
    for current in names:
        if current == name or current.lower() == sub:
            die(f"клиент «{name}» уже есть или путь /{sub} занят именем «{current}»")


def cmd_nginx_path():
    state = load_state()
    if not state or not state.get("nginx_config"):
        die("нет снимка сервера — выполните enable")
    sys.stdout.write(state["nginx_config"])


def main():
    args = sys.argv[1:]
    if not args:
        die("не указана команда")
    cmd, rest = args[0], args[1:]
    if cmd == "capture":
        capture(force="--force" in rest)
    elif cmd == "sync":
        sync()
    elif cmd == "list":
        cmd_list()
    elif cmd == "check-name" and rest:
        cmd_check_name(rest[0])
    elif cmd == "nginx-path":
        cmd_nginx_path()
    else:
        die(f"неизвестная команда {cmd}")


if __name__ == "__main__":
    main()
PY
}

ensure_clients_file() {
    mkdir -p "$STATE_DIR"
    if [[ -f "$AX_DIR/clients.txt" ]]; then
        return 0
    fi
    if [[ -f "$SCRIPT_DIR/clients.txt" ]]; then
        cp "$SCRIPT_DIR/clients.txt" "$AX_DIR/clients.txt"
    else
        printf '%s\n' "default" > "$AX_DIR/clients.txt"
    fi
    chmod 644 "$AX_DIR/clients.txt"
}

cmd_adopt() {
    need_root
    mkdir -p "$AX_DIR" "$STATE_DIR"
    ensure_clients_file
    ax_py capture
    cmd_sync
}

cmd_sync() {
    need_root
    local cfg="$AX_DIR/config.json"
    local nginx bak_cfg bak_nginx
    nginx="$(ax_py nginx-path)"
    [[ -f "$cfg" && -f "$nginx" ]] || { echo "нет config.json или nginx-конфига" >&2; exit 1; }
    bak_cfg="${cfg}.multi-bak"
    bak_nginx="${nginx}.multi-bak"
    cp -a "$cfg" "$bak_cfg"
    cp -a "$nginx" "$bak_nginx"
    chmod 600 "$bak_cfg" "$bak_nginx" || true

    restore() {
        mv -f "$bak_cfg" "$cfg"
        mv -f "$bak_nginx" "$nginx"
    }

    if ! ax_py sync; then
        restore
        echo "sync не выполнен, конфиги возвращены" >&2
        exit 1
    fi
    if [[ "${AUTOXRAY_SKIP_RESTART:-}" == "1" ]]; then
        return 0
    fi
    if ! xray -test -config "$cfg"; then
        restore
        echo "xray -test не прошёл, конфиги возвращены" >&2
        exit 1
    fi
    if ! nginx -t; then
        restore
        echo "nginx -t не прошёл, конфиги возвращены" >&2
        exit 1
    fi
    systemctl restart xray
    systemctl reload nginx
}

cmd_install() {
    local force=0 domain="" arg script="" cleanup=""
    for arg in "$@"; do
        case "$arg" in
            --force) force=1 ;;
            -*) echo "неизвестный флаг: $arg" >&2; exit 1 ;;
            *)
                [[ -z "$domain" ]] || { echo "лишний аргумент: $arg" >&2; exit 1; }
                domain="$arg"
                ;;
        esac
    done
    [[ -n "$domain" ]] || { echo "укажите домен" >&2; usage >&2; exit 1; }
    need_root
    if [[ -f "$AX_DIR/config.json" && "$force" -eq 0 ]]; then
        echo "Xray уже настроен ($AX_DIR/config.json)." >&2
        echo "Подключить multi: enable. Переустановка со сменой ключей: install --force $domain" >&2
        exit 1
    fi
    if [[ -n "${AUTOXRAY_SCRIPT:-}" ]]; then
        script="$AUTOXRAY_SCRIPT"
        [[ -f "$script" ]] || { echo "нет $script" >&2; exit 1; }
    else
        script="$(mktemp)"
        cleanup=1
        echo "Скачиваю свежий autoXRAY2.sh" >&2
        curl -fsSL --retry 3 --connect-timeout 20 "$UPSTREAM_URL" -o "$script" || {
            rm -f "$script"
            exit 1
        }
    fi
    set +e
    bash "$script" "$domain"
    local rc=$?
    set -e
    [[ -n "$cleanup" ]] && rm -f "$script"
    [[ "$rc" -eq 0 ]] || exit "$rc"
    cmd_adopt
}

cmd_add() {
    local name="${1:-}"
    [[ -n "$name" ]] || { echo "укажите имя клиента" >&2; exit 1; }
    ax_py check-name "$name"
    printf '%s\n' "$name" >> "$AX_DIR/clients.txt"
    cmd_sync
}

cmd_remove() {
    local name="${1:-}" tmp remaining
    [[ -n "$name" ]] || { echo "укажите имя клиента" >&2; exit 1; }
    [[ -f "$AX_DIR/clients.txt" ]] || { echo "нет $AX_DIR/clients.txt" >&2; exit 1; }
    tmp="$(mktemp)"
    awk -v n="$name" '
        {
            line = $0
            sub(/#.*/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line == n) next
            print
        }
    ' "$AX_DIR/clients.txt" > "$tmp"
    if cmp -s "$tmp" "$AX_DIR/clients.txt"; then
        rm -f "$tmp"
        echo "нет клиента «$name»" >&2
        exit 1
    fi
    remaining="$(awk '
        {
            line = $0
            sub(/#.*/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line != "") count++
        }
        END { print count + 0 }
    ' "$tmp")"
    if [[ "$remaining" -lt 1 ]]; then
        rm -f "$tmp"
        echo "нельзя удалить последнего клиента" >&2
        exit 1
    fi
    mv "$tmp" "$AX_DIR/clients.txt"
    cmd_sync
}

cmd_update_core() {
    need_root
    bash -c "$(curl -fsSL --retry 3 --connect-timeout 20 "$XRAY_INSTALL_URL")" @ install
    if [[ "${AUTOXRAY_SKIP_RESTART:-}" == "1" ]]; then
        return 0
    fi
    systemctl restart xray
}

main() {
    local cmd="${1:-}"
    if [[ $# -gt 0 ]]; then
        shift
    fi
    case "$cmd" in
        install) cmd_install "$@" ;;
        enable|adopt) cmd_adopt "$@" ;;
        sync) cmd_sync "$@" ;;
        add) cmd_add "$@" ;;
        remove) cmd_remove "$@" ;;
        list) ax_py list ;;
        update-core) cmd_update_core "$@" ;;
        help|-h|--help) usage ;;
        *) usage >&2; exit 1 ;;
    esac
}

main "$@"
