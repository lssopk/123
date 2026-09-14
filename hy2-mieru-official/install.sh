#!/usr/bin/env bash
set -euo pipefail
umask 077

APP_NAME="hy2-mieru-dual"
STATE_DIR="/etc/${APP_NAME}"
STATE_FILE="${STATE_DIR}/state.env"
MIERU_JSON="${STATE_DIR}/mita-server.json"
OPENCLASH_YAML="${STATE_DIR}/openclash.yaml"
MENU_BIN="/usr/local/bin/proxy2"
HY2_SERVICE="hysteria-server.service"
HY2_CONFIG="/etc/hysteria/config.yaml"
MIERU_SERVICE="mita.service"
HY2_INSTALL_URL="https://get.hy2.sh/"
MIERU_REPO="enfein/mieru"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 运行。"
    exit 1
  fi
}

valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1025 ] && [ "$1" -le 65534 ]
}

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl python3 iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssl python3 iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates openssl python3 iproute
  else
    echo "错误：仅支持 Debian/Ubuntu 与 RHEL/Rocky/CentOS/Fedora 系列。"
    exit 1
  fi
}

random_password() { openssl rand -hex 16; }

public_ip() {
  local ip=""
  ip="$(curl -4 --connect-timeout 5 --max-time 8 -fsSL https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -6 --connect-timeout 5 --max-time 8 -fsSL https://api64.ipify.org 2>/dev/null || true)"
  fi
  printf '%s' "$ip"
}

yaml_sq() { printf "%s" "$1" | sed "s/'/''/g"; }

