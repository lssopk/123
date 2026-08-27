bash <<'EOF'
set -euo pipefail

# =========================================================
# 沪日 IPLC WireGuard 游戏专线一键部署
#
# 日本公网 IP:       87.86.22.157
# 日本公网网关:      87.86.22.1
#
# 专线内网 IP:       172.16.4.48
# 移动专线入口:      211.136.162.188
#
# 专线端口范围:      4800-4899
# SSH:               4800
# =========================================================

JP_IP="87.86.22.157"
JP_GW="87.86.22.1"

IPLC_IP="172.16.4.48"
IPLC_MOBILE_ENTRY="211.136.162.188"
IPLC_EXTERNAL_IP="114.111.176.56"

WG_IF="wg-iplc"
WG_PORT="4888"

WG_NET="10.66.66"
WG_SERVER_IP="${WG_NET}.1"
WG_CLIENT_IP="${WG_NET}.2"
WG_CIDR="${WG_NET}.0/24"

WG_MTU="1380"

ROUTE_TABLE="51888"
ROUTE_PRIORITY="11088"

WG_DIR="/etc/wireguard"
SERVER_PRIV_FILE="${WG_DIR}/iplc-server.key"
SERVER_PUB_FILE="${WG_DIR}/iplc-server.pub"
CLIENT_PRIV_FILE="${WG_DIR}/iplc-client.key"
CLIENT_PUB_FILE="${WG_DIR}/iplc-client.pub"

# =========================================================
# 基础检查
# =========================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 用户运行"
    exit 1
fi

echo
echo "=============================================="
echo " 沪日 IPLC WireGuard 游戏专线"
echo "=============================================="
echo

if ! command -v apt >/dev/null 2>&1; then
    echo "错误：该脚本用于 Debian / Ubuntu"
    exit 1
fi

echo "[1/9] 安装 WireGuard..."

apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
    wireguard \
    wireguard-tools \
    iptables \
    iproute2 \
    curl

# =========================================================
# 自动识别双网卡
# =========================================================

echo
echo "[2/9] 自动识别网卡..."

JP_IF=$(
    ip -o -4 addr show |
    awk -v ip="${JP_IP}" '
    {
        split($4,a,"/")
        if (a[1] == ip) {
            print $2
            exit
        }
    }'
)

IPLC_IF=$(
    ip -o -4 addr show |
    awk -v ip="${IPLC_IP}" '
    {
        split($4,a,"/")
        if (a[1] == ip) {
            print $2
            exit
        }
    }'
)

if [ -z "${JP_IF}" ]; then
    echo "错误：没有找到日本公网 IP ${JP_IP} 所在网卡"
    echo
    ip -br -4 addr
    exit 1
fi

if [ -z "${IPLC_IF}" ]; then
    echo "错误：没有找到专线 IP ${IPLC_IP} 所在网卡"
    echo
    ip -br -4 addr
    exit 1
fi

echo "日本公网网卡： ${JP_IF}"
echo "  IP：          ${JP_IP}"
echo "  网关：        ${JP_GW}"
echo
echo "IPLC 专线网卡：${IPLC_IF}"
echo "  IP：          ${IPLC_IP}"

if [ "${JP_IF}" = "${IPLC_IF}" ]; then
    echo "错误：检测到两个 IP 位于同一个网卡，和预期双网卡结构不符"
    exit 1
fi

# =========================================================
# 检查 WireGuard UDP 端口
# =========================================================

echo
echo "[3/9] 检查 UDP 端口..."

if ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq ":${WG_PORT}$"; then
    echo "UDP ${WG_PORT} 已占用，自动寻找 4801-4899 空闲端口..."

    FOUND_PORT=""

    for P in $(seq 4801 4899); do
        if ! ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq ":${P}$"; then
            FOUND_PORT="$P"
            break
        fi
    done

    if [ -z "${FOUND_PORT}" ]; then
        echo "错误：4801-4899 没有可用 UDP 端口"
        exit 1
    fi

    WG_PORT="${FOUND_PORT}"
fi

echo "WireGuard UDP 端口：${WG_PORT}"

# =========================================================
# 清理/备份旧配置
# =========================================================

echo
echo "[4/9] 创建 WireGuard 密钥..."

