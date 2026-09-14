#!/usr/bin/env bash
set -euo pipefail

# Official Hysteria2 + Mieru/Mita dual installer.
# Hysteria2 uses UDP on BASE_PORT.
# Mieru uses TCP on BASE_PORT + 1.
#
# This wrapper pins the tested integrated installer and applies two patches:
#   1) Mieru/Mita transport is TCP everywhere.
#   2) Debian package operations wait for apt/dpkg locks instead of failing.

BASE_INSTALL_URL="https://raw.githubusercontent.com/lssopk/123/c4b33dfa118d271dd306b193bcfbe64cd37d42b5/hy2-mieru-official/install.sh"
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

wait_for_apt_lock() {
  # Never delete lock files. Wait for the process that owns them.
  if ! command -v fuser >/dev/null 2>&1; then
    return 0
  fi

  local locks=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )
  local i lock busy

  for i in $(seq 1 300); do
    busy=0
    for lock in "${locks[@]}"; do
      if [ -e "$lock" ] && fuser "$lock" >/dev/null 2>&1; then
        busy=1
        break
      fi
    done

    if [ "$busy" -eq 0 ]; then
      return 0
    fi

    if [ "$i" -eq 1 ]; then
      echo "检测到 apt/dpkg 正在被其他进程使用，等待锁释放（最多 300 秒）..."
      for lock in "${locks[@]}"; do
        if [ -e "$lock" ]; then
          fuser -v "$lock" 2>/dev/null || true
        fi
      done
    fi
    sleep 1
  done

  echo "错误：等待 apt/dpkg 锁超过 300 秒。"
  echo "请检查正在运行的 apt/dpkg/unattended-upgrades："
  ps -ef | grep -E '[a]pt|[d]pkg|[u]nattended' || true
  exit 1
}

wait_for_apt_lock
curl -fsSL "$BASE_INSTALL_URL" -o "$TMP_FILE"

# Mita server: official Mieru TCP transport.
# Mihomo/OpenClash: transport: TCP.
# Keep `udp: true`: application UDP can still be proxied through Mieru TCP.
sed -i \
  -e 's/"protocol": "UDP"/"protocol": "TCP"/g' \
  -e 's/transport: UDP/transport: TCP/g' \
  -e 's/${MIERU_PORT}\/udp/${MIERU_PORT}\/tcp/g' \
  -e 's/${MIERU_PORT}\/UDP/${MIERU_PORT}\/TCP/g' \
  "$TMP_FILE"

# Patch every Debian/Ubuntu package operation, not only the Mita package install.
# This closes the race where unattended-upgrades starts after the initial lock check.
python3 - "$TMP_FILE" <<'PY_PATCH'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

# Base dependency stage.
s = s.replace(
    'apt-get update',
    'apt-get -o DPkg::Lock::Timeout=300 update'
)
s = s.replace(
    'apt install -y ',
    'apt-get -o DPkg::Lock::Timeout=300 install -y '
)

# Official Mita local .deb installation.
s = s.replace(
    'dpkg -i "$tmp/$pkg" || { apt-get -f install -y; dpkg -i "$tmp/$pkg"; }',
    'apt-get -o DPkg::Lock::Timeout=300 install -y "$tmp/$pkg"'
)

# Any remaining apt-get install/remove/fix-dependency commands in the generated menu.
s = s.replace(
    'apt-get install -y ',
    'apt-get -o DPkg::Lock::Timeout=300 install -y '
)
s = s.replace(
    'apt-get -f install -y',
    'apt-get -o DPkg::Lock::Timeout=300 -f install -y'
)
s = s.replace(
    'apt-get remove -y mita',
    'apt-get -o DPkg::Lock::Timeout=300 remove -y mita'
)

p.write_text(s, encoding="utf-8")
PY_PATCH

exec bash "$TMP_FILE" "$@"
