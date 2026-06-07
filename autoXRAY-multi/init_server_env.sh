#!/bin/bash
# Однократно: сохранить параметры текущей установки autoXRAY в server.env

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Нужны root"; exit 1; }

AX_DIR="${AX_DIR:-/usr/local/etc/xray}"
export AX_DIR
CFG="$AX_DIR/config.json"
OUT="$AX_DIR/server.env"

python3 <<PY
import json, os, re, subprocess

ax_dir = os.environ.get("AX_DIR", "/usr/local/etc/xray")
cfg_path = os.path.join(ax_dir, "config.json")
with open(cfg_path) as f:
    cfg = json.load(f)

domain = None
path_xhttp = None
short_id = None
priv = None
socks_user = socks_pass = None

for ib in cfg.get("inbounds", []):
    if ib.get("protocol") == "vless" and ib.get("port") == 3333:
        path_xhttp = ib.get("streamSettings", {}).get("xhttpSettings", {}).get("path", "").lstrip("/")
    if ib.get("protocol") == "vless" and ib.get("port") == 443:
        rs = ib.get("streamSettings", {}).get("realitySettings", {})
        domain = (rs.get("serverNames") or [None])[0]
        short_id = (rs.get("shortIds") or [""])[0]
        priv = rs.get("privateKey")
    if ib.get("protocol") == "mixed":
        acc = (ib.get("settings") or {}).get("accounts") or []
        if acc:
            socks_user = acc[0].get("user")
            socks_pass = acc[0].get("pass")

pub = ""
if priv:
    r = subprocess.run(["xray", "x25519", "-i", priv], capture_output=True, text=True)
    for line in (r.stdout or "").splitlines():
        if "Password" in line or "Public" in line:
            pub = line.split(":", 1)[1].strip()

nginx_cfg = "/etc/nginx/sites-available/default"
if not os.path.isfile(nginx_cfg):
    nginx_cfg = "/etc/nginx/conf.d/default.conf"

web_path = f"/var/www/{domain}" if domain else "/var/www/html"

# uuid из config
uuid = None
for ib in cfg.get("inbounds", []):
    cl = (ib.get("settings") or {}).get("clients") or []
    if cl:
        uuid = cl[0].get("id")
        break

out = os.path.join(ax_dir, "server.env")
lines = [
    f"DOMAIN='{domain}'",
    f"WEB_PATH='{web_path}'",
    f"path_xhttp='{path_xhttp}'",
    f"xray_privateKey_vrv='{priv}'",
    f"xray_publicKey_vrv='{pub}'",
    f"xray_shortIds_vrv='{short_id}'",
    f"socksUser='{socks_user}'",
    f"socksPasw='{socks_pass}'",
    f"NGINX_CONFIG='{nginx_cfg}'",
]
with open(out, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"Записано: {out}")
if uuid:
    clients_dir = os.path.join(ax_dir, "clients")
    os.makedirs(clients_dir, exist_ok=True)
    default_env = os.path.join(clients_dir, "default.env")
    if not os.path.isfile(default_env):
        with open(default_env, "w") as f:
            f.write(f"CLIENT_NAME='default'\nxray_uuid_vrv='{uuid}'\npath_subpage='default'\n")
        print(f"Миграция клиента default -> {default_env} (путь /default.json)")
PY
