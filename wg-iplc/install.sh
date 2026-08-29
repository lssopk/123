#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg-iplc"
WG_NET="10.66.66"
WG_SERVER_IP="${WG_NET}.1"
WG_CLIENT_IP="${WG_NET}.2"
WG_CIDR="${WG_NET}.0/24"
WG_DIR="/etc/wireguard"
SERVER_PRIV_FILE="${WG_DIR}/iplc-server.key"
SERVER_PUB_FILE="${WG_DIR}/iplc-server.pub"
CLIENT_PRIV_FILE="${WG_DIR}/iplc-client.key"
CLIENT_PUB_FILE="${WG_DIR}/iplc-client.pub"

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 用户运行"
    exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
    echo "错误：该脚本用于 Debian / Ubuntu"
    exit 1
fi

clear || true
echo "=============================================="
echo "        WireGuard 一键部署（常规模式）"
echo "=============================================="
echo

echo "[1/8] 安装依赖..."
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
    wireguard wireguard-tools iptables iproute2 curl ca-certificates

DEFAULT_IF=$(ip -4 route show default | awk 'NR==1 {print $5}')
if [ -z "${DEFAULT_IF}" ]; then
    echo "错误：无法识别默认 IPv4 出口网卡"
    ip -4 route
    exit 1
fi