mkdir -p "${WG_DIR}"
chmod 700 "${WG_DIR}"

if systemctl is-active --quiet "wg-quick@${WG_IF}" 2>/dev/null; then
    systemctl stop "wg-quick@${WG_IF}" || true
fi

if [ -f "${WG_DIR}/${WG_IF}.conf" ]; then
    BACKUP="${WG_DIR}/${WG_IF}.conf.bak.$(date +%Y%m%d-%H%M%S)"
    cp "${WG_DIR}/${WG_IF}.conf" "${BACKUP}"
    echo "旧配置已备份：${BACKUP}"
fi

umask 077

wg genkey > "${SERVER_PRIV_FILE}"
wg pubkey < "${SERVER_PRIV_FILE}" > "${SERVER_PUB_FILE}"

wg genkey > "${CLIENT_PRIV_FILE}"
wg pubkey < "${CLIENT_PRIV_FILE}" > "${CLIENT_PUB_FILE}"

SERVER_PRIV=$(cat "${SERVER_PRIV_FILE}")
SERVER_PUB=$(cat "${SERVER_PUB_FILE}")

CLIENT_PRIV=$(cat "${CLIENT_PRIV_FILE}")
CLIENT_PUB=$(cat "${CLIENT_PUB_FILE}")

# =========================================================
# 系统网络参数
# =========================================================

echo
echo "[5/9] 配置转发和双网卡参数..."

cat > /etc/sysctl.d/99-wg-iplc-game.conf <<EOF2
# WireGuard 转发
net.ipv4.ip_forward=1

# 双 WAN / IPLC 环境避免严格反向路径检查误杀
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.${JP_IF}.rp_filter=2
net.ipv4.conf.${IPLC_IF}.rp_filter=2

# 有利于带 mark 的多路由环境
net.ipv4.conf.all.src_valid_mark=1
EOF2

sysctl --system >/dev/null

# =========================================================
# WireGuard 服务端配置
# =========================================================

echo
echo "[6/9] 创建 WireGuard 服务端配置..."

cat > "${WG_DIR}/${WG_IF}.conf" <<EOF2
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
MTU = ${WG_MTU}

# ---------------------------------------------------------
# 只允许专线网卡进入 WireGuard
# ---------------------------------------------------------
PostUp = iptables -I INPUT 1 -i ${IPLC_IF} -p udp --dport ${WG_PORT} -j ACCEPT
PostDown = iptables -D INPUT -i ${IPLC_IF} -p udp --dport ${WG_PORT} -j ACCEPT || true

# ---------------------------------------------------------
# WG -> 日本公网
# ---------------------------------------------------------
PostUp = iptables -I FORWARD 1 -i ${WG_IF} -o ${JP_IF} -j ACCEPT
PostUp = iptables -I FORWARD 1 -i ${JP_IF} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

PostDown = iptables -D FORWARD -i ${WG_IF} -o ${JP_IF} -j ACCEPT || true
PostDown = iptables -D FORWARD -i ${JP_IF} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true

# ---------------------------------------------------------
# 强制游戏流量使用日本公网 IP 出口
# ---------------------------------------------------------
PostUp = iptables -t nat -A POSTROUTING -s ${WG_CIDR} -o ${JP_IF} -j SNAT --to-source ${JP_IP}
PostDown = iptables -t nat -D POSTROUTING -s ${WG_CIDR} -o ${JP_IF} -j SNAT --to-source ${JP_IP} || true

# ---------------------------------------------------------
# 独立路由表：
# 10.66.66.0/24 解密后的流量强制从日本公网网卡出去
# 不依赖系统默认路由
# ---------------------------------------------------------
PostUp = ip route replace table ${ROUTE_TABLE} default via ${JP_GW} dev ${JP_IF} onlink
PostUp = ip rule del priority ${ROUTE_PRIORITY} 2>/dev/null || true; ip rule add priority ${ROUTE_PRIORITY} from ${WG_CIDR} table ${ROUTE_TABLE}

PostDown = ip rule del priority ${ROUTE_PRIORITY} 2>/dev/null || true
PostDown = ip route flush table ${ROUTE_TABLE} 2>/dev/null || true

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${WG_CLIENT_IP}/32
EOF2

chmod 600 "${WG_DIR}/${WG_IF}.conf"

