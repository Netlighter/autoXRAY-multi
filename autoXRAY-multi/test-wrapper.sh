#!/bin/bash
# Локальная проверка обёртки без root, nginx и xray.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAP="$ROOT/autoxray-multi.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SEED="11111111-1111-1111-1111-111111111111"
HY2="aabbccddeeff0011"
LEGACY="AbCdEfGhIjKlMnOpQrSt"
DOMAIN="example.com"
WEB="$WORK/www"
NGINX="$WORK/nginx.conf"
AX="$WORK/xray"

mkdir -p "$WEB" "$AX"
export AX_DIR="$AX"
export AX_STATE_DIR="$AX/multi"
export AX_NGINX_CONFIG="$NGINX"
export AUTOXRAY_SKIP_RESTART=1

cat > "$AX/config.json" <<EOF
{
  "inbounds": [
    {
      "protocol": "vless",
      "tag": "vision",
      "settings": {
        "clients": [
          {"flow": "xtls-rprx-vision", "id": "$SEED"}
        ]
      }
    },
    {
      "protocol": "vless",
      "tag": "xhttp",
      "settings": {
        "clients": [
          {"id": "$SEED"}
        ]
      }
    },
    {
      "protocol": "hysteria",
      "tag": "hy2",
      "settings": {
        "clients": [
          {"auth": "$HY2"}
        ]
      }
    }
  ]
}
EOF

cat > "$WEB/$LEGACY.json" <<EOF
[
  {
    "remarks": "🇪🇺 VLESS RAW TLS VISION",
    "outbounds": [
      {
        "protocol": "vless",
        "settings": {
          "vnext": [
            {
              "users": [
                {"encryption": "none", "flow": "xtls-rprx-vision", "id": "$SEED"}
              ]
            }
          ]
        }
      }
    ],
    "routing": {"rules": [{"domain": ["geosite:category-ru"], "outboundTag": "direct"}]}
  },
  {
    "remarks": "🇪🇺 HYSTERIA2",
    "outbounds": [
      {
        "protocol": "hysteria",
        "streamSettings": {"hysteriaSettings": {"auth": "$HY2"}}
      }
    ]
  }
]
EOF

cat > "$WEB/$LEGACY.html" <<EOF
<!DOCTYPE html><html><head><title>autoXRAY configs</title></head><body>
<h2>📂 Ссылка на подписку</h2>
<div id="subLink">https://$DOMAIN/$LEGACY.json</div>
<div id="c1">vless://$SEED@$DOMAIN:443?security=tls&amp;type=tcp#raw</div>
<div id="c2">hy2://$HY2@$DOMAIN:443/?sni=$DOMAIN#Hysteria2</div>
<a href="happ://add/https://$DOMAIN/$LEGACY.json">add</a>
</body></html>
EOF