LOCAL_IP=$(ip -o -4 addr show dev "${DEFAULT_IF}" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')
PUBLIC_IP=$(curl -4 --connect-timeout 5 --max-time 8 -fsSL https://api.ipify.org 2>/dev/null || true)
if [ -z "${PUBLIC_IP}" ]; then
    PUBLIC_IP="${LOCAL_IP}"
fi

echo
echo "检测到默认出口网卡：${DEFAULT_IF}"
echo "检测到本机地址：${LOCAL_IP:-未知}"
echo "检测到公网地址：${PUBLIC_IP:-未知}"
echo

DEFAULT_PORT="51820"
read -rp "请输入 WireGuard UDP 端口 [${DEFAULT_PORT}]: " WG_PORT
WG_PORT="${WG_PORT:-${DEFAULT_PORT}}"

if ! [[ "${WG_PORT}" =~ ^[0-9]+$ ]] || [ "${WG_PORT}" -lt 1 ] || [ "${WG_PORT}" -gt 65535 ]; then
    echo "错误：端口必须是 1-65535 的整数"
    exit 1
fi

if ss -H -lunp 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${WG_PORT}$"; then
    CURRENT_PORT=""
    if [ -f "${WG_DIR}/${WG_IF}.conf" ]; then
        CURRENT_PORT=$(awk -F= '/^[[:space:]]*ListenPort[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${WG_DIR}/${WG_IF}.conf" || true)
    fi
    if [ "${CURRENT_PORT}" != "${WG_PORT}" ]; then
        echo "错误：UDP ${WG_PORT} 已被其他程序占用"
        ss -lunp | grep -E "(^|:)${WG_PORT}[[:space:]]" || true
        exit 1
    fi
fi

read -rp "请输入客户端连接地址（公网 IP 或域名）[${PUBLIC_IP}]: " WG_ENDPOINT
WG_ENDPOINT="${WG_ENDPOINT:-${PUBLIC_IP}}"
if [ -z "${WG_ENDPOINT}" ]; then
    echo "错误：无法确定客户端连接地址"
    exit 1
fi

echo
echo "[2/8] 准备 WireGuard 密钥..."
mkdir -p "${WG_DIR}"
chmod 700 "${WG_DIR}"
umask 077

if [ ! -s "${SERVER_PRIV_FILE}" ]; then
    wg genkey > "${SERVER_PRIV_FILE}"
fi
if [ ! -s "${SERVER_PUB_FILE}" ]; then
    wg pubkey < "${SERVER_PRIV_FILE}" > "${SERVER_PUB_FILE}"
fi
if [ ! -s "${CLIENT_PRIV_FILE}" ]; then
    wg genkey > "${CLIENT_PRIV_FILE}"
fi
if [ ! -s "${CLIENT_PUB_FILE}" ]; then
    wg pubkey < "${CLIENT_PRIV_FILE}" > "${CLIENT_PUB_FILE}"
fi

SERVER_PRIV=$(cat "${SERVER_PRIV_FILE}")
SERVER_PUB=$(cat "${SERVER_PUB_FILE}")
CLIENT_PRIV=$(cat "${CLIENT_PRIV_FILE}")
CLIENT_PUB=$(cat "${CLIENT_PUB_FILE}")
chmod 600 \
    "${SERVER_PRIV_FILE}" "${SERVER_PUB_FILE}" \
    "${CLIENT_PRIV_FILE}" "${CLIENT_PUB_FILE}"

echo "[3/8] 开启 IPv4 转发..."
cat > /etc/sysctl.d/99-wg-game.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF
sysctl --system >/dev/null

echo "[4/8] 创建常规 WireGuard 服务端配置..."
if [ -f "${WG_DIR}/${WG_IF}.conf" ]; then
    cp "${WG_DIR}/${WG_IF}.conf" \
       "${WG_DIR}/${WG_IF}.conf.bak.$(date +%Y%m%d-%H%M%S)"
fi

cat > "${WG_DIR}/${WG_IF}.conf" <<EOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

PostUp = iptables -C INPUT -p udp --dport ${WG_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${WG_PORT} -j ACCEPT
PostUp = iptables -C FORWARD -i ${WG_IF} -o ${DEFAULT_IF} -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i ${WG_IF} -o ${DEFAULT_IF} -j ACCEPT
PostUp = iptables -C FORWARD -i ${DEFAULT_IF} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i ${DEFAULT_IF} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -s ${WG_CIDR} -o ${DEFAULT_IF} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${WG_CIDR} -o ${DEFAULT_IF} -j MASQUERADE

PostDown = iptables -D INPUT -p udp --dport ${WG_PORT} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${WG_IF} -o ${DEFAULT_IF} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${DEFAULT_IF} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s ${WG_CIDR} -o ${DEFAULT_IF} -j MASQUERADE 2>/dev/null || true

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${WG_CLIENT_IP}/32
EOF
chmod 600 "${WG_DIR}/${WG_IF}.conf"

echo "[5/8] 创建客户端与 OpenClash 配置..."
cat > "${WG_DIR}/iplc-client.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${WG_CLIENT_IP}/24

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${WG_ENDPOINT}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
EOF
chmod 600 "${WG_DIR}/iplc-client.conf"

cat > "${WG_DIR}/openclash-iplc.yaml" <<EOF
proxies:
  - name: "日本-WG"
    type: wireguard
    server: ${WG_ENDPOINT}
    port: ${WG_PORT}
    ip: ${WG_CLIENT_IP}
    private-key: "${CLIENT_PRIV}"
    public-key: "${SERVER_PUB}"
    allowed-ips:
      - "0.0.0.0/0"
    persistent-keepalive: 15
    udp: true
EOF
chmod 600 "${WG_DIR}/openclash-iplc.yaml"

echo "[6/8] 启动 WireGuard..."
systemctl daemon-reload
systemctl enable "wg-quick@${WG_IF}" >/dev/null
systemctl restart "wg-quick@${WG_IF}"
sleep 1

if ! systemctl is-active --quiet "wg-quick@${WG_IF}"; then
    echo "WireGuard 启动失败："
    journalctl -u "wg-quick@${WG_IF}" --no-pager -n 80
    exit 1
fi

echo "[7/8] 创建快捷管理命令 wgggg..."
cat > /usr/local/bin/wgggg <<'WGGMENU'
#!/usr/bin/env bash
WG_IF="wg-iplc"
SERVICE="wg-quick@wg-iplc"
WG_DIR="/etc/wireguard"

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then exec sudo "$0" "$@"; fi
    echo "请使用 root 用户运行 wgggg"
    exit 1
fi

pause() { echo; read -rp "按回车返回菜单..." _; }
start_wg() { systemctl start "${SERVICE}"; wg show "${WG_IF}" 2>/dev/null || true; }
stop_wg() { systemctl stop "${SERVICE}"; }
restart_wg() { systemctl restart "${SERVICE}"; wg show "${WG_IF}" 2>/dev/null || true; }
show_status() { systemctl --no-pager -l status "${SERVICE}" || true; }
show_wg() { wg show "${WG_IF}" || true; }
show_live() { echo "按 Ctrl+C 退出"; sleep 1; watch -n1 "wg show ${WG_IF}"; }
show_server() { cat "${WG_DIR}/${WG_IF}.conf"; }
show_client() { cat "${WG_DIR}/iplc-client.conf"; }
show_openclash() { cat "${WG_DIR}/openclash-iplc.yaml"; }
show_logs() { journalctl -u "${SERVICE}" -n 100 --no-pager; }
enable_wg() { systemctl enable "${SERVICE}"; }
disable_wg() { systemctl disable "${SERVICE}"; }

usage() {
    echo "wgggg start|stop|restart|status|show|live|server|client|openclash|logs|enable|disable"
}

if [ $# -gt 0 ]; then
    case "${1:-}" in
        start) start_wg ;; stop) stop_wg ;; restart) restart_wg ;;
        status) show_status ;; show) show_wg ;; live) show_live ;;
        server) show_server ;; client) show_client ;; openclash) show_openclash ;;
        logs) show_logs ;; enable) enable_wg ;; disable) disable_wg ;;
        *) usage; exit 1 ;;
    esac
    exit $?
