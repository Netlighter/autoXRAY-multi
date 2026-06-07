#!/bin/bash
# Синхронизация клиентов из clients.txt, xray, nginx, подписки и HTML на каждого клиента

set -euo pipefail

GRN='\033[1;32m'
RED='\033[1;31m'
YEL='\033[1;33m'
NC='\033[0m'

[[ $EUID -eq 0 ]] || { echo -e "${RED}Нужны root права${NC}"; exit 1; }

AX_DIR="${AX_DIR:-/usr/local/etc/xray}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AX_DIR

# shellcheck source=autoxray_lib.sh
source "$SCRIPT_DIR/autoxray_lib.sh"

ax_load_server_env || exit 1
AX_SHOW_SOCKS=1
ax_parse_options
ax_parse_enabled_configs
ax_parse_clients_txt

if [[ ${#AX_CLIENT_NAMES[@]} -eq 0 ]]; then
    echo -e "${RED}clients.txt пуст. Добавьте имена клиентов (по одному в строке).${NC}"
    exit 1
fi

echo -e "${YEL}Клиенты: ${AX_CLIENT_NAMES[*]}${NC}"
echo -e "${YEL}Включённые конфиги: ${AX_ENABLED[*]}${NC}"
if [[ "$AX_SHOW_SOCKS" -eq 1 ]]; then
    echo -e "${YEL}Socks5 в HTML: включён${NC}"
else
    echo -e "${YEL}Socks5 в HTML: выключен${NC}"
fi

ax_sync_client_envs
ax_patch_xray_clients

# Генерация json/html для каждого клиента
export DOMAIN WEB_PATH path_xhttp xray_publicKey_vrv xray_shortIds_vrv socksUser socksPasw
export AX_ENABLED_JSON AX_SHOW_SOCKS
AX_ENABLED_JSON="$(printf '%s\n' "${AX_ENABLED[@]}")"
export AX_SHOW_SOCKS="${AX_SHOW_SOCKS:-1}"

python3 <<'PYGEN'
import json, os, glob, urllib.parse

ax_dir = os.environ["AX_DIR"]
web_path = os.environ["WEB_PATH"]
domain = os.environ["DOMAIN"]
path_xhttp = os.environ["path_xhttp"]
pbk = os.environ["xray_publicKey_vrv"]
sid = os.environ["xray_shortIds_vrv"]
socks_user = os.environ.get("socksUser", "")
socks_pass = os.environ.get("socksPasw", "")
show_socks = os.environ.get("AX_SHOW_SOCKS", "1") not in ("0", "false", "no")
enabled = set(os.environ.get("AX_ENABLED_JSON", "").split())

def load_env(path):
    d = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                d[k.strip()] = v.strip().strip("'\"")
    return d

def print_config(proxy_outbound, remark):
    return {
        "log": {"loglevel": "warning"},
        "dns": {
            "servers": [
                "https://8.8.4.4/dns-query",
                "https://8.8.8.8/dns-query",
                "https://1.1.1.1/dns-query",
            ],
            "queryStrategy": "UseIPv4",
        },
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
                {"domain": ["geosite:category-ads", "geosite:win-spy"], "outboundTag": "block"},
                {"protocol": ["bittorrent"], "outboundTag": "direct"},
                {"domain": ["habr.com", "apkmirror.com"], "outboundTag": "proxy"},
                {
                    "domain": [
                        "geosite:private", "ifconfig.me", "checkip.amazonaws.com", "pify.org",
                        "geosite:category-ip-geo-detect", "geosite:apple", "geosite:apple-pki",
                        "geosite:huawei", "geosite:xiaomi", "geosite:category-android-app-download",
                        "geosite:f-droid", "geosite:yandex", "geosite:vk", "geosite:microsoft",
                        "geosite:win-update", "geosite:win-extra", "geosite:google-play",
                        "geosite:steam", "geosite:category-ru",
                    ],
                    "outboundTag": "direct",
                },
                {"ip": ["geoip:private"], "outboundTag": "direct"},
            ],
        },
        "inbounds": [
            {"tag": "socks-in", "protocol": "socks", "listen": "127.0.0.1", "port": 10808,
             "settings": {"udp": True}, "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}},
            {"tag": "socks-sb", "protocol": "socks", "listen": "127.0.0.1", "port": 2080,
             "settings": {"udp": True}, "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}},
            {"tag": "http-in", "protocol": "http", "listen": "127.0.0.1", "port": 10809,
             "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}},
        ],
        "outbounds": [json.loads(proxy_outbound), {"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}],
        "remarks": remark,
    }

def out_reality_xhttp(uid):
    return {
        "mux": {"concurrency": -1, "enabled": False},
        "tag": "proxy", "protocol": "vless",
        "settings": {"vnext": [{"address": domain, "port": 443, "users": [{"id": uid, "encryption": "none"}]}]},
        "streamSettings": {
            "network": "xhttp", "security": "reality",
            "xhttpSettings": {
                "mode": "stream-one", "path": f"/{path_xhttp}",
                "extra": {
                    "noGRPCHeader": False, "scMaxEachPostBytes": 1500000, "scMinPostsIntervalMs": 20,
                    "scStreamUpServerSecs": "60-240", "xPaddingBytes": "400-800",
                    "xmux": {"cMaxReuseTimes": "1000-3000", "hKeepAlivePeriod": 0, "hMaxRequestTimes": "400-700",
                             "hMaxReusableSecs": "1200-1800", "maxConcurrency": "3-5", "maxConnections": 0},
                },
            },
            "realitySettings": {"show": False, "fingerprint": "chrome", "serverName": domain,
                                "password": pbk, "shortId": sid, "spiderX": "/"},
        },
    }

def out_reality_vision(uid):
    return {
        "mux": {"concurrency": -1, "enabled": False},
        "tag": "proxy", "protocol": "vless",
        "settings": {"vnext": [{"address": domain, "port": 443,
            "users": [{"id": uid, "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
        "streamSettings": {
            "network": "raw", "security": "reality",
            "realitySettings": {"show": False, "fingerprint": "chrome", "serverName": domain,
                                "password": pbk, "shortId": sid, "spiderX": "/"},
        },
    }

def out_tls_vision(uid):
    return {
        "tag": "proxy", "protocol": "vless",
        "settings": {"vnext": [{"address": domain, "port": 8443,
            "users": [{"id": uid, "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
        "streamSettings": {"network": "raw", "security": "tls",
            "tlsSettings": {"serverName": domain, "fingerprint": "chrome"}},
    }

def out_tls_xhttp(uid):
    return {
        "tag": "proxy", "protocol": "vless",
        "settings": {"vnext": [{"address": domain, "port": 8443, "users": [{"id": uid, "encryption": "none"}]}]},
        "streamSettings": {
            "network": "xhttp", "security": "tls",
            "xhttpSettings": {"mode": "auto", "path": f"/{path_xhttp}",
                "extra": {"headers": {}, "noGRPCHeader": False, "scMaxEachPostBytes": 1500000,
                    "scMinPostsIntervalMs": 20, "scStreamUpServerSecs": "60-240", "xPaddingBytes": "400-800",
                    "xmux": {"cMaxReuseTimes": "1000-3000", "hKeepAlivePeriod": 0, "hMaxRequestTimes": "400-700",
                             "hMaxReusableSecs": "1200-1800", "maxConcurrency": "3-5", "maxConnections": 0}}},
            "tlsSettings": {"serverName": domain, "fingerprint": "chrome"},
        },
    }

def out_grpc(uid):
    return {
        "tag": "proxy", "protocol": "vless",
        "settings": {"vnext": [{"address": domain, "port": 8443, "users": [{"id": uid, "encryption": "none"}]}]},
        "streamSettings": {
            "network": "grpc", "grpcSettings": {"serviceName": f"{path_xhttp}11", "multiMode": False},
            "security": "tls", "tlsSettings": {"serverName": domain, "alpn": ["h2"], "fingerprint": "chrome"},
        },
    }

def out_ws(uid):
    return {
        "tag": "proxy", "protocol": "vless",
        "settings": {"vnext": [{"address": domain, "port": 8443, "users": [{"id": uid, "encryption": "none"}]}]},
        "streamSettings": {
            "network": "ws", "wsSettings": {"path": f"/{path_xhttp}22"},
            "security": "tls", "tlsSettings": {"serverName": domain, "fingerprint": "chrome"},
        },
    }

CONFIG_META = {
    "1": ("🇪🇺 VLESS XHTTP REALITY EXTRA", out_reality_xhttp, "vlessXHTTPrealityEXTRA"),
    "2": ("🇪🇺 VLESS RAW REALITY VISION", out_reality_vision, "vlessRAWrealityVISION"),
    "3": ("🇪🇺 VLESS RAW TLS VISION", out_tls_vision, "vlessRAWtlsVision"),
    "4": ("🇪🇺 VLESS XHTTP TLS EXTRA", out_tls_xhttp, "vlessXHTTPtls"),
    "5": ("🇪🇺 VLESS gRPC TLS", out_grpc, "vlessGRPCtls"),
    "6": ("🇪🇺 VLESS WS TLS", out_ws, "vlessWStls"),
}

EXTRA_XHTTP = urllib.parse.quote(
    '{"xmux":{"cMaxReuseTimes":"1000-3000","maxConcurrency":"3-5","maxConnections":0,'
    '"hKeepAlivePeriod":0,"hMaxRequestTimes":"400-700","hMaxReusableSecs":"1200-1800"},'
    '"headers":{},"noGRPCHeader":false,"xPaddingBytes":"400-800","scMaxEachPostBytes":1500000,'
    '"scMinPostsIntervalMs":20,"scStreamUpServerSecs":"60-240"}', safe=""
)

def build_links(uid, client_name):
    links = []
    if "1" in enabled:
        links.append(("VLESS XHTTP REALITY EXTRA (для моста)",
            f"vless://{uid}@{domain}:443?security=reality&type=xhttp&path=%2F{path_xhttp}&mode=stream-one"
            f"&extra={EXTRA_XHTTP}&sni={domain}&fp=chrome&pbk={pbk}&sid={sid}&spx=%2F#vlessXHTTPrealityEXTRA-autoXRAY-{client_name}"))
    if "2" in enabled:
        links.append(("VLESS RAW REALITY VISION",
            f"vless://{uid}@{domain}:443?security=reality&type=tcp&flow=xtls-rprx-vision&sni={domain}&fp=chrome&pbk={pbk}&sid={sid}&spx=%2F#vlessRAWrealityVISION-autoXRAY-{client_name}"))
    if "3" in enabled:
        links.append(("VLESS RAW TLS VISION",
            f"vless://{uid}@{domain}:8443?security=tls&type=tcp&flow=xtls-rprx-vision&sni={domain}&fp=chrome&spx=%2F#vlessRAWtlsVision-autoXRAY-{client_name}"))
    if "4" in enabled:
        links.append(("VLESS XHTTP TLS EXTRA",
            f"vless://{uid}@{domain}:8443?security=tls&type=xhttp&path=%2F{path_xhttp}&mode=auto&extra={EXTRA_XHTTP}&sni={domain}&fp=chrome&spx=%2F#vlessXHTTPtls-autoXRAY-{client_name}"))
    if "5" in enabled:
        links.append(("VLESS GRPC TLS",
            f"vless://{uid}@{domain}:8443?security=tls&type=grpc&serviceName={path_xhttp}11&sni={domain}&fp=chrome&spx=%2F#vlessGRPCtls-autoXRAY-{client_name}"))
    if "6" in enabled:
        links.append(("VLESS WS TLS",
            f"vless://{uid}@{domain}:8443?security=tls&type=ws&path=%2F{path_xhttp}22&sni={domain}&fp=chrome&spx=%2F#vlessWStls-autoXRAY-{client_name}"))
    return links

HTML_HEAD = '''<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<meta name="robots" content="noindex,nofollow">
<title>autoXRAY configs</title>
<link rel="icon" type="image/svg+xml" href='data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMDBCRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBhdGggZD0iTTIxIDJsLTIgMm0tNy42MSA3LjYxYTUuNSA1LjUgMCAxIDEtNy43NzggNy43NzggNS41IDUuNSAwIDAgMSA3Ljc3Ny03Ljc3N3ptMCAwTDE1LjUgNy41bTAgMGwzIDNMMjIgN2wtMy0zbS0zLjUgMy41TDE5IDQiLz48L3N2Zz4='>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>
:root{--bg:#0f1115;--card:#1a1d24;--card2:#141820;--border:#2d3340;--text:#e8eaed;--muted:#9aa3b2;--green:#c3e88d;--blue:#82aaff;--accent:#00bfff}
*{box-sizing:border-box}
body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--text);line-height:1.45}
.wrap{max-width:920px;margin:0 auto;padding:16px 14px 32px}
.hero{background:linear-gradient(135deg,#1a2233 0%,#141820 60%,#1a1d24 100%);border:1px solid var(--border);border-radius:12px;padding:18px 20px;margin-bottom:8px;box-shadow:0 8px 24px rgba(0,0,0,.25)}
.hero-badge{display:inline-block;font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--accent);background:rgba(0,191,255,.12);border:1px solid rgba(0,191,255,.35);padding:4px 10px;border-radius:999px;margin-bottom:10px}
.hero h1{margin:0 0 6px;font-size:1.55rem;font-weight:700;color:var(--blue)}
.hero-sub{margin:0;font-size:.9rem;color:var(--muted)}
h2{color:var(--green);border-top:1px solid var(--border);padding-top:18px;margin:22px 0 12px;font-size:1.05rem;font-weight:700}
h2.no-border{border-top:none;padding-top:0;margin-top:8px}
.note{margin:0 0 14px;font-size:.88rem;color:var(--muted)}
.config-row{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:8px 10px;display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:10px;box-shadow:0 2px 8px rgba(0,0,0,.15)}
.config-label{background:var(--card2);color:var(--blue);padding:7px 12px;border-radius:8px;font-weight:700;font-size:.78rem;white-space:nowrap;min-width:148px;text-align:center;border:1px solid var(--border)}
.config-code{flex:1;min-width:0;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:nowrap;overflow-x:auto;padding:9px 10px;background:#0c0e12;border-radius:8px;color:var(--green);font-size:.74rem;border:1px solid #222831;scrollbar-width:thin;scrollbar-color:#444 transparent}
.config-code::-webkit-scrollbar{height:6px}
.config-code::-webkit-scrollbar-thumb{background:#444;border-radius:3px}
.config-code.multiline{max-height:72px;white-space:pre-wrap;word-break:break-all;overflow-y:auto}
.btn-action{border:1px solid var(--border);padding:6px 12px;border-radius:8px;cursor:pointer;font-weight:700;font-size:.78rem;transition:all .18s;height:34px;display:flex;align-items:center;justify-content:center;white-space:nowrap}
.copy-btn{background:#252a34;color:var(--text);min-width:64px}
.copy-btn:hover{background:var(--green);color:#121212;border-color:var(--green)}
.qr-btn{background:#252a34;color:var(--blue);border-color:rgba(130,170,255,.45);min-width:44px}
.qr-btn:hover{background:var(--blue);color:#121212}
.btn-group{display:flex;flex-wrap:wrap;gap:10px;margin:10px 0 18px}
.btn{flex:1;min-width:140px;background:var(--card2);color:var(--green);border:1px solid var(--green);padding:11px 14px;text-align:center;border-radius:10px;text-decoration:none;font-weight:700;font-size:.9rem;transition:all .18s}
.btn:hover{background:var(--green);color:#121212}
.btn.download{border-color:var(--blue);color:var(--blue)}
.btn.download:hover{background:var(--blue);color:#121212}
.btn.tg{border-color:#2AABEE;color:#2AABEE}
.btn.tg:hover{background:#2AABEE;color:#fff}
.footer{margin:36px 0 12px;text-align:center}
.footer a{color:var(--muted);text-decoration:none;font-size:.85rem}
.footer a:hover{color:var(--blue)}
.modal-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.88);z-index:999;justify-content:center;align-items:center;backdrop-filter:blur(4px)}
.modal-content{background:var(--card);padding:22px;border-radius:12px;border:1px solid var(--blue);text-align:center;box-shadow:0 12px 40px rgba(0,0,0,.45)}
#qrcode{background:#fff;padding:12px;border-radius:8px;margin-bottom:12px;display:inline-block}
.close-modal-btn{background:#c31e1e;color:#fff;border:none;padding:9px 22px;border-radius:8px;cursor:pointer;font-weight:700}
@media(max-width:600px){.wrap{padding:12px 10px 28px}.hero h1{font-size:1.3rem}.config-label{width:100%;margin-bottom:2px}.config-code{min-width:100%;order:3}.btn-action{flex:1;order:2}}
</style>
<script>
function copyText(e,t){navigator.clipboard.writeText(document.getElementById(e).innerText).then(()=>{let o=t.innerText;t.innerText="OK",t.style.cssText="background:#c3e88d;color:#121212",setTimeout(()=>{t.innerText=o,t.style.cssText=""},1500)}).catch(e=>console.error(e))}function showQR(e){let t=document.getElementById(e).innerText,o=document.getElementById("qrModal"),n=document.getElementById("qrcode");n.innerHTML="",new QRCode(n,{text:t,width:256,height:256,colorDark:"#000000",colorLight:"#ffffff",correctLevel:QRCode.CorrectLevel.L}),o.style.display="flex"}function closeModal(){document.getElementById("qrModal").style.display="none"}window.onclick=function(e){e.target==document.getElementById("qrModal")&&closeModal()};
</script>
</head><body><div class="wrap">
'''

HTML_FOOT = '''
<footer class="footer"><a href="https://github.com/xVRVx/autoXRAY" target="_blank" rel="noopener">github.com/xVRVx/autoXRAY</a></footer>
</div>
<div id="qrModal" class="modal-overlay"><div class="modal-content"><div id="qrcode"></div><button class="close-modal-btn" onclick="closeModal()">Close</button></div></div>
</body></html>
'''

clients_dir = os.path.join(ax_dir, "clients")
allowed = set()
with open(os.path.join(ax_dir, "clients.txt"), encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.replace("\r", "").strip()
        if not line or line.startswith("#"):
            continue
        name = line.split("#", 1)[0].strip()
        if name:
            allowed.add(name)

summary = []
for env_path in sorted(glob.glob(os.path.join(clients_dir, "*.env"))):
    c = load_env(env_path)
    cname = c.get("CLIENT_NAME", "client")
    if cname not in allowed:
        continue
    uid = c["xray_uuid_vrv"]
    subpath = c["path_subpage"]
    expected = cname.lower()
    if subpath != expected:
        print(f"WARN: {cname} path_subpage={subpath}, ожидалось {expected}")
    sub_link = f"https://{domain}/{subpath}.json"
    html_link = f"https://{domain}/{subpath}.html"

    subs = []
    for num in sorted(CONFIG_META.keys()):
        if num not in enabled:
            continue
        title, builder, _ = CONFIG_META[num]
        subs.append(print_config(json.dumps(builder(uid)), title))

    json_path = os.path.join(web_path, f"{subpath}.json")
    with open(json_path, "w") as f:
        json.dump(subs, f, indent=2)
    print(f"JSON: {json_path} ({cname})")

    links = build_links(uid, cname)
    all_links = "<br>".join(lk for _, lk in links)
    body = [HTML_HEAD,
        '<header class="hero">',
        '<span class="hero-badge">autoXRAY-multi</span>',
        f'<h1>{cname}</h1>',
        f'<p class="hero-sub">{domain} · персональные конфиги</p>',
        '</header>',
        '<h2 class="no-border">📂 Ссылка на подписку</h2>',
        '<p class="note">Готовый конфиг клиента с роутингом — добавьте в Happ или v2rayTun.</p>',
        f'<div class="config-row"><div class="config-label">Subscription</div><div class="config-code" id="subLink">{sub_link}</div>'
        '<button class="btn-action copy-btn" onclick="copyText(\'subLink\', this)">Copy</button>'
        '<button class="btn-action qr-btn" onclick="showQR(\'subLink\')">QR</button></div>',
        '<h2>📱 Приложение HAPP</h2>',
        f'<div class="btn-group"><a href="happ://add/{sub_link}" class="btn">⚡ Add to HAPP</a>'
        '<a href="https://www.happ.su/main/ru" target="_blank" class="btn download">⬇️ Download App</a></div>',
        '<p class="note">Маршрутизацию в приложении лучше выключить — здесь она уже встроена в подписку.</p>',
        '<h2>➡️ Конфиги</h2>']
    for i, (title, link) in enumerate(links, 1):
        body.append(f'<div class="config-row"><div class="config-label">{title}</div>'
            f'<div class="config-code" id="c{i}">{link}</div>'
            f'<button class="btn-action copy-btn" onclick="copyText(\'c{i}\', this)">Copy</button>'
            f'<button class="btn-action qr-btn" onclick="showQR(\'c{i}\')">QR</button></div>')
    if show_socks and socks_user and socks_pass:
        body.append(f'<div class="config-row"><div class="config-label">Socks5 (TG)</div>'
            f'<div class="config-code" id="sock">server={domain} port=10443 user={socks_user} pass={socks_pass}</div>'
            '<button class="btn-action copy-btn" onclick="copyText(\'sock\', this)">Copy</button>'
            f'<a href="https://t.me/socks?server={domain}&port=10443&user={socks_user}&pass={socks_pass}" '
            'target="_blank" class="btn-action qr-btn btn tg" title="автодобавление в тг" style="text-decoration:none">✈️ TG</a></div>')
    body.append('<h2>💠 Все конфиги вместе</h2>')
    body.append(f'<div class="config-row"><div class="config-code multiline" id="cAll">{all_links}</div>'
        '<button class="btn-action copy-btn" onclick="copyText(\'cAll\', this)">Copy ALL</button>'
        '<button class="btn-action qr-btn" onclick="showQR(\'cAll\')">QR</button></div>')
    body.append(HTML_FOOT)
    html_path = os.path.join(web_path, f"{subpath}.html")
    with open(html_path, "w") as f:
        f.write("".join(body))
    print(f"HTML: {html_path}")
    summary.append((cname, sub_link, html_link, len(subs)))

if not summary:
    raise SystemExit("Не сгенерировано ни одного клиента — проверьте clients.txt")

print("\n--- Итог генерации ---")
for cname, sub, html, ncfg in summary:
    print(f"  {cname}: {ncfg} конфиг(ов) в подписке")
    print(f"    {sub}")
    print(f"    {html}")
PYGEN

ax_cleanup_stale_web_files
ax_patch_nginx_sub_locations

if ! xray -test -config "$AX_XRAY_CFG" >/dev/null 2>&1; then
    echo -e "${RED}Ошибка: xray -test не прошёл. config.json не применён.${NC}"
    xray -test -config "$AX_XRAY_CFG" || true
    exit 1
fi
systemctl restart xray

ax_write_clients_urls
ax_print_client_summary

echo -e "${GRN}✅ update_clients завершён${NC}"
echo "Редактируйте: $AX_CLIENTS_TXT и $AX_ENABLED_CFG"
echo "Затем снова: $SCRIPT_DIR/update_clients.sh"
