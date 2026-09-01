#!/usr/bin/env bash
set -euo pipefail

SERVICE="hysteria-server.service"
CONF_DIR="/etc/hysteria"
CONF_FILE="${CONF_DIR}/config.yaml"
STATE_FILE="${CONF_DIR}/manager.conf"
CLIENT_FILE="${CONF_DIR}/openclash-node.yaml"
MENU_BIN="/usr/local/bin/hy2"
OFFICIAL_INSTALL="https://get.hy2.sh/"

if [ "$(id -u)" -ne 0 ]; then
  echo "错误：请使用 root 用户运行"
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "错误：当前系统未使用 systemd，官方安装脚本不支持此环境。"
  exit 1
fi

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssl iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates openssl iproute
  else
    echo "错误：无法识别包管理器，请先安装 curl、openssl、ca-certificates、iproute2。"
    exit 1
  fi
}

valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

prompt_port() {
  local v
  while true; do
    read -rp "请输入 HY2 UDP 端口 [18611]: " v
    v="${v:-18611}"
    if valid_port "$v"; then
      HY2_PORT="$v"
      return
    fi
    echo "端口必须是 1-65535 的整数。"
  done
}

prompt_existing_file() {
  local prompt="$1" default="$2" outvar="$3" v
  while true; do
    read -rp "${prompt} [${default}]: " v
    v="${v:-$default}"
    if [ -f "$v" ]; then
      printf -v "$outvar" '%s' "$v"
      return
    fi
    echo "文件不存在：$v"
  done
}

random_password() {
  openssl rand -hex 16
}

