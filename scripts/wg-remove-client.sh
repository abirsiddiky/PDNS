#!/usr/bin/env bash
# Removes a WireGuard peer by name. Invoked via sudo by the web UI.
# Usage: wg-remove-client.sh <client-name>
set -euo pipefail

WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
CONF="${WG_DIR}/${WG_IFACE}.conf"
CLIENTS_DIR="${WG_CLIENTS_DIR:-/etc/wireguard-clients}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAME="${1:-}"
if [[ -z "$NAME" || ! "$NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
  echo '{"error":"invalid or missing client name"}' >&2; exit 1
fi
if [[ ! -f "${CLIENTS_DIR}/${NAME}.conf" ]]; then
  echo '{"error":"client not found"}' >&2; exit 1
fi

CLIENT_PRIV=$(grep -oP '^PrivateKey\s*=\s*\K.*' "${CLIENTS_DIR}/${NAME}.conf")
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)

python3 "${SCRIPT_DIR}/_strip_peer.py" "$CONF" "$NAME"

wg set "$WG_IFACE" peer "$CLIENT_PUB" remove || true
wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") || true

rm -f "${CLIENTS_DIR}/${NAME}.conf"
echo "{\"removed\":\"${NAME}\"}"
