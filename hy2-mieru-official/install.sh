#!/usr/bin/env bash
set -euo pipefail

# Official Hysteria2 + Mieru/Mita dual installer.
# Hysteria2 uses UDP on BASE_PORT.
# Mieru uses TCP on BASE_PORT + 1.
#
# The full installer is pinned to the original integrated implementation
# and patched here so both the initial configuration and the generated
# proxy2 management menu consistently use Mieru TCP transport.

BASE_INSTALL_URL="https://raw.githubusercontent.com/lssopk/123/c4b33dfa118d271dd306b193bcfbe64cd37d42b5/hy2-mieru-official/install.sh"
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

curl -fsSL "$BASE_INSTALL_URL" -o "$TMP_FILE"

# Mita server: listen with the official Mieru TCP transport.
# Mihomo/OpenClash: use transport: TCP.
# Keep `udp: true` on the Mihomo node intentionally: official Mieru
# supports UDP Associate over the TCP proxy transport.
sed -i \
  -e 's/"protocol": "UDP"/"protocol": "TCP"/g' \
  -e 's/transport: UDP/transport: TCP/g' \
  -e 's/${MIERU_PORT}\/udp/${MIERU_PORT}\/tcp/g' \
  -e 's/${MIERU_PORT}\/UDP/${MIERU_PORT}\/TCP/g' \
  "$TMP_FILE"

exec bash "$TMP_FILE" "$@"