# =========================================================
# 创建原生 WireGuard 客户端配置
# =========================================================

echo
echo "[7/9] 创建客户端配置..."

cat > "${WG_DIR}/iplc-client.conf" <<EOF2
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${WG_CLIENT_IP}/24
MTU = ${WG_MTU}

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${IPLC_MOBILE_ENTRY}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
EOF2

chmod 600 "${WG_DIR}/iplc-client.conf"

# =========================================================
# OpenClash / Mihomo 配置
# =========================================================

cat > "${WG_DIR}/openclash-iplc.yaml" <<EOF2
proxies:
  - name: "沪日-IPLC-WG"
    type: wireguard
    server: ${IPLC_MOBILE_ENTRY}
    port: ${WG_PORT}
    ip: ${WG_CLIENT_IP}
    private-key: "${CLIENT_PRIV}"
    public-key: "${SERVER_PUB}"
    allowed-ips:
      - "0.0.0.0/0"
    persistent-keepalive: 15
    udp: true
    mtu: ${WG_MTU}
EOF2

chmod 600 "${WG_DIR}/openclash-iplc.yaml"

# =========================================================
# 启动
# =========================================================

echo
echo "[8/9] 启动 WireGuard..."

systemctl daemon-reload
systemctl enable "wg-quick@${WG_IF}" >/dev/null
systemctl restart "wg-quick@${WG_IF}"

sleep 1

if ! systemctl is-active --quiet "wg-quick@${WG_IF}"; then
    echo
    echo "WireGuard 启动失败："
    journalctl -u "wg-quick@${WG_IF}" --no-pager -n 50
    exit 1
fi

# =========================================================
# 创建快捷管理命令 wgggg
# =========================================================

echo
echo "[9/10] 创建快捷管理命令 wgggg..."

cat > /usr/local/bin/wgggg <<'WGGMENU'
#!/usr/bin/env bash

WG_IF="wg-iplc"
WG_DIR="/etc/wireguard"
SERVICE="wg-quick@${WG_IF}"

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo "$0" "$@"
    else
        echo "请使用 root 用户运行 wgggg"
        exit 1
    fi
fi

pause() {
    echo
    read -rp "按回车返回菜单..." _
}

do_start() {
    echo
    echo "正在启动 ${WG_IF} ..."
    systemctl start "${SERVICE}"
    echo "启动完成。"
    wg show "${WG_IF}" 2>/dev/null || true
}

do_stop() {
    echo
    echo "正在停止 ${WG_IF} ..."
    systemctl stop "${SERVICE}"
    echo "已停止。"
}

do_restart() {
    echo
    echo "正在重启 ${WG_IF} ..."
    systemctl restart "${SERVICE}"
    echo "重启完成。"
    wg show "${WG_IF}" 2>/dev/null || true
}

do_status() {
    systemctl --no-pager -l status "${SERVICE}" || true
}

do_show() {
    echo
    wg show "${WG_IF}" || true
}

do_live() {
    echo "按 Ctrl+C 退出实时监控"
    sleep 1
    watch -n1 "wg show ${WG_IF}"
}

do_server_config() {
    echo
    echo "===== 服务端配置 ====="
    cat "${WG_DIR}/${WG_IF}.conf"
}

do_openclash_config() {
    echo
    echo "===== OpenClash / Mihomo 节点配置 ====="
    cat "${WG_DIR}/openclash-iplc.yaml"
}

do_client_config() {
    echo
    echo "===== WireGuard 客户端配置 ====="
    cat "${WG_DIR}/iplc-client.conf"
}

do_logs() {
    journalctl -u "${SERVICE}" -n 100 --no-pager
}

do_enable() {
    systemctl enable "${SERVICE}"
    echo "已开启开机自启。"
}

do_disable() {
    systemctl disable "${SERVICE}"
    echo "已关闭开机自启。"
}

