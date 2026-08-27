#!/usr/bin/env bash
set -euo pipefail

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
WG_ROUTE_TABLE="51888"
WG_ROUTE_PRIORITY="11088"

WG_DIR="/etc/wireguard"
SERVER_PRIV_FILE="${WG_DIR}/iplc-server.key"
SERVER_PUB_FILE="${WG_DIR}/iplc-server.pub"
CLIENT_PRIV_FILE="${WG_DIR}/iplc-client.key"
CLIENT_PUB_FILE="${WG_DIR}/iplc-client.pub"

SS_PORT="4887"
SS_METHOD="2022-blake3-aes-128-gcm"
SS_DIR="/etc/shadowsocks-rust"
SS_CONFIG="${SS_DIR}/iplc-ss.json"
SS_PASS_FILE="${SS_DIR}/iplc-ss.key"
SS_BIN="/usr/local/bin/ssserver-iplc"
SS_SERVICE="ss-iplc"
SS_ROUTE_TABLE="51887"
SS_ROUTE_PRIORITY="11087"

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 用户运行"
    exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
    echo "错误：该脚本用于 Debian / Ubuntu"
    exit 1
fi

echo "=============================================="
echo " 沪日 IPLC WireGuard + Shadowsocks 游戏专线"
echo "=============================================="

echo "[1/10] 安装依赖..."
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
    wireguard wireguard-tools iptables iproute2 curl ca-certificates xz-utils

echo "[2/10] 自动识别双网卡..."
JP_IF=$(ip -o -4 addr show | awk -v ip="${JP_IP}" '{split($4,a,"/"); if (a[1] == ip) {print $2; exit}}')
IPLC_IF=$(ip -o -4 addr show | awk -v ip="${IPLC_IP}" '{split($4,a,"/"); if (a[1] == ip) {print $2; exit}}')

if [ -z "${JP_IF}" ]; then
    echo "错误：没有找到日本公网 IP ${JP_IP} 所在网卡"
    ip -br -4 addr
    exit 1
fi

if [ -z "${IPLC_IF}" ]; then
    echo "错误：没有找到专线 IP ${IPLC_IP} 所在网卡"
    ip -br -4 addr
    exit 1
fi

if [ "${JP_IF}" = "${IPLC_IF}" ]; then
    echo "错误：两个 IP 位于同一网卡，和预期双网卡结构不符"
    exit 1
fi

echo "日本公网网卡：${JP_IF} (${JP_IP})"
echo "IPLC 专线网卡：${IPLC_IF} (${IPLC_IP})"

if ss -H -lunp 2>/dev/null | grep -Eq ":${WG_PORT}\b" && ! systemctl is-active --quiet "wg-quick@${WG_IF}" 2>/dev/null; then
    echo "错误：UDP ${WG_PORT} 已被其他程序占用"
    exit 1
fi

if { ss -H -ltnp 2>/dev/null; ss -H -lunp 2>/dev/null; } | grep -Eq ":${SS_PORT}\b" && ! systemctl is-active --quiet "${SS_SERVICE}" 2>/dev/null; then
    echo "错误：TCP/UDP ${SS_PORT} 已被其他程序占用"
    exit 1
fi

echo "[3/10] 准备 WireGuard 密钥..."
mkdir -p "${WG_DIR}"
chmod 700 "${WG_DIR}"
umask 077

if [ ! -s "${SERVER_PRIV_FILE}" ]; then wg genkey > "${SERVER_PRIV_FILE}"; fi
if [ ! -s "${SERVER_PUB_FILE}" ]; then wg pubkey < "${SERVER_PRIV_FILE}" > "${SERVER_PUB_FILE}"; fi
if [ ! -s "${CLIENT_PRIV_FILE}" ]; then wg genkey > "${CLIENT_PRIV_FILE}"; fi
if [ ! -s "${CLIENT_PUB_FILE}" ]; then wg pubkey < "${CLIENT_PRIV_FILE}" > "${CLIENT_PUB_FILE}"; fi

SERVER_PRIV=$(cat "${SERVER_PRIV_FILE}")
SERVER_PUB=$(cat "${SERVER_PUB_FILE}")
CLIENT_PRIV=$(cat "${CLIENT_PRIV_FILE}")
CLIENT_PUB=$(cat "${CLIENT_PUB_FILE}")
chmod 600 "${SERVER_PRIV_FILE}" "${SERVER_PUB_FILE}" "${CLIENT_PRIV_FILE}" "${CLIENT_PUB_FILE}"