save_state() {
  mkdir -p "$STATE_DIR"
  {
    printf 'BASE_PORT=%q\n' "$BASE_PORT"
    printf 'HY2_PORT=%q\n' "$HY2_PORT"
    printf 'MIERU_PORT=%q\n' "$MIERU_PORT"
    printf 'ENDPOINT=%q\n' "$ENDPOINT"
    printf 'HY2_SNI=%q\n' "$HY2_SNI"
    printf 'HY2_CERT=%q\n' "$HY2_CERT"
    printf 'HY2_KEY=%q\n' "$HY2_KEY"
    printf 'HY2_PASSWORD=%q\n' "$HY2_PASSWORD"
    printf 'MIERU_USER=%q\n' "$MIERU_USER"
    printf 'MIERU_PASSWORD=%q\n' "$MIERU_PASSWORD"
    printf 'HY2_NODE_NAME=%q\n' "$HY2_NODE_NAME"
    printf 'MIERU_NODE_NAME=%q\n' "$MIERU_NODE_NAME"
    printf 'MIERU_MTU=%q\n' "$MIERU_MTU"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

load_state() {
  [ -f "$STATE_FILE" ] || { echo "错误：未找到 $STATE_FILE"; exit 1; }
  . "$STATE_FILE"
}

render_hy2_config() {
  load_state
  mkdir -p /etc/hysteria
  cat > "$HY2_CONFIG" <<EOF_HY2
listen: :${HY2_PORT}

tls:
  cert: '$(yaml_sq "$HY2_CERT")'
  key: '$(yaml_sq "$HY2_KEY")'

auth:
  type: password
  password: '$(yaml_sq "$HY2_PASSWORD")'

disableUDP: false
udpIdleTimeout: 60s
EOF_HY2
  chmod 600 "$HY2_CONFIG"
}

render_mieru_json() {
  load_state
  python3 - "$MIERU_JSON" "$MIERU_PORT" "$MIERU_USER" "$MIERU_PASSWORD" "$MIERU_MTU" <<'PY_JSON'
import json, sys
path, port, user, password, mtu = sys.argv[1:]
data = {
    "portBindings": [{"port": int(port), "protocol": "UDP"}],
    "users": [{"name": user, "password": password}],
    "loggingLevel": "INFO",
    "mtu": int(mtu),
    "dns": {"dualStack": "PREFER_IPv4"},
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY_JSON
  chmod 600 "$MIERU_JSON"
}

render_openclash() {
  load_state
  cat > "$OPENCLASH_YAML" <<EOF_OC
proxies:
  - name: '$(yaml_sq "$HY2_NODE_NAME")'
    type: hysteria2
    server: '$(yaml_sq "$ENDPOINT")'
    port: ${HY2_PORT}
    password: '$(yaml_sq "$HY2_PASSWORD")'
    udp: true
    sni: '$(yaml_sq "$HY2_SNI")'
    skip-cert-verify: false

  - name: '$(yaml_sq "$MIERU_NODE_NAME")'
    type: mieru
    server: '$(yaml_sq "$ENDPOINT")'
    port: ${MIERU_PORT}
    transport: UDP
    username: '$(yaml_sq "$MIERU_USER")'
    password: '$(yaml_sq "$MIERU_PASSWORD")'
    udp: true
    multiplexing: MULTIPLEXING_OFF
    handshake-mode: HANDSHAKE_NO_WAIT
EOF_OC
  chmod 600 "$OPENCLASH_YAML"
}

install_hy2() {
  echo "==> 安装/升级官方 Hysteria2..."
  HYSTERIA_USER=root bash <(curl -fsSL "$HY2_INSTALL_URL")
  render_hy2_config
  systemctl daemon-reload
  systemctl enable "$HY2_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$HY2_SERVICE"
}

latest_mieru_version() {
  curl -fsSL "https://api.github.com/repos/${MIERU_REPO}/releases/latest" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))'
}

install_mieru() {
  echo "==> 安装/升级官方 Mieru/Mita..."
  local ver arch pkg url tmp

  if [ -x /usr/local/bin/install-mita ] || [ -e /var/lib/mita-oneclick/.installed ]; then
    echo "检测到旧的 mieru-OneClick 管理层，正在清理后切换为官方 Mita..."
    if [ -x /usr/local/bin/install-mita ]; then
      /usr/local/bin/install-mita --uninstall -y || true
    fi
    rm -f /usr/local/bin/mita /usr/local/bin/mita-real /usr/local/bin/mita-menu /usr/local/bin/install-mita
    rm -f /etc/profile.d/mita-oneclick.sh
    systemctl daemon-reload || true
  fi

  ver="$(latest_mieru_version)"
  arch="$(uname -m)"
  tmp="$(mktemp -d)"

  if command -v dpkg >/dev/null 2>&1; then
    case "$arch" in
      x86_64|amd64) pkg="mita_${ver}_amd64.deb" ;;
      aarch64|arm64) pkg="mita_${ver}_arm64.deb" ;;
      *) echo "错误：官方 Mita deb 包暂不支持架构 $arch"; rm -rf "$tmp"; return 1 ;;
    esac
    url="https://github.com/${MIERU_REPO}/releases/download/v${ver}/${pkg}"
    curl -fL "$url" -o "$tmp/$pkg"
    dpkg -i "$tmp/$pkg" || { apt-get -f install -y; dpkg -i "$tmp/$pkg"; }
  elif command -v rpm >/dev/null 2>&1; then
    case "$arch" in
      x86_64|amd64) pkg="mita-${ver}-1.x86_64.rpm" ;;
      aarch64|arm64) pkg="mita-${ver}-1.aarch64.rpm" ;;
      *) echo "错误：官方 Mita rpm 包暂不支持架构 $arch"; rm -rf "$tmp"; return 1 ;;
    esac
    url="https://github.com/${MIERU_REPO}/releases/download/v${ver}/${pkg}"
    curl -fL "$url" -o "$tmp/$pkg"
    rpm -Uvh --force "$tmp/$pkg"
  else
    echo "错误：未检测到 dpkg 或 rpm。"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"

  render_mieru_json
  systemctl enable --now "$MIERU_SERVICE" >/dev/null 2>&1 || true
  sleep 1
  mita apply config "$MIERU_JSON"
  mita stop >/dev/null 2>&1 || true
  mita start
}

open_firewall_best_effort() {
  load_state
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${HY2_PORT}/udp" >/dev/null || true
    ufw allow "${MIERU_PORT}/udp" >/dev/null || true
  fi
}

check_services() {
  if systemctl is-active --quiet "$HY2_SERVICE"; then echo "Hysteria2 : active"; else echo "Hysteria2 : FAILED"; fi
  if mita status 2>/dev/null | grep -qi 'RUNNING'; then echo "Mieru/Mita: RUNNING"; else echo "Mieru/Mita: NOT RUNNING"; fi
}

