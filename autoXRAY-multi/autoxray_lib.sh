#!/bin/bash
# Shared helpers for multi-client autoXRAY (sourced, not executed directly)

AX_DIR="${AX_DIR:-/usr/local/etc/xray}"
AX_CLIENTS_DIR="${AX_CLIENTS_DIR:-$AX_DIR/clients}"
AX_SERVER_ENV="${AX_SERVER_ENV:-$AX_DIR/server.env}"
AX_CLIENTS_TXT="${AX_CLIENTS_TXT:-$AX_DIR/clients.txt}"
AX_ENABLED_CFG="${AX_ENABLED_CFG:-$AX_DIR/enabled_configs}"
AX_XRAY_CFG="${AX_XRAY_CFG:-$AX_DIR/config.json}"

NGINX_SUB_MARKER_START="# AUTOXRAY_SUB_LOCATIONS_START"
NGINX_SUB_MARKER_END="# AUTOXRAY_SUB_LOCATIONS_END"

HAPP_ROUTING='add_header profile-title "base64:YXV0b1hSQVk=";
		add_header routing "happ://routing/onadd/eyJOYW1lIjoiYXV0b1hSQVkiLCJHbG9iYWxQcm94eSI6InRydWUiLCJSb3V0ZU9yZGVyIjoiYmxvY2stcHJveHktZGlyZWN0IiwiUmVtb3RlRE5TVHlwZSI6IkRvSCIsIlJlbW90ZUROU0RvbWFpbiI6Imh0dHBzOi8vZG5zLmdvb2dsZS9kbnMtcXVlcnkiLCJSZW1vdGVETlNJUCI6IjguOC40LjQiLCJEb21lc3RpY0ROU1R5cGUiOiJEb0giLCJEb21lc3RpY0ROU0RvbWFpbiI6Imh0dHBzOi8vY2xvdWRmbGFyZS1kbnMuY29tL2Rucy1xdWVyeSIsIkRvbWVzdGljRE5TSVAiOiIxLjEuMS4xIiwiR2VvaXB1cmwiOiJodHRwczovL2dpdGh1Yi5jb20vTG95YWxzb2xkaWVyL3YycmF5LXJ1bGVzLWRhdC9yZWxlYXNlcy9sYXRlc3QvZG93bmxvYWQvZ2VvaXAuZGF0IiwiR2Vvc2l0ZXVybCI6Imh0dHBzOi8vZ2l0aHViLmNvbS9Mb3lhbHNvbGRpZXIvdjJyYXktcnVsZXMtZGF0L3JlbGVhc2VzL2xhdGVzdC9kb3dubG9hZC9nZW9zaXRlLmRhdCIsIkxhc3RVcGRhdGVkIjoiMTc3NTIwNjEwOCIsIkRuc0hvc3RzIjp7fSwiRGlyZWN0U2l0ZXMiOlsiZ2Vvc2l0ZTpjYXRlZ29yeS1ydSIsImdlb3NpdGU6cHJpdmF0ZSJdLCJEaXJlY3RJcCI6WyJnZW9pcDpwcml2YXRlIl0sIlByb3h5U2l0ZXMiOltdLCJQcm94eUlwIjpbXSwiQmxvY2tTaXRlcyI6WyJnZW9zaXRlOmNhdGVnb3J5LWFkcyIsImdlb3NpdGU6d2luLXNweSJdLCJCbG9ja0lwIjpbXSwiRG9tYWluU3RyYXRlZ3kiOiJJUElmTm9uTWF0Y2giLCJGYWtlRE5TIjoiZmFsc2UiLCJVc2VDaHVua0ZpbGVzIjoiZmFsc2UifQ";
		add_header routing-enable 0;'

ax_load_server_env() {
    [[ -f "$AX_SERVER_ENV" ]] || { echo "Нет $AX_SERVER_ENV — запустите init_server_env.sh"; return 1; }
    # shellcheck source=/dev/null
    source "$AX_SERVER_ENV"
    export DOMAIN WEB_PATH path_xhttp xray_privateKey_vrv xray_publicKey_vrv xray_shortIds_vrv socksUser socksPasw NGINX_CONFIG
}

ax_trim_line() {
    local line="$1"
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    printf '%s' "$line"
}