save_state() {
  mkdir -p "$CONF_DIR"
  umask 077
  {
    printf 'HY2_PORT=%q\n' "$HY2_PORT"
    printf 'HY2_ENDPOINT=%q\n' "$HY2_ENDPOINT"
    printf 'HY2_SNI=%q\n' "$HY2_SNI"
    printf 'HY2_CERT=%q\n' "$HY2_CERT"
    printf 'HY2_KEY=%q\n' "$HY2_KEY"
    printf 'HY2_PASSWORD=%q\n' "$HY2_PASSWORD"
    printf 'HY2_NAME=%q\n' "$HY2_NAME"
    printf 'HY2_UDP_IDLE=%q\n' "$HY2_UDP_IDLE"
    printf 'HY2_DISABLE_PMTU=%q\n' "$HY2_DISABLE_PMTU"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

clear || true
echo "======================================================"
echo "        官方 Hysteria2 一键安装 / 管理脚本"
echo "======================================================"
echo

echo "[1/7] 安装基础依赖..."
install_deps

PUBLIC_IP="$(curl -4 --connect-timeout 5 --max-time 8 -fsSL https://api.ipify.org 2>/dev/null || true)"
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="$(curl -6 --connect-timeout 5 --max-time 8 -fsSL https://api64.ipify.org 2>/dev/null || true)"
fi
PUBLIC_IP="${PUBLIC_IP:-服务器IP或域名}"

prompt_port
read -rp "请输入 OpenClash 连接地址（公网 IP / 域名）[${PUBLIC_IP}]: " HY2_ENDPOINT
HY2_ENDPOINT="${HY2_ENDPOINT:-$PUBLIC_IP}"

read -rp "请输入 TLS SNI [no.s13.cc]: " HY2_SNI
HY2_SNI="${HY2_SNI:-no.s13.cc}"

prompt_existing_file "请输入证书文件路径" "/usr/local/etc/xray/certs/_.s13.cc.pem" HY2_CERT
prompt_existing_file "请输入私钥文件路径" "/usr/local/etc/xray/certs/_.s13.cc.key" HY2_KEY

DEFAULT_PASS="$(random_password)"
read -rp "请输入 HY2 密码（直接回车随机生成）: " HY2_PASSWORD
HY2_PASSWORD="${HY2_PASSWORD:-$DEFAULT_PASS}"

read -rp "请输入 OpenClash 节点名称 [Nobrand日本官方HY2]: " HY2_NAME
HY2_NAME="${HY2_NAME:-Nobrand日本官方HY2}"

HY2_UDP_IDLE="60s"
HY2_DISABLE_PMTU="false"

if command -v ss >/dev/null 2>&1 && ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${HY2_PORT}$"; then
  echo
  echo "警告：UDP ${HY2_PORT} 当前已被占用。"
  ss -lunp 2>/dev/null | grep -E "(^|:)${HY2_PORT}[[:space:]]" || true
  read -rp "仍然继续安装吗？[y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || exit 1
fi

echo
echo "[2/7] 使用官方 get.hy2.sh 安装/升级 Hysteria2..."
HYSTERIA_USER=root bash <(curl -fsSL "$OFFICIAL_INSTALL")

echo "[3/7] 保存管理配置..."
mkdir -p "$CONF_DIR"
if [ -f "$CONF_FILE" ]; then
  cp -a "$CONF_FILE" "${CONF_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
fi
save_state

echo "[4/7] 创建 hy2 快捷管理命令..."
cat > "$MENU_BIN" <<'MENU'
#!/usr/bin/env bash
set -u

SERVICE="hysteria-server.service"
CONF_DIR="/etc/hysteria"
CONF_FILE="${CONF_DIR}/config.yaml"
STATE_FILE="${CONF_DIR}/manager.conf"
CLIENT_FILE="${CONF_DIR}/openclash-node.yaml"
OFFICIAL_INSTALL="https://get.hy2.sh/"

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo "$0" "$@"
  fi
  echo "请使用 root 用户运行 hy2"
  exit 1
fi

load_state() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "错误：找不到 $STATE_FILE，请重新运行安装脚本。"
    exit 1
  fi
  . "$STATE_FILE"
}

save_state() {
  umask 077
  {
    printf 'HY2_PORT=%q\n' "$HY2_PORT"
    printf 'HY2_ENDPOINT=%q\n' "$HY2_ENDPOINT"
    printf 'HY2_SNI=%q\n' "$HY2_SNI"
    printf 'HY2_CERT=%q\n' "$HY2_CERT"
    printf 'HY2_KEY=%q\n' "$HY2_KEY"
    printf 'HY2_PASSWORD=%q\n' "$HY2_PASSWORD"
    printf 'HY2_NAME=%q\n' "$HY2_NAME"
    printf 'HY2_UDP_IDLE=%q\n' "$HY2_UDP_IDLE"
    printf 'HY2_DISABLE_PMTU=%q\n' "$HY2_DISABLE_PMTU"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

yaml_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

cert_fingerprint() {
  if command -v openssl >/dev/null 2>&1 && [ -f "$HY2_CERT" ]; then
    openssl x509 -noout -fingerprint -sha256 -in "$HY2_CERT" 2>/dev/null \
      | awk -F= 'NF>1 {print $2}' | tr -d ':' | tr 'A-F' 'a-f'
  fi
}

render_files() {
  load_state
  local qcert qkey qpass qendpoint qsni qname fp
  qcert="$(yaml_escape "$HY2_CERT")"
  qkey="$(yaml_escape "$HY2_KEY")"
  qpass="$(yaml_escape "$HY2_PASSWORD")"
  qendpoint="$(yaml_escape "$HY2_ENDPOINT")"
  qsni="$(yaml_escape "$HY2_SNI")"
  qname="$(yaml_escape "$HY2_NAME")"

  cat > "$CONF_FILE" <<EOF
listen: :${HY2_PORT}

tls:
  cert: '${qcert}'
  key: '${qkey}'

auth:
  type: password
  password: '${qpass}'

disableUDP: false
udpIdleTimeout: ${HY2_UDP_IDLE}

quic:
  disablePathMTUDiscovery: ${HY2_DISABLE_PMTU}
EOF
  chmod 600 "$CONF_FILE"

  fp="$(cert_fingerprint || true)"
  cat > "$CLIENT_FILE" <<EOF
proxies:
  - name: '${qname}'
    type: hysteria2
    server: '${qendpoint}'
    port: ${HY2_PORT}
    password: '${qpass}'
    udp: true
    sni: '${qsni}'
    skip-cert-verify: false
EOF
  if [ -n "$fp" ]; then
    printf "    fingerprint: '%s'\n" "$fp" >> "$CLIENT_FILE"
  fi
  cat >> "$CLIENT_FILE" <<'EOF'
    alpn:
      - h3
EOF
  chmod 600 "$CLIENT_FILE"
}

restart_service() {
  render_files
  systemctl daemon-reload
  systemctl restart "$SERVICE"
  sleep 1
  if systemctl is-active --quiet "$SERVICE"; then
    echo "HY2 已重启，状态：运行中"
  else
    echo "HY2 启动失败，最近日志："
    journalctl -u "$SERVICE" -n 80 --no-pager || true
    return 1
  fi
}

pause() { echo; read -rp "按回车返回菜单..." _; }

show_info() {
  load_state
  local fp
  fp="$(cert_fingerprint || true)"
  echo "端口          : $HY2_PORT/UDP"
  echo "连接地址      : $HY2_ENDPOINT"
  echo "SNI           : $HY2_SNI"
  echo "证书          : $HY2_CERT"
  echo "私钥          : $HY2_KEY"
  echo "UDP idle      : $HY2_UDP_IDLE"
  echo "禁用 PMTU 探测: $HY2_DISABLE_PMTU"
  echo "证书 SHA256   : ${fp:-无法读取}"
  if command -v hysteria >/dev/null 2>&1; then
    echo "Hysteria 版本 : $(hysteria version 2>/dev/null | head -n1 || true)"
  fi
}

reconfigure() {
  load_state
  local v
  echo "直接回车保留当前值。"

  while true; do
    read -rp "UDP 端口 [$HY2_PORT]: " v
    v="${v:-$HY2_PORT}"
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ]; then
      HY2_PORT="$v"; break
    fi
    echo "端口无效。"
  done

  read -rp "连接地址 [$HY2_ENDPOINT]: " v; HY2_ENDPOINT="${v:-$HY2_ENDPOINT}"
  read -rp "SNI [$HY2_SNI]: " v; HY2_SNI="${v:-$HY2_SNI}"

  while true; do
    read -rp "证书路径 [$HY2_CERT]: " v; v="${v:-$HY2_CERT}"
    [ -f "$v" ] && { HY2_CERT="$v"; break; }
    echo "文件不存在：$v"
  done
  while true; do
    read -rp "私钥路径 [$HY2_KEY]: " v; v="${v:-$HY2_KEY}"
    [ -f "$v" ] && { HY2_KEY="$v"; break; }
    echo "文件不存在：$v"
  done

  read -rp "节点名称 [$HY2_NAME]: " v; HY2_NAME="${v:-$HY2_NAME}"
  read -rp "UDP idle timeout [$HY2_UDP_IDLE]: " v; HY2_UDP_IDLE="${v:-$HY2_UDP_IDLE}"

  echo "PMTU 探测当前：$([ "$HY2_DISABLE_PMTU" = true ] && echo '关闭' || echo '开启')"
  read -rp "是否禁用 QUIC Path MTU Discovery？[y/N]: " v
  if [[ "$v" =~ ^[Yy]$ ]]; then HY2_DISABLE_PMTU="true"; else HY2_DISABLE_PMTU="false"; fi

  read -rp "是否修改密码？[y/N]: " v
  if [[ "$v" =~ ^[Yy]$ ]]; then
    read -rp "新密码（回车随机生成）: " v
    HY2_PASSWORD="${v:-$(openssl rand -hex 16)}"
  fi

  save_state
  restart_service
}

toggle_pmtu() {
  load_state
  if [ "$HY2_DISABLE_PMTU" = "true" ]; then
    HY2_DISABLE_PMTU="false"
    echo "已设置：开启 QUIC Path MTU Discovery"
  else
    HY2_DISABLE_PMTU="true"
    echo "已设置：关闭 QUIC Path MTU Discovery"
  fi
  save_state
  restart_service
}

change_password() {
  load_state
  local v
  read -rp "请输入新密码（回车随机生成）: " v
  HY2_PASSWORD="${v:-$(openssl rand -hex 16)}"
  save_state
  restart_service
  echo
  echo "OpenClash 节点已同步更新：$CLIENT_FILE"
}

upgrade_hy2() {
  echo "正在使用官方脚本升级 Hysteria2..."
  HYSTERIA_USER=root bash <(curl -fsSL "$OFFICIAL_INSTALL")
  render_files
  systemctl restart "$SERVICE"
  echo "升级完成。"
  hysteria version 2>/dev/null || true
}

check_port() {
  load_state
  echo "监听检查：UDP $HY2_PORT"
  if command -v ss >/dev/null 2>&1; then
    ss -lunp | grep -E "(^|:)${HY2_PORT}[[:space:]]" || echo "未发现监听"
  else
    echo "系统没有 ss 命令"
  fi
}

show_client() {
  render_files
  cat "$CLIENT_FILE"
}

show_config() {
  render_files
  cat "$CONF_FILE"
}

uninstall_hy2() {
  echo "这会卸载官方 Hysteria2，并删除本脚本创建的管理文件。"
  read -rp "确认卸载？请输入 YES: " v
  [ "$v" = "YES" ] || { echo "已取消"; return; }
  systemctl stop "$SERVICE" 2>/dev/null || true
  bash <(curl -fsSL "$OFFICIAL_INSTALL") --remove || true
  rm -f "/usr/local/bin/hy2" "$STATE_FILE" "$CLIENT_FILE"
  echo "已卸载。配置目录中的备份文件不会自动删除。"
  exit 0
}

usage() {
  cat <<EOF
用法：
  hy2                打开管理菜单
  hy2 start          启动
  hy2 stop           停止
  hy2 restart        重启
  hy2 status         状态
  hy2 logs           最近日志
  hy2 follow         实时日志
  hy2 info           当前参数
  hy2 config         查看服务端配置
  hy2 client         查看 OpenClash 节点
  hy2 reconfig       重新配置
  hy2 pmtu           切换 Path MTU Discovery
  hy2 passwd         修改密码
  hy2 upgrade        升级官方 Hysteria2
  hy2 check          检查 UDP 监听
  hy2 enable         开机自启
  hy2 disable        关闭开机自启
EOF
}

if [ $# -gt 0 ]; then
  case "$1" in
    start) systemctl start "$SERVICE" ;;
    stop) systemctl stop "$SERVICE" ;;
    restart) restart_service ;;
    status) systemctl --no-pager -l status "$SERVICE" || true ;;
    logs) journalctl -u "$SERVICE" -n 100 --no-pager ;;
    follow) journalctl -fu "$SERVICE" ;;
    info) show_info ;;
    config) show_config ;;
    client) show_client ;;
    reconfig) reconfigure ;;
    pmtu) toggle_pmtu ;;
    passwd) change_password ;;
    upgrade) upgrade_hy2 ;;
    check) check_port ;;
    enable) systemctl enable "$SERVICE" ;;
    disable) systemctl disable "$SERVICE" ;;
    *) usage; exit 1 ;;
  esac
  exit $?