create_menu() {
  cat > "$MENU_BIN" <<'EOF_MENU'
#!/usr/bin/env bash
set -u
APP_NAME="hy2-mieru-dual"
STATE_DIR="/etc/${APP_NAME}"
STATE_FILE="${STATE_DIR}/state.env"
MIERU_JSON="${STATE_DIR}/mita-server.json"
OPENCLASH_YAML="${STATE_DIR}/openclash.yaml"
HY2_SERVICE="hysteria-server.service"
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_INSTALL_URL="https://get.hy2.sh/"
MIERU_REPO="enfein/mieru"

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then exec sudo "$0" "$@"; fi
  echo "请使用 root 运行 proxy2"; exit 1
fi
load_state(){ [ -f "$STATE_FILE" ] || { echo "缺少 $STATE_FILE"; exit 1; }; . "$STATE_FILE"; }
yaml_sq(){ printf "%s" "$1" | sed "s/'/''/g"; }
save_state(){
  mkdir -p "$STATE_DIR"; umask 077
  {
    printf 'BASE_PORT=%q\n' "$BASE_PORT"; printf 'HY2_PORT=%q\n' "$HY2_PORT"; printf 'MIERU_PORT=%q\n' "$MIERU_PORT"
    printf 'ENDPOINT=%q\n' "$ENDPOINT"; printf 'HY2_SNI=%q\n' "$HY2_SNI"; printf 'HY2_CERT=%q\n' "$HY2_CERT"; printf 'HY2_KEY=%q\n' "$HY2_KEY"
    printf 'HY2_PASSWORD=%q\n' "$HY2_PASSWORD"; printf 'MIERU_USER=%q\n' "$MIERU_USER"; printf 'MIERU_PASSWORD=%q\n' "$MIERU_PASSWORD"
    printf 'HY2_NODE_NAME=%q\n' "$HY2_NODE_NAME"; printf 'MIERU_NODE_NAME=%q\n' "$MIERU_NODE_NAME"; printf 'MIERU_MTU=%q\n' "$MIERU_MTU"
  } > "$STATE_FILE"; chmod 600 "$STATE_FILE"
}
render_hy2(){
  load_state
  cat > "$HY2_CONFIG" <<EOF_H
listen: :${HY2_PORT}

tls:
  cert: '$(yaml_sq "$HY2_CERT")'
  key: '$(yaml_sq "$HY2_KEY")'

auth:
  type: password
  password: '$(yaml_sq "$HY2_PASSWORD")'

disableUDP: false
udpIdleTimeout: 60s
EOF_H
  chmod 600 "$HY2_CONFIG"
}
render_mieru(){
  load_state
  python3 - "$MIERU_JSON" "$MIERU_PORT" "$MIERU_USER" "$MIERU_PASSWORD" "$MIERU_MTU" <<'PY_J'
import json,sys
p,port,user,pw,mtu=sys.argv[1:]
with open(p,'w',encoding='utf-8') as f:
    json.dump({'portBindings':[{'port':int(port),'protocol':'UDP'}],'users':[{'name':user,'password':pw}],'loggingLevel':'INFO','mtu':int(mtu),'dns':{'dualStack':'PREFER_IPv4'}},f,ensure_ascii=False,indent=2)
    f.write('\n')
PY_J
  chmod 600 "$MIERU_JSON"
}
render_openclash(){
  load_state
  cat > "$OPENCLASH_YAML" <<EOF_O
proxies:
  - name: '$(yaml_sq "$HY2_NODE_NAME")'
    type: hysteria2
    server: '$(yaml_sq "$ENDPOINT")'
    port: ${HY2_PORT}
    password: '$(yaml_sq "$HY2_PASSWORD")'
    udp: true
    sni: '$(yaml_sq "$HY2_SNI")'
    skip-cert-verify: false

  - name: '$(yaml_sq "$MIERU_NODE_NAME")'
    type: mieru
    server: '$(yaml_sq "$ENDPOINT")'
    port: ${MIERU_PORT}
    transport: UDP
    username: '$(yaml_sq "$MIERU_USER")'
    password: '$(yaml_sq "$MIERU_PASSWORD")'
    udp: true
    multiplexing: MULTIPLEXING_OFF
    handshake-mode: HANDSHAKE_NO_WAIT
EOF_O
  chmod 600 "$OPENCLASH_YAML"
}
apply_all(){ render_hy2; render_mieru; render_openclash; systemctl restart "$HY2_SERVICE"; mita apply config "$MIERU_JSON"; mita stop >/dev/null 2>&1 || true; mita start; }
start_all(){ systemctl start "$HY2_SERVICE"; systemctl start mita.service >/dev/null 2>&1 || true; mita start >/dev/null 2>&1 || true; }
stop_all(){ systemctl stop "$HY2_SERVICE"; mita stop >/dev/null 2>&1 || true; }
restart_all(){ systemctl restart "$HY2_SERVICE"; mita stop >/dev/null 2>&1 || true; mita start; }
show_status(){ load_state; echo "HY2  : ${ENDPOINT}:${HY2_PORT}/UDP"; echo "Mieru: ${ENDPOINT}:${MIERU_PORT}/UDP"; echo; systemctl --no-pager -l status "$HY2_SERVICE" 2>/dev/null | sed -n '1,8p' || true; echo; mita status 2>/dev/null || true; }
show_nodes(){ render_openclash; cat "$OPENCLASH_YAML"; }
show_logs(){ echo "===== Hysteria2 ====="; journalctl -u "$HY2_SERVICE" -n 50 --no-pager || true; echo; echo "===== Mita ====="; journalctl -u mita.service -n 50 --no-pager || true; }
change_ports(){
  load_state; local p
  while true; do read -rp "新的基础端口（HY2；Mieru 自动 +1）[$BASE_PORT]: " p; p="${p:-$BASE_PORT}"; [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1025 ] && [ "$p" -le 65534 ] && break; echo "请输入 1025-65534。"; done
  BASE_PORT="$p"; HY2_PORT="$p"; MIERU_PORT=$((p+1)); save_state; apply_all; echo "已改为 HY2=${HY2_PORT}, Mieru=${MIERU_PORT}"
}
change_auth(){ load_state; local v; read -rp "HY2 新密码（回车随机）: " v; HY2_PASSWORD="${v:-$(openssl rand -hex 16)}"; read -rp "Mieru 用户名 [$MIERU_USER]: " v; MIERU_USER="${v:-$MIERU_USER}"; read -rp "Mieru 新密码（回车随机）: " v; MIERU_PASSWORD="${v:-$(openssl rand -hex 16)}"; save_state; apply_all; }
upgrade_hy2(){ HYSTERIA_USER=root bash <(curl -fsSL "$HY2_INSTALL_URL"); render_hy2; systemctl restart "$HY2_SERVICE"; }
upgrade_mieru(){
  local ver arch pkg url tmp
  ver="$(curl -fsSL "https://api.github.com/repos/${MIERU_REPO}/releases/latest" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')"; arch="$(uname -m)"; tmp="$(mktemp -d)"
  if command -v dpkg >/dev/null 2>&1; then case "$arch" in x86_64|amd64) pkg="mita_${ver}_amd64.deb";; aarch64|arm64) pkg="mita_${ver}_arm64.deb";; *) echo "不支持 $arch"; rm -rf "$tmp"; return 1;; esac; url="https://github.com/${MIERU_REPO}/releases/download/v${ver}/${pkg}"; curl -fL "$url" -o "$tmp/$pkg"; dpkg -i "$tmp/$pkg" || { apt-get -f install -y; dpkg -i "$tmp/$pkg"; }
  else case "$arch" in x86_64|amd64) pkg="mita-${ver}-1.x86_64.rpm";; aarch64|arm64) pkg="mita-${ver}-1.aarch64.rpm";; *) echo "不支持 $arch"; rm -rf "$tmp"; return 1;; esac; url="https://github.com/${MIERU_REPO}/releases/download/v${ver}/${pkg}"; curl -fL "$url" -o "$tmp/$pkg"; rpm -Uvh --force "$tmp/$pkg"; fi
  rm -rf "$tmp"; render_mieru; mita apply config "$MIERU_JSON"; mita stop >/dev/null 2>&1 || true; mita start
}
uninstall_all(){ read -rp "确认卸载 HY2 + Mieru？输入 YES: " v; [ "$v" = YES ] || return 0; systemctl stop "$HY2_SERVICE" 2>/dev/null || true; mita stop >/dev/null 2>&1 || true; bash <(curl -fsSL "$HY2_INSTALL_URL") --remove || true; if command -v apt-get >/dev/null 2>&1; then apt-get remove -y mita || true; elif command -v dnf >/dev/null 2>&1; then dnf remove -y mita || true; elif command -v yum >/dev/null 2>&1; then yum remove -y mita || true; elif command -v rpm >/dev/null 2>&1; then rpm -e mita || true; fi; rm -rf "$STATE_DIR"; rm -f /usr/local/bin/proxy2; echo "卸载完成。"; exit 0; }
pause(){ echo; read -rp "按回车继续..." _; }
usage(){ echo "proxy2 [start|stop|restart|status|nodes|logs|ports|auth|upgrade|uninstall]"; }
if [ $# -gt 0 ]; then case "$1" in start) start_all;; stop) stop_all;; restart) restart_all;; status) show_status;; nodes|client) show_nodes;; logs) show_logs;; ports) change_ports;; auth) change_auth;; upgrade) upgrade_hy2; upgrade_mieru;; uninstall) uninstall_all;; *) usage; exit 1;; esac; exit $?; fi
while true; do
  clear || true; echo "=================================================="; echo "       官方 HY2 + Mieru/Mita 管理菜单"; echo "=================================================="; load_state; echo "HY2   : ${HY2_PORT}/UDP"; echo "Mieru : ${MIERU_PORT}/UDP"; echo
  echo " 1. 启动两个代理"; echo " 2. 停止两个代理"; echo " 3. 重启两个代理"; echo " 4. 查看状态"; echo " 5. 输出 OpenClash 两个节点"; echo " 6. 查看日志"; echo " 7. 修改基础端口（Mieru 自动 +1）"; echo " 8. 修改密码/用户名"; echo " 9. 升级两个官方核心"; echo "10. 卸载两个代理"; echo " 0. 退出"
  read -rp "请选择 [0-10]: " c
  case "$c" in 1) start_all; pause;; 2) stop_all; pause;; 3) restart_all; pause;; 4) show_status; pause;; 5) show_nodes; pause;; 6) show_logs; pause;; 7) change_ports; pause;; 8) change_auth; pause;; 9) upgrade_hy2; upgrade_mieru; pause;; 10) uninstall_all;; 0) exit 0;; *) sleep 1;; esac
