#!/usr/bin/env bash
set -euo pipefail

HY2_INSTALL_URL="https://raw.githubusercontent.com/lssopk/123/main/hy2/install.sh"
MITA_INSTALL_URL="https://raw.githubusercontent.com/ike-sh/mieru-OneClick/main/install-mita.sh"
WORKDIR="/opt/hy2-mita-installer"
STATE_FILE="${WORKDIR}/state.env"
MENU_BIN="/usr/local/bin/proxy2"

if [ "$(id -u)" -ne 0 ]; then
  echo "错误：请使用 root 用户运行"
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令：$1"
    exit 1
  }
}

need_cmd curl
need_cmd bash
need_cmd sed
need_cmd awk

mkdir -p "$WORKDIR"

valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65534 ]
}

clear || true
echo "======================================================"
echo "       HY2 + Mita/Mieru 双代理一键安装器"
echo "======================================================"
echo
read -rp "请输入基础 UDP 端口 [18611]: " BASE_PORT
BASE_PORT="${BASE_PORT:-18611}"
if ! valid_port "$BASE_PORT"; then
  echo "错误：基础端口必须是 1-65534"
  exit 1
fi
HY2_PORT="$BASE_PORT"
MITA_PORT="$((BASE_PORT + 1))"

echo
echo "端口规划："
echo "  官方 Hysteria2 : ${HY2_PORT}/UDP"
echo "  Mita/Mieru     : ${MITA_PORT}/UDP"
echo
read -rp "确认开始安装？[Y/n]: " yn
if [[ "${yn:-Y}" =~ ^[Nn]$ ]]; then
  exit 0
fi

cat > "$STATE_FILE" <<EOF
BASE_PORT=${BASE_PORT}
HY2_PORT=${HY2_PORT}
MITA_PORT=${MITA_PORT}
EOF
chmod 600 "$STATE_FILE"

echo
echo "[1/4] 安装官方 Hysteria2..."
TMP_HY2="${WORKDIR}/hy2-install.sh"
curl -fsSL "$HY2_INSTALL_URL" -o "$TMP_HY2"
chmod +x "$TMP_HY2"

# 你的 HY2 脚本本身是交互式的，目前通过预填第一项端口来保证使用基础端口。
# 其余 SNI、证书、密码等仍由用户按原脚本自行配置。
{
  printf '%s\n' "$HY2_PORT"
  cat /dev/tty
} | bash "$TMP_HY2"

echo
echo "[2/4] 准备 Mita/Mieru 安装脚本..."
TMP_MITA_ORIG="${WORKDIR}/install-mita.orig.sh"
TMP_MITA="${WORKDIR}/install-mita.patched.sh"
curl -fsSL "$MITA_INSTALL_URL" -o "$TMP_MITA_ORIG"
cp "$TMP_MITA_ORIG" "$TMP_MITA"
chmod +x "$TMP_MITA"

# 尽量只替换脚本里明确的默认端口值；若上游脚本仍要求交互，用户按提示确认即可。
# 这样既不改动协议逻辑，也避免直接 fork 上游大量代码。
for old in 8964 5000 443 8443 10000; do
  if grep -qE "(^|[^0-9])${old}([^0-9]|$)" "$TMP_MITA"; then
    sed -i -E "s/(^|[^0-9])${old}([^0-9]|$)/\\1${MITA_PORT}\\2/g" "$TMP_MITA"
    break
  fi
done

export MITA_PORT
export MIERU_PORT="$MITA_PORT"
export SERVER_PORT="$MITA_PORT"
export PORT="$MITA_PORT"

echo "Mita/Mieru 计划使用端口：${MITA_PORT}"
bash "$TMP_MITA"

echo
echo "[3/4] 创建统一快捷菜单 proxy2..."
cat > "$MENU_BIN" <<'MENU'
#!/usr/bin/env bash
set -u
STATE_FILE="/opt/hy2-mita-installer/state.env"

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then exec sudo "$0" "$@"; fi
  echo "请使用 root 运行 proxy2"
  exit 1
fi

[ -f "$STATE_FILE" ] && . "$STATE_FILE"
pause(){ echo; read -rp "按回车返回菜单..." _; }

show_ports(){
  echo "Hysteria2 : ${HY2_PORT:-未知}/UDP"
  echo "Mita/Mieru: ${MITA_PORT:-未知}/UDP"
}

show_hy2(){
  if command -v hy2 >/dev/null 2>&1; then hy2; else echo "未检测到 hy2 快捷命令"; fi
}

show_mita(){
  for cmd in mita mieru mita.sh mieru-manager; do
    if command -v "$cmd" >/dev/null 2>&1; then
      "$cmd"
      return
    fi
  done
  echo "未检测到已知 Mita/Mieru 快捷命令。"
  echo "请查看上游安装脚本输出确认其管理命令。"
}

status_all(){
  echo "========== 端口 =========="
  show_ports
  echo
  echo "========== HY2 =========="
  systemctl --no-pager -l status hysteria-server.service 2>/dev/null || true
  echo
  echo "========== Mita/Mieru 相关服务 =========="
  systemctl list-units --type=service --all --no-pager | grep -Ei 'mita|mieru' || true
}

while true; do
  clear || true
  echo "======================================================"
  echo "           HY2 + Mita/Mieru 管理菜单"
  echo "======================================================"
  show_ports
  echo
  echo "  1. 打开 HY2 管理菜单"
  echo "  2. 打开 Mita/Mieru 管理菜单"
  echo "  3. 查看两套代理状态"
  echo "  4. 查看 UDP 监听"
  echo "  5. 重启 HY2"
  echo "  6. 尝试重启 Mita/Mieru 服务"
  echo "  0. 退出"
  echo
  read -rp "请选择 [0-6]: " c
  case "$c" in
    1) show_hy2 ;;
    2) show_mita; pause ;;
    3) status_all; pause ;;
    4) ss -lunp 2>/dev/null | grep -E ":(${HY2_PORT:-0}|${MITA_PORT:-0})[[:space:]]" || true; pause ;;
    5) if command -v hy2 >/dev/null 2>&1; then hy2 restart; else systemctl restart hysteria-server.service; fi; pause ;;
    6)
      svc="$(systemctl list-unit-files --type=service --no-pager 2>/dev/null | awk 'tolower($1) ~ /(mita|mieru)/ {print $1; exit}')"
      if [ -n "$svc" ]; then systemctl restart "$svc" && echo "已重启 $svc"; else echo "未找到 Mita/Mieru systemd 服务"; fi
      pause ;;
    0) exit 0 ;;
    *) echo "输入无效"; sleep 1 ;;
  esac
done
MENU
chmod +x "$MENU_BIN"

echo
echo "[4/4] 安装完成"
echo "======================================================"
echo "官方 Hysteria2 : ${HY2_PORT}/UDP"
echo "Mita/Mieru     : ${MITA_PORT}/UDP"
echo "统一快捷菜单   : proxy2"
echo "HY2 快捷菜单   : hy2"
echo "======================================================"
echo
echo "注意：Mita/Mieru 上游脚本的交互和快捷命令由 ike-sh/mieru-OneClick 决定。"
echo "本安装器会下载原脚本到 ${TMP_MITA_ORIG}，并在本地副本上尝试将默认端口替换为 ${MITA_PORT}。"