fi

while true; do
  clear || true
  echo "======================================================"
  echo "             官方 Hysteria2 管理菜单"
  echo "======================================================"
  if systemctl is-active --quiet "$SERVICE"; then
    echo "当前状态：运行中"
  else
    echo "当前状态：已停止"
  fi
  echo
  echo "  1. 启动 HY2"
  echo "  2. 停止 HY2"
  echo "  3. 重启 HY2"
  echo "  4. 查看服务状态"
  echo "  5. 查看最近日志"
  echo "  6. 实时查看日志"
  echo "  7. 查看当前参数"
  echo "  8. 查看服务端配置"
  echo "  9. 查看 OpenClash 节点配置"
  echo " 10. 重新配置端口 / SNI / 证书等"
  echo " 11. 修改认证密码"
  echo " 12. 切换 QUIC Path MTU Discovery"
  echo " 13. 检查 UDP 监听"
  echo " 14. 升级官方 Hysteria2"
  echo " 15. 开启开机自启"
  echo " 16. 关闭开机自启"
  echo " 17. 卸载 Hysteria2"
  echo "  0. 退出"
  echo
  read -rp "请选择 [0-17]: " choice
  case "$choice" in
    1) systemctl start "$SERVICE"; pause ;;
    2) systemctl stop "$SERVICE"; pause ;;
    3) restart_service; pause ;;
    4) systemctl --no-pager -l status "$SERVICE" || true; pause ;;
    5) journalctl -u "$SERVICE" -n 100 --no-pager; pause ;;
    6) journalctl -fu "$SERVICE" ;;
    7) show_info; pause ;;
    8) show_config; pause ;;
    9) show_client; pause ;;
    10) reconfigure; pause ;;
    11) change_password; pause ;;
    12) toggle_pmtu; pause ;;
    13) check_port; pause ;;
    14) upgrade_hy2; pause ;;
    15) systemctl enable "$SERVICE"; pause ;;
    16) systemctl disable "$SERVICE"; pause ;;
    17) uninstall_hy2 ;;
    0) exit 0 ;;
    *) echo "输入无效"; sleep 1 ;;
  esac
done
MENU
chmod +x "$MENU_BIN"

echo "[5/7] 生成官方 HY2 与 OpenClash 配置..."
"$MENU_BIN" restart || true

echo "[6/7] 设置开机自启..."
systemctl enable "$SERVICE" >/dev/null 2>&1 || true

if ! systemctl is-active --quiet "$SERVICE"; then
  echo
  echo "HY2 未成功启动，最近日志："
  journalctl -u "$SERVICE" -n 100 --no-pager || true
  exit 1
fi

echo "[7/7] 安装完成"
echo
echo "======================================================"
echo "官方 Hysteria2 已安装并运行"
echo "======================================================"
echo "UDP 端口：$HY2_PORT"
echo "连接地址：$HY2_ENDPOINT"
echo "SNI     ：$HY2_SNI"
echo "快捷菜单：hy2"
echo "OpenClash 节点：$CLIENT_FILE"
echo
echo "查看 OpenClash 节点："
echo "  hy2 client"
echo
echo "打开快捷菜单："
echo "  hy2"
echo
"$MENU_BIN" client