echo "[4/10] 配置系统网络参数..."
cat > /etc/sysctl.d/99-wg-iplc-game.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.${JP_IF}.rp_filter=2
net.ipv4.conf.${IPLC_IF}.rp_filter=2
net.ipv4.conf.all.src_valid_mark=1
EOF
sysctl --system >/dev/null

echo "[5/10] 创建 WireGuard 配置..."
if [ -f "${WG_DIR}/${WG_IF}.conf" ]; then
    cp "${WG_DIR}/${WG_IF}.conf" "${WG_DIR}/${WG_IF}.conf.bak.$(date +%Y%m%d-%H%M%S)"
fi

cat > "${WG_DIR}/${WG_IF}.conf" <<EOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
MTU = ${WG_MTU}

PostUp = iptables -C INPUT -i ${IPLC_IF} -p udp --dport ${WG_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i ${IPLC_IF} -p udp --dport ${WG_PORT} -j ACCEPT
PostDown = iptables -D INPUT -i ${IPLC_IF} -p udp --dport ${WG_PORT} -j ACCEPT 2>/dev/null || true
PostUp = iptables -C FORWARD -i ${WG_IF} -o ${JP_IF} -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i ${WG_IF} -o ${JP_IF} -j ACCEPT
PostUp = iptables -C FORWARD -i ${JP_IF} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i ${JP_IF} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -D FORWARD -i ${WG_IF} -o ${JP_IF} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${JP_IF} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostUp = iptables -t nat -C POSTROUTING -s ${WG_CIDR} -o ${JP_IF} -j SNAT --to-source ${JP_IP} 2>/dev/null || iptables -t nat -A POSTROUTING -s ${WG_CIDR} -o ${JP_IF} -j SNAT --to-source ${JP_IP}
PostDown = iptables -t nat -D POSTROUTING -s ${WG_CIDR} -o ${JP_IF} -j SNAT --to-source ${JP_IP} 2>/dev/null || true
PostUp = ip route replace table ${WG_ROUTE_TABLE} default via ${JP_GW} dev ${JP_IF} onlink
PostUp = ip rule del priority ${WG_ROUTE_PRIORITY} 2>/dev/null || true; ip rule add priority ${WG_ROUTE_PRIORITY} from ${WG_CIDR} table ${WG_ROUTE_TABLE}
PostDown = ip rule del priority ${WG_ROUTE_PRIORITY} 2>/dev/null || true
PostDown = ip route flush table ${WG_ROUTE_TABLE} 2>/dev/null || true

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${WG_CLIENT_IP}/32
EOF
chmod 600 "${WG_DIR}/${WG_IF}.conf"

cat > "${WG_DIR}/iplc-client.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${WG_CLIENT_IP}/24
MTU = ${WG_MTU}

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${IPLC_MOBILE_ENTRY}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
EOF
chmod 600 "${WG_DIR}/iplc-client.conf"

echo "[6/10] 安装并配置 Shadowsocks-Rust..."
mkdir -p "${SS_DIR}"
chmod 700 "${SS_DIR}"

case "$(uname -m)" in
    x86_64|amd64) SS_ARCH="x86_64" ;;
    aarch64|arm64) SS_ARCH="aarch64" ;;
    *) echo "错误：暂不支持该架构：$(uname -m)"; exit 1 ;;
esac

if [ ! -x "${SS_BIN}" ]; then
    SS_VERSION=$(curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n1)
    if [ -z "${SS_VERSION}" ]; then
        echo "错误：无法获取 Shadowsocks-Rust 最新版本"
        exit 1
    fi
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "${TMP_DIR}"' EXIT
    SS_ARCHIVE="shadowsocks-${SS_VERSION}.${SS_ARCH}-unknown-linux-musl.tar.xz"
    SS_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SS_VERSION}/${SS_ARCHIVE}"
    curl -fL "${SS_URL}" -o "${TMP_DIR}/${SS_ARCHIVE}"
    tar -xJf "${TMP_DIR}/${SS_ARCHIVE}" -C "${TMP_DIR}"
    install -m 755 "${TMP_DIR}/ssserver" "${SS_BIN}"
    rm -rf "${TMP_DIR}"
    trap - EXIT