done
EOF_MENU
  chmod +x "$MENU_BIN"
}

main() {
  need_root
  echo "======================================================"
  echo "      官方 Hysteria2 + Mieru/Mita 一键安装"
  echo "======================================================"
  echo "规则：HY2 使用基础端口；Mieru 自动使用 基础端口+1。"
  echo
  install_deps

  local p ip
  while true; do
    read -rp "请输入基础端口（HY2）[18611]: " p
    p="${p:-18611}"
    valid_port "$p" && break
    echo "请输入 1025-65534。"
  done
  BASE_PORT="$p"; HY2_PORT="$BASE_PORT"; MIERU_PORT=$((BASE_PORT + 1))

  ip="$(public_ip)"
  read -rp "请输入客户端连接 IP/域名 [${ip:-服务器公网IP}]: " ENDPOINT
  ENDPOINT="${ENDPOINT:-$ip}"
  [ -n "$ENDPOINT" ] || { echo "错误：无法自动获取公网 IP，请手动输入。"; exit 1; }

  read -rp "请输入 HY2 TLS SNI [no.s13.cc]: " HY2_SNI
  HY2_SNI="${HY2_SNI:-no.s13.cc}"
  while true; do read -rp "HY2 证书路径 [/usr/local/etc/xray/certs/_.s13.cc.pem]: " HY2_CERT; HY2_CERT="${HY2_CERT:-/usr/local/etc/xray/certs/_.s13.cc.pem}"; [ -f "$HY2_CERT" ] && break; echo "文件不存在：$HY2_CERT"; done
  while true; do read -rp "HY2 私钥路径 [/usr/local/etc/xray/certs/_.s13.cc.key]: " HY2_KEY; HY2_KEY="${HY2_KEY:-/usr/local/etc/xray/certs/_.s13.cc.key}"; [ -f "$HY2_KEY" ] && break; echo "文件不存在：$HY2_KEY"; done

  read -rp "HY2 密码（回车随机生成）: " HY2_PASSWORD; HY2_PASSWORD="${HY2_PASSWORD:-$(random_password)}"
  read -rp "Mieru 用户名 [user]: " MIERU_USER; MIERU_USER="${MIERU_USER:-user}"
  read -rp "Mieru 密码（回车随机生成）: " MIERU_PASSWORD; MIERU_PASSWORD="${MIERU_PASSWORD:-$(random_password)}"
  read -rp "HY2 节点名称 [Nobrand-官方HY2]: " HY2_NODE_NAME; HY2_NODE_NAME="${HY2_NODE_NAME:-Nobrand-官方HY2}"
  read -rp "Mieru 节点名称 [Nobrand-官方Mieru]: " MIERU_NODE_NAME; MIERU_NODE_NAME="${MIERU_NODE_NAME:-Nobrand-官方Mieru}"
  MIERU_MTU=1400

  echo; echo "将使用："; echo "  HY2   : ${HY2_PORT}/UDP"; echo "  Mieru : ${MIERU_PORT}/UDP"; echo
  save_state
  install_hy2
  install_mieru
  render_openclash
  open_firewall_best_effort
  create_menu

  echo; echo "======================================================"; echo "安装完成"; echo "======================================================"
  check_services; echo; echo "快捷菜单：proxy2"; echo "查看 OpenClash 节点：proxy2 nodes"; echo "配置文件：$OPENCLASH_YAML"; echo; cat "$OPENCLASH_YAML"
}

main "$@"