run_arg() {
    case "${1:-}" in
        start) do_start ;;
        stop) do_stop ;;
        restart) do_restart ;;
        status) do_status ;;
        show) do_show ;;
        live) do_live ;;
        server) do_server_config ;;
        openclash) do_openclash_config ;;
        client) do_client_config ;;
        logs) do_logs ;;
        enable) do_enable ;;
        disable) do_disable ;;
        *)
            echo "用法："
            echo "  wgggg"
            echo "  wgggg start"
            echo "  wgggg stop"
            echo "  wgggg restart"
            echo "  wgggg status"
            echo "  wgggg show"
            echo "  wgggg live"
            echo "  wgggg server"
            echo "  wgggg openclash"
            echo "  wgggg client"
            echo "  wgggg logs"
            echo "  wgggg enable"
            echo "  wgggg disable"
            exit 1
            ;;
    esac
}

if [ $# -gt 0 ]; then
    run_arg "$1"
    exit $?
fi

while true; do
    clear
    echo "======================================================"
    echo "       沪日 IPLC WireGuard 管理菜单"
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
    echo "  5. 查看 WireGuard 握手/流量"
    echo "  6. 实时查看 WireGuard 流量"
    echo "  7. 查看服务端配置"
    echo "  8. 查看 OpenClash 节点配置"
    echo "  9. 查看原生客户端配置"
    echo " 10. 查看最近 100 行日志"
    echo " 11. 开启开机自启"
    echo " 12. 关闭开机自启"
    echo "  0. 退出"
    echo
    read -rp "请选择 [0-12]: " choice

    case "$choice" in
        1) do_start; pause ;;
        2) do_stop; pause ;;
        3) do_restart; pause ;;
        4) do_status; pause ;;
        5) do_show; pause ;;
        6) do_live ;;
        7) do_server_config; pause ;;
        8) do_openclash_config; pause ;;
        9) do_client_config; pause ;;
        10) do_logs; pause ;;
        11) do_enable; pause ;;
        12) do_disable; pause ;;
        0) exit 0 ;;
        *) echo "输入无效"; sleep 1 ;;
    esac
done
WGGMENU

chmod +x /usr/local/bin/wgggg

# =========================================================
# 输出结果
# =========================================================

echo
echo "[10/10] 部署完成"
echo
echo "======================================================"
echo "        沪日 IPLC WireGuard 部署成功"
echo "======================================================"
echo
echo "日本公网："
echo "  网卡：              ${JP_IF}"
echo "  IP：                ${JP_IP}"
echo "  网关：              ${JP_GW}"
echo
echo "IPLC："
echo "  网卡：              ${IPLC_IF}"
echo "  内网 IP：           ${IPLC_IP}"
echo "  移动入口：          ${IPLC_MOBILE_ENTRY}"
echo "  面板外部连接 IP：   ${IPLC_EXTERNAL_IP}"
echo
echo "WireGuard："
echo "  UDP 端口：          ${WG_PORT}"
echo "  Server：            ${WG_SERVER_IP}"
echo "  Client：            ${WG_CLIENT_IP}"
echo "  MTU：               ${WG_MTU}"
echo
echo "OpenClash Endpoint："
echo
echo "  ${IPLC_MOBILE_ENTRY}:${WG_PORT}"
echo
echo "------------------------------------------------------"
echo "服务端公钥："
echo "${SERVER_PUB}"
echo
echo "客户端私钥："
echo "${CLIENT_PRIV}"
echo
echo "------------------------------------------------------"
echo "OpenClash / Mihomo 节点："
echo "------------------------------------------------------"
cat "${WG_DIR}/openclash-iplc.yaml"
echo
echo "------------------------------------------------------"
echo "WireGuard 原生客户端："
echo "------------------------------------------------------"
cat "${WG_DIR}/iplc-client.conf"
echo
echo "------------------------------------------------------"
echo "当前状态："
echo "------------------------------------------------------"

wg show "${WG_IF}"

echo
echo "======================================================"
echo "配置文件："
echo
echo "服务端："
echo "  ${WG_DIR}/${WG_IF}.conf"
echo
echo "OpenClash："
echo "  ${WG_DIR}/openclash-iplc.yaml"
echo
echo "原生 WG 客户端："
echo "  ${WG_DIR}/iplc-client.conf"
echo
echo "查看连接："
echo "  wg show ${WG_IF}"
echo
echo "看实时流量："
echo "  watch -n1 'wg show ${WG_IF}'"
echo
echo "快捷管理菜单："
echo "  wgggg"
echo
echo "也可以直接执行："
echo "  wgggg start | stop | restart | status | show | live | logs"
echo
echo "======================================================"
EOF