fi

if [ ! -s "${SS_PASS_FILE}" ]; then
    head -c 16 /dev/urandom | base64 | tr -d '\n' > "${SS_PASS_FILE}"
fi
SS_PASSWORD=$(cat "${SS_PASS_FILE}")
chmod 600 "${SS_PASS_FILE}"

cat > "${SS_CONFIG}" <<EOF
{
  "server": "${IPLC_IP}",
  "server_port": ${SS_PORT},
  "password": "${SS_PASSWORD}",
  "method": "${SS_METHOD}",
  "mode": "tcp_and_udp",
  "outbound_bind_interface": "${JP_IF}",
  "outbound_bind_addr": "${JP_IP}",
  "outbound_udp_allow_fragmentation": true
}
EOF
chmod 600 "${SS_CONFIG}"

cat > /etc/systemd/system/${SS_SERVICE}.service <<EOF
[Unit]
Description=IPLC Shadowsocks-Rust Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c '/usr/sbin/iptables -C INPUT -i ${IPLC_IF} -p tcp --dport ${SS_PORT} -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I INPUT 1 -i ${IPLC_IF} -p tcp --dport ${SS_PORT} -j ACCEPT'
ExecStartPre=/bin/sh -c '/usr/sbin/iptables -C INPUT -i ${IPLC_IF} -p udp --dport ${SS_PORT} -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I INPUT 1 -i ${IPLC_IF} -p udp --dport ${SS_PORT} -j ACCEPT'
ExecStartPre=/bin/sh -c '/usr/sbin/ip route replace table ${SS_ROUTE_TABLE} default via ${JP_GW} dev ${JP_IF} onlink'
ExecStartPre=/bin/sh -c '/usr/sbin/ip rule del priority ${SS_ROUTE_PRIORITY} 2>/dev/null || true; /usr/sbin/ip rule add priority ${SS_ROUTE_PRIORITY} from ${JP_IP}/32 table ${SS_ROUTE_TABLE}'
ExecStart=${SS_BIN} -c ${SS_CONFIG}
ExecStopPost=/bin/sh -c '/usr/sbin/ip rule del priority ${SS_ROUTE_PRIORITY} 2>/dev/null || true'
ExecStopPost=/bin/sh -c '/usr/sbin/ip route flush table ${SS_ROUTE_TABLE} 2>/dev/null || true'
ExecStopPost=/bin/sh -c '/usr/sbin/iptables -D INPUT -i ${IPLC_IF} -p tcp --dport ${SS_PORT} -j ACCEPT 2>/dev/null || true'
ExecStopPost=/bin/sh -c '/usr/sbin/iptables -D INPUT -i ${IPLC_IF} -p udp --dport ${SS_PORT} -j ACCEPT 2>/dev/null || true'
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo "[7/10] 创建 OpenClash / Mihomo 节点配置..."
cat > "${WG_DIR}/openclash-iplc.yaml" <<EOF
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

  - name: "沪日-IPLC-SS"
    type: ss
    server: ${IPLC_MOBILE_ENTRY}
    port: ${SS_PORT}
    cipher: ${SS_METHOD}
    password: "${SS_PASSWORD}"
    udp: true
EOF
chmod 600 "${WG_DIR}/openclash-iplc.yaml"

cat > "${SS_DIR}/openclash-ss.yaml" <<EOF
proxies:
  - name: "沪日-IPLC-SS"
    type: ss
    server: ${IPLC_MOBILE_ENTRY}
    port: ${SS_PORT}
    cipher: ${SS_METHOD}
    password: "${SS_PASSWORD}"
    udp: true
EOF
chmod 600 "${SS_DIR}/openclash-ss.yaml"

echo "[8/10] 启动 WireGuard 和 Shadowsocks..."
systemctl daemon-reload
systemctl enable "wg-quick@${WG_IF}" "${SS_SERVICE}" >/dev/null
systemctl restart "wg-quick@${WG_IF}"
systemctl restart "${SS_SERVICE}"
sleep 1

if ! systemctl is-active --quiet "wg-quick@${WG_IF}"; then
    echo "WireGuard 启动失败："
    journalctl -u "wg-quick@${WG_IF}" --no-pager -n 50
    exit 1
fi
if ! systemctl is-active --quiet "${SS_SERVICE}"; then
    echo "Shadowsocks 启动失败："
    journalctl -u "${SS_SERVICE}" --no-pager -n 50
    exit 1