fi

while true; do
    clear
    echo "======================================================"
    echo "             WireGuard 管理菜单"
    echo "======================================================"
    if systemctl is-active --quiet "${SERVICE}"; then
        echo "当前状态：运行中"
    else
        echo "当前状态：已停止"
    fi
    echo
    echo "  1. 启动 WireGuard"
    echo "  2. 停止 WireGuard"
    echo "  3. 重启 WireGuard"
    echo "  4. 查看服务状态"
    echo "  5. 查看 WG 握手/流量"
    echo "  6. 实时查看 WG 流量"
    echo "  7. 查看服务端配置"
    echo "  8. 查看客户端配置"
    echo "  9. 查看 OpenClash 节点"
    echo " 10. 查看日志"
    echo " 11. 开启开机自启"
    echo " 12. 关闭开机自启"
    echo "  0. 退出"
    echo
    read -rp "请选择 [0-12]: " choice
    case "${choice}" in
        1) start_wg; pause ;; 2) stop_wg; pause ;; 3) restart_wg; pause ;;
        4) show_status; pause ;; 5) show_wg; pause ;; 6) show_live ;;
        7) show_server; pause ;; 8) show_client; pause ;; 9) show_openclash; pause ;;
        10) show_logs; pause ;; 11) enable_wg; pause ;; 12) disable_wg; pause ;;
        0) exit 0 ;; *) echo "输入无效"; sleep 1 ;;
    esac
done
WGGMENU
chmod +x /usr/local/bin/wgggg

echo "[8/8] 部署完成"
echo
echo "======================================================"
echo "            WireGuard 部署成功"
echo "======================================================"
echo "监听端口：${WG_PORT}/UDP"
echo "默认出口：${DEFAULT_IF}"
echo "客户端入口：${WG_ENDPOINT}:${WG_PORT}"
echo "服务端地址：${WG_SERVER_IP}/24"
echo "客户端地址：${WG_CLIENT_IP}/24"
echo
echo "OpenClash / Mihomo 节点："
cat "${WG_DIR}/openclash-iplc.yaml"
echo
echo "管理菜单：wgggg"
echo "======================================================"