ax_parse_clients_txt() {
    AX_CLIENT_NAMES=()
    [[ -f "$AX_CLIENTS_TXT" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(ax_trim_line "$line")"
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        line="${line%%#*}"
        line="$(ax_trim_line "$line")"
        [[ -n "$line" ]] && AX_CLIENT_NAMES+=("$line")
    done < "$AX_CLIENTS_TXT"
}

ax_parse_enabled_configs() {
    AX_ENABLED=()
    [[ -f "$AX_ENABLED_CFG" ]] || { AX_ENABLED=(1 2 3 4 5 6 7); return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(ax_trim_line "${line//$'\r'/}")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line%%#*}"
        line="$(ax_trim_line "$line")"
        [[ -z "$line" ]] && continue
        local token
        for token in $line; do
            [[ "$token" =~ ^[1-7]$ ]] && AX_ENABLED+=("$token")
        done
    done < "$AX_ENABLED_CFG"
    if [[ ${#AX_ENABLED[@]} -eq 0 ]]; then
        AX_ENABLED=(1 2 3 4 5 6 7)
    fi
}

# URL-путь подписки = имя клиента в нижнем регистре (латиница, цифры, - _)
ax_client_subpath() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

ax_validate_client_name() {
    local n="$1"
    [[ "$n" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || return 1
}

ax_sync_client_envs() {
    mkdir -p "$AX_CLIENTS_DIR"
    local name envf subpath uuid old_path
    declare -A AX_SEEN=()

    for name in "${AX_CLIENT_NAMES[@]}"; do
        if ! ax_validate_client_name "$name"; then
            echo "Ошибка: недопустимое имя «$name» (только a-z A-Z 0-9 _ -)"
            exit 1
        fi
        if [[ -n "${AX_SEEN[$name]:-}" ]]; then
            echo "Ошибка: дубликат клиента «$name» в clients.txt"
            exit 1
        fi
        AX_SEEN[$name]=1
    done

    for name in "${AX_CLIENT_NAMES[@]}"; do
        envf="$AX_CLIENTS_DIR/${name}.env"
        subpath="$(ax_client_subpath "$name")"
        old_path=""
        uuid=""

        if [[ -f "$envf" ]]; then
            # shellcheck source=/dev/null
            source "$envf"
            old_path="$path_subpage"
            uuid="$xray_uuid_vrv"
        else
            uuid="$(xray uuid)"
            echo "Новый клиент: $name"
        fi

        if [[ "$old_path" != "$subpath" && -n "$old_path" ]]; then
            rm -f "$WEB_PATH/${old_path}.json" "$WEB_PATH/${old_path}.html"
            echo "Переименован путь: /${old_path}.* -> /${subpath}.* ($name)"
        fi

        cat > "$envf" <<EOF
CLIENT_NAME='$name'
xray_uuid_vrv='$uuid'
path_subpage='$subpath'
EOF
    done
    # Удалить env и веб-файлы для клиентов, которых нет в clients.txt
    for envf in "$AX_CLIENTS_DIR"/*.env; do
        [[ -f "$envf" ]] || continue
        # shellcheck source=/dev/null
        source "$envf"
        local found=0
        for name in "${AX_CLIENT_NAMES[@]}"; do
            [[ "$name" == "$CLIENT_NAME" ]] && found=1
        done
        if [[ $found -eq 0 ]]; then
            rm -f "$envf" "$WEB_PATH/${path_subpage}.json" "$WEB_PATH/${path_subpage}.html"
            echo "Удалён клиент: $CLIENT_NAME"
        fi
    done
}

ax_patch_xray_clients() {
    python3 <<'PY'
import json, os, glob

ax_dir = os.environ.get("AX_DIR", "/usr/local/etc/xray")
cfg_path = os.path.join(ax_dir, "config.json")
clients_dir = os.path.join(ax_dir, "clients")

uuids = []
for path in sorted(glob.glob(os.path.join(clients_dir, "*.env"))):
    data = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip().strip("'\"")
    u = data.get("xray_uuid_vrv")
    if u:
        uuids.append(u)

if not uuids:
    raise SystemExit("Нет UUID клиентов в clients/*.env")

with open(cfg_path) as f:
    cfg = json.load(f)

vision = [{"flow": "xtls-rprx-vision", "id": u} for u in uuids]
plain = [{"id": u} for u in uuids]

for ib in cfg.get("inbounds", []):
    if ib.get("protocol") != "vless":
        continue
    st = ib.get("settings") or {}
    if "clients" not in st:
        continue
    cur = st["clients"]
    if not cur:
        continue
    needs_flow = any("flow" in c for c in cur)
    st["clients"] = vision if needs_flow else plain

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
print(f"Xray: {len(uuids)} клиент(ов) в inbounds vless")
PY
}

ax_nginx_sub_block() {
    local path_subpage="$1"
    cat <<EOF
    location = /${path_subpage}.json {
		${HAPP_ROUTING}
	}
EOF
}

ax_patch_nginx_sub_locations() {
    [[ -n "$NGINX_CONFIG" && -f "$NGINX_CONFIG" ]] || { echo "NGINX_CONFIG не задан"; return 1; }
    local blocks_file envf
    blocks_file="$(mktemp)"
    for envf in "$AX_CLIENTS_DIR"/*.env; do
        [[ -f "$envf" ]] || continue
        # shellcheck source=/dev/null
        source "$envf"
        ax_nginx_sub_block "$path_subpage" >> "$blocks_file"
    done
    NGINX_CONFIG="$NGINX_CONFIG" BLOCKS_FILE="$blocks_file" \
    NGINX_SUB_MARKER_START="$NGINX_SUB_MARKER_START" NGINX_SUB_MARKER_END="$NGINX_SUB_MARKER_END" \
    python3 <<'PY'
import os, re
nginx = os.environ["NGINX_CONFIG"]
start = os.environ["NGINX_SUB_MARKER_START"]
end = os.environ["NGINX_SUB_MARKER_END"]
with open(os.environ["BLOCKS_FILE"]) as f:
    blocks = f.read()
with open(nginx) as f:
    text = f.read()
if start in text:
    text = re.sub(
        re.escape(start) + r".*?" + re.escape(end),
        start + "\n" + blocks + end,
        text,
        count=1,
        flags=re.DOTALL,
    )
else:
    text = re.sub(
        r"\n\s*location = /[A-Za-z0-9_-]+\.json \{.*?\n\s*\}",
        "\n" + start + "\n" + blocks + end,
        text,
        count=1,
        flags=re.DOTALL,
    )
with open(nginx, "w") as f:
    f.write(text)
print("nginx: обновлены location подписок")
PY
    rm -f "$blocks_file"
    nginx -t && systemctl reload nginx
}

ax_cleanup_stale_web_files() {
    local envf subpath keep="" f base
    for envf in "$AX_CLIENTS_DIR"/*.env; do
        [[ -f "$envf" ]] || continue
        # shellcheck source=/dev/null
        source "$envf"
        keep+="${path_subpage} "
    done
    for f in "$WEB_PATH"/*.json "$WEB_PATH"/*.html; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        [[ "$base" == "index.html" ]] && continue
        sub="${base%.*}"
        [[ " $keep " == *" $sub "* ]] && continue
        rm -f "$f"
        echo "Удалён устаревший файл: $f"
    done
}

ax_write_clients_urls() {
    local envf urls="$AX_DIR/clients_urls.txt"
    : > "$urls"
    for envf in "$AX_CLIENTS_DIR"/*.env; do
        [[ -f "$envf" ]] || continue
        # shellcheck source=/dev/null
        source "$envf"
        {
            echo "[$CLIENT_NAME]"
            echo "  подписка: https://$DOMAIN/${path_subpage}.json"
            echo "  конфиги:  https://$DOMAIN/${path_subpage}.html"
            echo "  uuid:     $xray_uuid_vrv"
            echo
        } >> "$urls"
    done
}

ax_print_client_summary() {
    local envf
    echo ""
    echo "=== Ссылки клиентов (по имени) ==="
    for envf in "$AX_CLIENTS_DIR"/*.env; do
        [[ -f "$envf" ]] || continue
        # shellcheck source=/dev/null
        source "$envf"
        echo "  $CLIENT_NAME:"
        echo "    https://$DOMAIN/${path_subpage}.json"
        echo "    https://$DOMAIN/${path_subpage}.html"
    done
    echo "Сводка также в: $AX_DIR/clients_urls.txt"
    echo ""
}