fi

echo "[9/10] 创建快捷管理命令 wgggg..."
cat > /usr/local/bin/wgggg <<'WGGMENU'
#!/usr/bin/env bash
WG_IF="wg-iplc"
WG_SERVICE="wg-quick@wg-iplc"
WG_DIR="/etc/wireguard"
SS_SERVICE="ss-iplc"
SS_DIR="/etc/shadowsocks-rust"
JP_IP="87.86.22.157"
SS_ROUTE_TABLE="51887"
SS_ROUTE_PRIORITY="11087"

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then exec sudo "$0" "$@"; fi
    echo "请使用 root 用户运行 wgggg"
    exit 1
fi

pause() { echo; read -rp "按回车返回菜单..." _; }
status_word() { if systemctl is-active --quiet "$1"; then echo "运行中"; else echo "已停止"; fi; }
wg_start() { systemctl start "${WG_SERVICE}"; }
wg_stop() { systemctl stop "${WG_SERVICE}"; }
wg_restart() { systemctl restart "${WG_SERVICE}"; }
ss_start() { systemctl start "${SS_SERVICE}"; }
ss_stop() { systemctl stop "${SS_SERVICE}"; }
ss_restart() { systemctl restart "${SS_SERVICE}"; }
all_start() { wg_start; ss_start; }
all_stop() { wg_stop; ss_stop; }
all_restart() { wg_restart; ss_restart; }

show_status() {
    echo "WG：$(status_word "${WG_SERVICE}")"
    echo "SS：$(status_word "${SS_SERVICE}")"
    echo
    systemctl --no-pager -l status "${WG_SERVICE}" "${SS_SERVICE}" || true
}
show_wg() { wg show "${WG_IF}" || true; }
show_live() { echo "按 Ctrl+C 退出"; sleep 1; watch -n1 "wg show ${WG_IF}"; }
show_openclash() { cat "${WG_DIR}/openclash-iplc.yaml"; }
show_wg_client() { cat "${WG_DIR}/iplc-client.conf"; }
show_ss_config() {
    echo "===== Shadowsocks 服务端 ====="
    cat "${SS_DIR}/iplc-ss.json"
    echo
    echo "===== OpenClash SS 节点 ====="
    cat "${SS_DIR}/openclash-ss.yaml"
}
show_wg_logs() { journalctl -u "${WG_SERVICE}" -n 100 --no-pager; }
show_ss_logs() { journalctl -u "${SS_SERVICE}" -n 100 --no-pager; }
show_ss_route() {
    echo "===== SS 策略路由 ====="
    ip rule show | grep -E "${SS_ROUTE_PRIORITY}:|lookup ${SS_ROUTE_TABLE}" || true
    echo
    ip route show table "${SS_ROUTE_TABLE}" || true
    echo
    echo "===== 以 ${JP_IP} 为源地址查询 1.1.1.1 ====="
    ip route get 1.1.1.1 from "${JP_IP}" || true
}
test_ss_exit() {
    echo "测试 ${JP_IP} 公网出口..."
    OUT=$(curl -4 --connect-timeout 8 --max-time 15 --interface "${JP_IP}" -fsSL https://api.ipify.org 2>/dev/null || true)
    if [ "${OUT}" = "${JP_IP}" ]; then
        echo "正常：出口 IP = ${OUT}"
    elif [ -n "${OUT}" ]; then
        echo "异常：返回出口 IP = ${OUT}，预期 ${JP_IP}"
    else
        echo "失败：通过 ${JP_IP} 访问外网超时/失败"
    fi
}
enable_all() { systemctl enable "${WG_SERVICE}" "${SS_SERVICE}"; }
disable_all() { systemctl disable "${WG_SERVICE}" "${SS_SERVICE}"; }

usage() {
    echo "wgggg"
    echo "wgggg wg start|stop|restart|status|show|live|logs|client"
    echo "wgggg ss start|stop|restart|status|show|logs|route|test"
    echo "wgggg all start|stop|restart|status"
    echo "wgggg openclash"
}

if [ $# -gt 0 ]; then
    case "${1:-}" in
        wg)
            case "${2:-}" in
                start) wg_start ;; stop) wg_stop ;; restart) wg_restart ;;
                status) systemctl --no-pager -l status "${WG_SERVICE}" || true ;;
                show) show_wg ;; live) show_live ;; logs) show_wg_logs ;; client) show_wg_client ;;
                *) usage; exit 1 ;;
            esac ;;
        ss)
            case "${2:-}" in
                start) ss_start ;; stop) ss_stop ;; restart) ss_restart ;;
                status) systemctl --no-pager -l status "${SS_SERVICE}" || true ;;
                show) show_ss_config ;; logs) show_ss_logs ;; route) show_ss_route ;; test) test_ss_exit ;;
                *) usage; exit 1 ;;
            esac ;;
        all)
            case "${2:-}" in
                start) all_start ;; stop) all_stop ;; restart) all_restart ;; status) show_status ;;
                *) usage; exit 1 ;;
            esac ;;
        openclash) show_openclash ;;
        start) wg_start ;; stop) wg_stop ;; restart) wg_restart ;;
        status) systemctl --no-pager -l status "${WG_SERVICE}" || true ;;
        show) show_wg ;; live) show_live ;; logs) show_wg_logs ;; client) show_wg_client ;;
        *) usage; exit 1 ;;
    esac
    exit $?
