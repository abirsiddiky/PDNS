#!/usr/bin/env bash
# Adds a WireGuard peer. Meant to be invoked via sudo (see /etc/sudoers.d/dns-vpn-ui).
# Usage: wg-add-client.sh <client-name>
# Prints JSON: {"name":..,"ip":..,"public_key":..,"config":..,"qr_png_b64":..}
set -euo pipefail

WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
CONF="${WG_DIR}/${WG_IFACE}.conf"
CLIENTS_DIR="${WG_CLIENTS_DIR:-/etc/wireguard-clients}"
WEBUI_USER="${WEBUI_USER:-www-data}"
SUBNET_PREFIX="10.66.0"
SERVER_PUBKEY_FILE="${WG_DIR}/server_public.key"

NAME="${1:-}"
if [[ -z "$NAME" || ! "$NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
  echo '{"error":"invalid or missing client name"}' >&2; exit 1
fi
if [[ -f "${CLIENTS_DIR}/${NAME}.conf" ]]; then
  echo '{"error":"client already exists"}' >&2; exit 1
fi

mkdir -p "$CLIENTS_DIR"
chown "root:${WEBUI_USER}" "$CLIENTS_DIR" 2>/dev/null || true
chmod 750 "$CLIENTS_DIR"

# Find next free IP in the /24 (skip .1 = server)
USED_IPS=$(grep -oE "${SUBNET_PREFIX}\.[0-9]+" "$CONF" 2>/dev/null || true)
for i in $(seq 2 254); do
  CANDIDATE="${SUBNET_PREFIX}.${i}"
  if ! grep -q "^${CANDIDATE}$" <<< "$USED_IPS"; then
    CLIENT_IP="$CANDIDATE"
    break
  fi
done
if [[ -z "${CLIENT_IP:-}" ]]; then
  echo '{"error":"no free IPs in subnet"}' >&2; exit 1
fi

umask 077
CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)
PSK=$(wg genpsk)
SERVER_PUB=$(cat "$SERVER_PUBKEY_FILE")
SERVER_ENDPOINT_IP="${SERVER_PUB_IP:-$(curl -fsSL4 https://api.ipify.org || echo "CHANGE-ME")}"
WG_PORT=$(grep -oP 'ListenPort\s*=\s*\K[0-9]+' "$CONF")

# Append peer to server config and sync live (no restart / no dropped clients)
cat >> "$CONF" <<EOF

[Peer]
# name=${NAME}
PublicKey = ${CLIENT_PUB}
PresharedKey = ${PSK}
AllowedIPs = ${CLIENT_IP}/32
EOF

wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE")

CLIENT_CONF="[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_IP}/32
DNS = 10.66.0.1

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PSK}
Endpoint = ${SERVER_ENDPOINT_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
"

echo "$CLIENT_CONF" > "${CLIENTS_DIR}/${NAME}.conf"
chmod 640 "${CLIENTS_DIR}/${NAME}.conf"
chgrp "${WEBUI_USER}" "${CLIENTS_DIR}/${NAME}.conf" 2>/dev/null || true
QR_B64=$(qrencode -t PNG -o - <<< "$CLIENT_CONF" | base64 -w0)

python3 - "$NAME" "$CLIENT_IP" "$CLIENT_PUB" "$QR_B64" <<'PYEOF' 2>/dev/null || true
import json,sys
name, ip, pub, qr = sys.argv[1:5]
print(json.dumps({"name": name, "ip": ip, "public_key": pub, "qr_png_b64": qr}))
PYEOF

# Fallback JSON emit if python3 isn't available
if ! command -v python3 >/dev/null 2>&1; then
  printf '{"name":"%s","ip":"%s","public_key":"%s","qr_png_b64":"%s"}\n' "$NAME" "$CLIENT_IP" "$CLIENT_PUB" "$QR_B64"
fi