cat > "$NGINX" <<EOF
server {
    server_name $DOMAIN;
    root $WEB;

    location = /$LEGACY.html {
        try_files \$uri =404;
    }

    location = /$LEGACY.json {
        add_header X-Test "a{b}c";
        add_header profile-title "base64:YXV0b1hSQVk=";
        try_files \$uri =404;
    }

    location /secretpath {
        grpc_pass grpc://127.0.0.1:3333;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "install отказывается, если конфиг уже есть"
if bash "$WRAP" install "$DOMAIN" >"$WORK/install.out" 2>&1; then
    fail "install должен остановиться"
fi
grep -q "adopt" "$WORK/install.out" || fail "install не предложил adopt"

echo "adopt"
bash "$WRAP" adopt

python3 - "$AX" "$WEB" "$NGINX" "$SEED" "$HY2" "$LEGACY" "$DOMAIN" <<'PY'
import json, pathlib, sys
ax, web, nginx, seed, hy2, legacy, domain = sys.argv[1:]
web, ax = pathlib.Path(web), pathlib.Path(ax)
cfg = json.loads((ax / "config.json").read_text())
by_tag = {ib["tag"]: ib for ib in cfg["inbounds"]}
assert by_tag["vision"]["settings"]["clients"] == [
    {"flow": "xtls-rprx-vision", "id": seed, "email": "default"}
], by_tag["vision"]
assert "flow" not in by_tag["xhttp"]["settings"]["clients"][0]
assert by_tag["xhttp"]["settings"]["clients"][0]["id"] == seed
assert by_tag["hy2"]["settings"]["clients"] == [{"auth": hy2}]
sub = json.loads((web / "default.json").read_text())
assert sub[0]["remarks"] == "🇪🇺 VLESS RAW TLS VISION [default]"
assert sub[0]["routing"]["rules"][0]["domain"] == ["geosite:category-ru"]
assert sub[1]["outbounds"][0]["streamSettings"]["hysteriaSettings"]["auth"] == hy2
legacy_doc = json.loads((web / f"{legacy}.json").read_text())
assert legacy_doc[0]["outbounds"][0]["settings"]["vnext"][0]["users"][0]["id"] == seed
page = (web / "default.html").read_text()
assert page.count("<h2>Клиент: default</h2>") == 1
assert f"https://{domain}/default.json" in page
assert f"/{legacy}.json" not in page
legacy_page = (web / f"{legacy}.html").read_text()
assert f"https://{domain}/{legacy}.json" in legacy_page
conf = pathlib.Path(nginx).read_text()
assert conf.count(f"location = /{legacy}.json") == 1
assert conf.count("location = /default.json") == 1
assert 'add_header X-Test "a{b}c";' in conf
assert "grpc_pass grpc://127.0.0.1:3333;" in conf
assert conf.count("# AUTOXRAY_MULTI_SUB_START") == 1
state = json.loads((ax / "multi" / "server.json").read_text())
assert state["path_xhttp"] == "secretpath"
assert state["seed_uuid"] == seed
print("adopt ok")
PY

echo "повторный adopt не удваивает пометку"
bash "$WRAP" adopt
python3 - "$WEB" <<'PY'
import json, pathlib, sys
web = pathlib.Path(sys.argv[1])
sub = json.loads((web / "default.json").read_text())
assert sub[0]["remarks"].count("[default]") == 1, sub[0]["remarks"]
page = (web / "default.html").read_text()
assert page.count("<h2>Клиент: default</h2>") == 1
print("idempotent ok")
PY

echo "add bob"
bash "$WRAP" add bob
python3 - "$AX" "$WEB" "$NGINX" "$SEED" "$HY2" "$LEGACY" "$DOMAIN" <<'PY'
import json, pathlib, re, sys
ax, web, nginx, seed, hy2, legacy, domain = sys.argv[1:]
web, ax = pathlib.Path(web), pathlib.Path(ax)
cfg = json.loads((ax / "config.json").read_text())
by_tag = {ib["tag"]: ib for ib in cfg["inbounds"]}
vision = by_tag["vision"]["settings"]["clients"]
assert len(vision) == 2
assert all(c["flow"] == "xtls-rprx-vision" for c in vision)
assert {c["email"] for c in vision} == {"default", "bob"}
xhttp = by_tag["xhttp"]["settings"]["clients"]
assert all("flow" not in c for c in xhttp)
auths = [c["auth"] for c in by_tag["hy2"]["settings"]["clients"]]
assert hy2 in auths and len(set(auths)) == 2
bob = json.loads((ax / "multi" / "clients" / "bob.json").read_text())
assert bob["uuid"] != seed
assert re.fullmatch(r"[0-9a-f]{16}", bob["hy2"])
sub = json.loads((web / "bob.json").read_text())
assert seed not in json.dumps(sub)
assert sub[1]["outbounds"][0]["streamSettings"]["hysteriaSettings"]["auth"] == bob["hy2"]
assert sub[0]["remarks"].endswith(" [bob]")
assert "[default]" not in sub[0]["remarks"]
page = (web / "bob.html").read_text()
assert f"hy2://{bob['hy2']}@{domain}" in page
assert f"hy2://{hy2}@" not in page
assert f"https://{domain}/bob.json" in page
assert seed not in page
legacy_page = (web / f"{legacy}.html").read_text()
assert seed in legacy_page
assert f"https://{domain}/{legacy}.json" in legacy_page
conf = pathlib.Path(nginx).read_text()
assert conf.count("location = /bob.json") == 1
assert conf.count("# AUTOXRAY_MULTI_SUB_START") == 1
print("bob ok")
PY

echo "sync повторно не плодит location"
before="$(cksum "$NGINX" "$AX/config.json")"
bash "$WRAP" sync
after="$(cksum "$NGINX" "$AX/config.json")"
[[ "$before" == "$after" ]] || fail "повторный sync изменил nginx или config"

echo "плохое имя и дубликат"
if bash "$WRAP" add '../x' >/dev/null 2>&1; then
    fail "имя ../x должно быть отвергнуто"
fi
if bash "$WRAP" add Default >/dev/null 2>&1; then
    fail "путь default уже занят"
fi
grep -q '^bob$' "$AX/clients.txt" || fail "bob пропал из списка"
# Плохие add не должны были дописать строку.
[[ "$(grep -c '^Default$' "$AX/clients.txt" || true)" -eq 0 ]] || fail "Default записан"

echo "remove bob"
bash "$WRAP" remove bob
[[ ! -f "$WEB/bob.json" && ! -f "$WEB/bob.html" ]] || fail "файлы bob остались"
python3 - "$AX" <<'PY'
import json, sys
from pathlib import Path
ax = Path(sys.argv[1])
cfg = json.loads((ax / "config.json").read_text())
clients = cfg["inbounds"][0]["settings"]["clients"]
assert len(clients) == 1 and clients[0]["email"] == "default"
assert not (ax / "multi" / "clients" / "bob.json").exists()
print("remove ok")
PY

echo "переустановка подхватывает новый шаблон и не ротирует UUID клиентов"
NEW_SEED="22222222-2222-2222-2222-222222222222"
NEW_HY2="0011223344556677"
NEW_LEGACY="ZzYyXxWwVvUuTtSsRrQq"
cat > "$AX/config.json" <<EOF
{
  "inbounds": [
    {
      "protocol": "vless",
      "tag": "vision",
      "settings": {"clients": [{"flow": "xtls-rprx-vision", "id": "$NEW_SEED"}]}
    },
    {
      "protocol": "hysteria",
      "tag": "hy2",
      "settings": {"clients": [{"auth": "$NEW_HY2"}]}
    }
  ]
}
EOF
cat > "$WEB/$NEW_LEGACY.json" <<EOF
[
  {"remarks": "🇪🇺 VLESS RAW TLS VISION", "outbounds": [{"protocol": "vless", "settings": {"vnext": [{"users": [{"id": "$NEW_SEED", "flow": "xtls-rprx-vision"}]}]}}]},
  {"remarks": "🇪🇺 HYSTERIA2", "outbounds": [{"protocol": "hysteria", "streamSettings": {"hysteriaSettings": {"auth": "$NEW_HY2"}}}]}
]
EOF
printf '<html><head><title>autoXRAY configs</title></head><body>\n<div id="subLink">https://%s/%s.json</div>\n<div>vless://%s@%s:443#raw</div>\n</body></html>\n' \
    "$DOMAIN" "$NEW_LEGACY" "$NEW_SEED" "$DOMAIN" > "$WEB/$NEW_LEGACY.html"
cat > "$NGINX" <<EOF
server {
    server_name $DOMAIN;
    root $WEB;
    location = /$NEW_LEGACY.html {
        try_files \$uri =404;
    }
    location = /$NEW_LEGACY.json {
        add_header X-Fresh "yes";
        try_files \$uri =404;
    }
}
EOF
bash "$WRAP" adopt
python3 - "$AX" "$WEB" "$SEED" "$NEW_SEED" "$NEW_HY2" "$NEW_LEGACY" "$DOMAIN" <<'PY'
import json, sys
from pathlib import Path
ax, web, seed, new_seed, new_hy2, legacy, domain = sys.argv[1:]
ax, web = Path(ax), Path(web)
rec = json.loads((ax / "multi" / "clients" / "default.json").read_text())
assert rec["uuid"] == seed, rec
assert rec["hy2"] != new_hy2
cfg = json.loads((ax / "config.json").read_text())
ids = [c["id"] for ib in cfg["inbounds"] if ib["protocol"] == "vless" for c in ib["settings"]["clients"]]
assert ids == [seed], ids
page = (web / f"{legacy}.html").read_text()
assert seed in page and new_seed not in page
assert f"https://{domain}/{legacy}.json" in page
sub = json.loads((web / f"{legacy}.json").read_text())
assert sub[1]["outbounds"][0]["streamSettings"]["hysteriaSettings"]["auth"] == rec["hy2"]
print("recapture uuid kept")
PY
grep -q 'add_header X-Fresh "yes";' "$NGINX" || fail "новый заголовок nginx потерян"
grep -q "location = /$NEW_LEGACY.json" "$NGINX" || fail "новый путь подписки не прописан"
if grep -q "$LEGACY" "$NGINX"; then
    fail "старый location остался"
fi

echo "последнего клиента не удаляем"
if bash "$WRAP" remove default >/dev/null 2>&1; then
    fail "последний клиент удалён"
fi
grep -q '^default$' "$AX/clients.txt" || fail "default стёрт"

echo "OK"