fi

while true; do
    clear
    echo "======================================================"
    echo "       沪日 IPLC WG + SS2022 管理菜单"
    echo "======================================================"
    echo "WG：$(status_word "${WG_SERVICE}")"
    echo "SS：$(status_word "${SS_SERVICE}")"
    echo
    echo "  1. 启动 WireGuard"
    echo "  2. 停止 WireGuard"
    echo "  3. 重启 WireGuard"
    echo "  4. 启动 Shadowsocks"
    echo "  5. 停止 Shadowsocks"
    echo "  6. 重启 Shadowsocks"
    echo "  7. 启动 WG + SS"
    echo "  8. 停止 WG + SS"
    echo "  9. 重启 WG + SS"
    echo " 10. 查看服务状态"
    echo " 11. 查看 WG 握手/流量"
    echo " 12. 实时查看 WG 流量"
    echo " 13. 查看 OpenClash 两个节点"
    echo " 14. 查看 WG 客户端配置"
    echo " 15. 查看 SS 配置"
    echo " 16. 查看 WG 日志"
    echo " 17. 查看 SS 日志"
    echo " 18. 查看 SS 强制出站路由"
    echo " 19. 测试 87.86.22.157 公网出口"
    echo " 20. 开启 WG + SS 开机自启"
    echo " 21. 关闭 WG + SS 开机自启"
    echo "  0. 退出"
    echo
    read -rp "请选择 [0-21]: " choice
    case "${choice}" in
        1) wg_start; pause ;; 2) wg_stop; pause ;; 3) wg_restart; pause ;;
        4) ss_start; pause ;; 5) ss_stop; pause ;; 6) ss_restart; pause ;;
        7) all_start; pause ;; 8) all_stop; pause ;; 9) all_restart; pause ;;
        10) show_status; pause ;; 11) show_wg; pause ;; 12) show_live ;;
        13) show_openclash; pause ;; 14) show_wg_client; pause ;; 15) show_ss_config; pause ;;
        16) show_wg_logs; pause ;; 17) show_ss_logs; pause ;; 18) show_ss_route; pause ;;
        19) test_ss_exit; pause ;; 20) enable_all; pause ;; 21) disable_all; pause ;;
        0) exit 0 ;; *) echo "输入无效"; sleep 1 ;;
    esac
done
WGGMENU
chmod +x /usr/local/bin/wgggg

echo "[10/10] 部署完成"
echo
echo "======================================================"
echo "        沪日 IPLC 双协议部署成功"
echo "======================================================"
echo "WireGuard：${IPLC_MOBILE_ENTRY}:${WG_PORT}/UDP"
echo "Shadowsocks：${IPLC_MOBILE_ENTRY}:${SS_PORT}/TCP+UDP"
echo "SS 加密：${SS_METHOD}"
echo "SS 出站：${JP_IP} -> table ${SS_ROUTE_TABLE} -> ${JP_GW}"
echo
echo "OpenClash / Mihomo："
cat "${WG_DIR}/openclash-iplc.yaml"
echo
echo "管理菜单：wgggg"
echo "测试 SS 路由：wgggg ss route"
echo "测试公网出口：wgggg ss test"
echo "======================================================"
