#!/usr/bin/env bash
#
# dns-vpn-stack installer
# WireGuard + Unbound + Pi-hole + custom VPN-only PHP Web UI
# Tested target: Debian 11/12, Ubuntu 20.04/22.04/24.04 (root required)
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this as root (sudo bash install.sh)"; exit 1
fi

trap 'echo -e "\n\033[1;31m✘ install.sh failed at line $LINENO: $BASH_COMMAND\033[0m" >&2' ERR

# ---------------------------------------------------------------------------
# 0. Config (override with env vars before running, e.g. WG_PORT=51821 ./install.sh)
# ---------------------------------------------------------------------------
WG_IFACE="${WG_IFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET="${WG_SUBNET:-10.66.0.0/24}"
WG_SERVER_IP="${WG_SERVER_IP:-10.66.0.1}"
UNBOUND_PORT="${UNBOUND_PORT:-5335}"
WEBUI_PORT="${WEBUI_PORT:-8443}"
WEBUI_DIR="/opt/dns-vpn-ui"
WG_DIR="/etc/wireguard"
WG_CLIENTS_DIR="${WG_CLIENTS_DIR:-/etc/wireguard-clients}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16; true)}"
SERVER_PUB_IP="${SERVER_PUB_IP:-$(curl -fsSL4 --max-time 5 https://api.ipify.org 2>/dev/null || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || true)}"
SUDO_USER_FOR_WEBUI="${SUDO_USER_FOR_WEBUI:-www-data}"
RUN_HEALTHCHECK="${RUN_HEALTHCHECK:-yes}"       # set to "no" to skip the post-install check
FIRST_CLIENT_NAME="${FIRST_CLIENT_NAME:-first-client}"
SKIP_FIRST_CLIENT="${SKIP_FIRST_CLIENT:-no}"    # set to "yes" to skip auto-creating + QR-printing a client

log() { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m! $*\033[0m"; }

if [[ -z "$SERVER_PUB_IP" ]]; then
  warn "Couldn't auto-detect the server's public IP (outbound curl to api.ipify.org / ifconfig.me failed)."
  warn "Client configs will use 'CHANGE-ME' as the endpoint — edit /etc/wireguard/clients/*.conf"
  warn "and replace it with this VPS's public IP after install, or re-run with SERVER_PUB_IP=x.x.x.x ./install.sh"
  SERVER_PUB_IP="CHANGE-ME"
fi

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  wireguard wireguard-tools qrencode \
  unbound unbound-anchor dns-root-data \
  curl ca-certificates gnupg lsb-release \
  php-cli php-sqlite3 php-json php-curl \
  sqlite3 ufw jq net-tools iproute2 dnsutils

# ---------------------------------------------------------------------------
# 2. Unbound (recursive resolver, loopback only)
# ---------------------------------------------------------------------------
log "Configuring Unbound on 127.0.0.1:${UNBOUND_PORT}"
mkdir -p /etc/unbound/unbound.conf.d
cat > /etc/unbound/unbound.conf.d/dns-vpn-stack.conf <<EOF
server:
    interface: 127.0.0.1@${UNBOUND_PORT}
    port: ${UNBOUND_PORT}
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    root-hints: "/var/lib/unbound/root.hints"
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
    edns-buffer-size: 1232
    prefetch: yes
    num-threads: 2
    so-rcvbuf: 1m
    private-address: ${WG_SUBNET}
    access-control: 127.0.0.0/8 allow
    hide-identity: yes
    hide-version: yes
EOF
curl -fsSL https://www.internic.net/domain/named.root -o /var/lib/unbound/root.hints || \
  curl -fsSL https://raw.githubusercontent.com/PowerDNS/pdns/master/regression-tests/named.root -o /var/lib/unbound/root.hints
systemctl enable --now unbound
systemctl restart unbound

# ---------------------------------------------------------------------------
# 3. WireGuard server
# ---------------------------------------------------------------------------
log "Configuring WireGuard interface ${WG_IFACE}"
mkdir -p "${WG_DIR}"
chmod 700 "${WG_DIR}"

# Client configs live OUTSIDE /etc/wireguard on purpose: /etc/wireguard holds
# the server private key + peer preshared keys (wg0.conf) and must stay
# root-only. The web UI (running as ${SUDO_USER_FOR_WEBUI}) needs to read
# client configs to show QR codes / downloads, so they get their own
# directory, group-readable only by the web UI user.
mkdir -p "${WG_CLIENTS_DIR}"
chown "root:${SUDO_USER_FOR_WEBUI}" "${WG_CLIENTS_DIR}"
chmod 750 "${WG_CLIENTS_DIR}"

if [[ ! -f "${WG_DIR}/server_private.key" ]]; then
  umask 077
  wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
fi
SERVER_PRIV=$(cat "${WG_DIR}/server_private.key")
SERVER_PUB=$(cat "${WG_DIR}/server_public.key")

WAN_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)
if [[ -z "$WAN_IFACE" ]]; then
  warn "Couldn't detect the default network interface — falling back to 'eth0'."
  warn "If that's wrong, edit PostUp/PostDown in ${WG_DIR}/${WG_IFACE}.conf after install."
  WAN_IFACE="eth0"
fi

if [[ ! -f "${WG_DIR}/${WG_IFACE}.conf" ]]; then
cat > "${WG_DIR}/${WG_IFACE}.conf" <<EOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = iptables -A FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_IFACE} -j MASQUERADE
SaveConfig = false

# --- managed clients appended below by the web UI / scripts ---
EOF
fi

sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

systemctl enable --now "wg-quick@${WG_IFACE}"
systemctl restart "wg-quick@${WG_IFACE}" || wg-quick up "${WG_IFACE}"

# ---------------------------------------------------------------------------
# 4. Pi-hole (unattended, DNS upstream = Unbound, bound to wg0 + lo only)
# ---------------------------------------------------------------------------
log "Installing Pi-hole"
mkdir -p /etc/pihole
cat > /etc/pihole/setupVars.conf <<EOF
PIHOLE_INTERFACE=${WG_IFACE}
IPV4_ADDRESS=${WG_SERVER_IP}/24
IPV6_ADDRESS=
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=single
PIHOLEDNS_1=127.0.0.1#${UNBOUND_PORT}
PIHOLE_DNS_1=127.0.0.1#${UNBOUND_PORT}
DNSSEC=false
REV_SERVER=false
BLOCKING_ENABLED=true
WEBPASSWORD=
WEBUIBOXEDLAYOUT=boxed
EOF

if ! command -v pihole >/dev/null 2>&1; then
  curl -sSL https://install.pi-hole.net -o /tmp/pihole-install.sh
  bash /tmp/pihole-install.sh --unattended
fi

# Lock Pi-hole's admin UI to loopback + the WireGuard subnet only.
# Pi-hole v6+ ships a built-in webserver inside pihole-FTL (no more
# lighttpd/PHP) configured via /etc/pihole/pihole.toml, so we use its
# native ACL feature. The old lighttpd path is kept for anyone still on v5.
if [[ -f /etc/lighttpd/lighttpd.conf ]]; then
  sed -i "s/^server.bind.*/server.bind = \"${WG_SERVER_IP}\"/" /etc/lighttpd/lighttpd.conf
  grep -q "^server.bind" /etc/lighttpd/lighttpd.conf || \
    echo "server.bind = \"${WG_SERVER_IP}\"" >> /etc/lighttpd/lighttpd.conf
  systemctl restart lighttpd || true
elif command -v pihole-FTL >/dev/null 2>&1; then
  pihole-FTL --config webserver.acl "+127.0.0.1,+[::1],+${WG_SUBNET}" 2>/dev/null || \
    warn "Couldn't set Pi-hole's webserver ACL — its admin UI may be reachable outside the tunnel too."
fi
pihole -a -p "${ADMIN_PASS}"

# Known Pi-hole v6 quirk: its embedded (CivetWeb) webserver can 404 on
# /admin/ even though the files exist — usually a directory-traversal
# permission issue on /var/www, or the port config not taking. Both
# fixes below are non-interactive and harmless to re-apply.
# See: https://discourse.pi-hole.net/t/update-to-version-6-404-for-admin-site/76046
chmod 755 /var/www /var/www/html 2>/dev/null || true
pihole-FTL --config webserver.port "80o,443os,[::]:80o,[::]:443os" 2>/dev/null || true

systemctl restart pihole-FTL 2>/dev/null || true
sleep 2   # give FTL's embedded webserver a moment to come back up

# The custom panel (running as ${SUDO_USER_FOR_WEBUI}) reads pihole-FTL.db
# directly (read-only) to show the live query log — needs group access.
usermod -aG pihole "${SUDO_USER_FOR_WEBUI}" 2>/dev/null || \
  warn "Couldn't add ${SUDO_USER_FOR_WEBUI} to the 'pihole' group — live DNS queries in the panel may not load."
chmod g+r /etc/pihole/pihole-FTL.db 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Web UI deployment
# ---------------------------------------------------------------------------
log "Deploying custom Web UI to ${WEBUI_DIR}"
mkdir -p "${WEBUI_DIR}"
cp -r "$(dirname "$0")/webui" "${WEBUI_DIR}/"
cp -r "$(dirname "$0")/scripts" "${WEBUI_DIR}/scripts"
chmod +x "${WEBUI_DIR}"/scripts/*.sh

PASS_HASH=$(P="${ADMIN_PASS}" php -r "echo password_hash(getenv('P'), PASSWORD_BCRYPT);")
cat > "${WEBUI_DIR}/webui/config.php" <<EOF
<?php
return [
    'admin_user'    => '${ADMIN_USER}',
    'admin_hash'    => '${PASS_HASH}',
    'wg_iface'      => '${WG_IFACE}',
    'wg_conf'       => '${WG_DIR}/${WG_IFACE}.conf',
    'wg_clients_dir'=> '${WG_CLIENTS_DIR}',
    'wg_subnet'     => '${WG_SUBNET}',
    'wg_server_ip'  => '${WG_SERVER_IP}',
    'wg_port'       => ${WG_PORT},
    'server_pub_ip' => '${SERVER_PUB_IP}',
    'server_pubkey' => '${SERVER_PUB}',
    'pihole_db'     => '/etc/pihole/pihole-FTL.db',
    'pihole_admin_url' => 'http://${WG_SERVER_IP}/admin/',
    'allowed_cidr'  => '${WG_SUBNET}',
    'session_name'  => 'dnsvpnui_sess',
];
EOF

# sudoers: allow the web-serving user to run only the wrapper scripts as root
cat > /etc/sudoers.d/dns-vpn-ui <<EOF
${SUDO_USER_FOR_WEBUI} ALL=(root) NOPASSWD: ${WEBUI_DIR}/scripts/wg-add-client.sh, ${WEBUI_DIR}/scripts/wg-remove-client.sh, ${WEBUI_DIR}/scripts/wg-status.sh
EOF
chmod 440 /etc/sudoers.d/dns-vpn-ui
visudo -cf /etc/sudoers.d/dns-vpn-ui

chown -R "${SUDO_USER_FOR_WEBUI}:${SUDO_USER_FOR_WEBUI}" "${WEBUI_DIR}"

# ---------------------------------------------------------------------------
# 6. systemd service — PHP built-in server bound to the wg0 IP only
# ---------------------------------------------------------------------------
log "Creating dns-vpn-ui systemd service (listening on ${WG_SERVER_IP}:${WEBUI_PORT})"
cat > /etc/systemd/system/dns-vpn-ui.service <<EOF
[Unit]
Description=DNS/VPN Stack Web UI
After=network-online.target wg-quick@${WG_IFACE}.service
Wants=network-online.target

[Service]
Type=simple
User=${SUDO_USER_FOR_WEBUI}
WorkingDirectory=${WEBUI_DIR}/webui
ExecStart=/usr/bin/php -S ${WG_SERVER_IP}:${WEBUI_PORT} -t ${WEBUI_DIR}/webui
Restart=always
RestartSec=3
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now dns-vpn-ui.service

# ---------------------------------------------------------------------------
# 7. Firewall — only SSH + WireGuard UDP port reachable from the internet.
#    DNS (53) and the web UI only listen on wg0, so UFW rules for them
#    are scoped to the tunnel subnet as defense in depth.
# ---------------------------------------------------------------------------
log "Configuring UFW"
ufw allow OpenSSH || true
ufw allow "${WG_PORT}/udp"
ufw allow from "${WG_SUBNET}" to any port 53
ufw allow from "${WG_SUBNET}" to any port "${WEBUI_PORT}"
ufw allow from "${WG_SUBNET}" to any port 80
ufw --force enable

# ---------------------------------------------------------------------------
# 8. Post-install health check — verifies every piece is actually working,
#    not just "systemctl enabled". Non-fatal: reports PASS/FAIL per check.
# ---------------------------------------------------------------------------
HC_FAILED=0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf "  \033[1;32m✔\033[0m %s\n" "$desc"
  else
    printf "  \033[1;31m✘\033[0m %s\n" "$desc"
    HC_FAILED=1
  fi
}

if [[ "$RUN_HEALTHCHECK" == "yes" ]]; then
  log "Running post-install health check"

  check "WireGuard interface ${WG_IFACE} is up"      bash -c "wg show '${WG_IFACE}'"
  check "Unbound service is active"                   systemctl is-active --quiet unbound
  check "Unbound resolves (via 127.0.0.1:${UNBOUND_PORT})" \
        bash -c "dig @127.0.0.1 -p ${UNBOUND_PORT} cloudflare.com +time=3 +tries=1 +short | grep -q ."
  check "Pi-hole FTL service is active"                systemctl is-active --quiet pihole-FTL
  check "Pi-hole resolves (via ${WG_SERVER_IP}:53)" \
        bash -c "dig @${WG_SERVER_IP} cloudflare.com +time=3 +tries=1 +short | grep -q ."
  ADMIN_UI_OK=0
  ADMIN_CODE="000"
  for i in 1 2 3; do
    ADMIN_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 -kL "http://${WG_SERVER_IP}/admin/" 2>/dev/null || echo "000")
    if echo "$ADMIN_CODE" | grep -qE '^(2|3|401)'; then ADMIN_UI_OK=1; break; fi
    sleep 2
  done
  if [[ "$ADMIN_UI_OK" -eq 1 ]]; then
    printf "  \033[1;32m✔\033[0m Pi-hole admin UI responds (${WG_SERVER_IP}:80)\n"
  else
    printf "  \033[1;31m✘\033[0m Pi-hole admin UI responds (${WG_SERVER_IP}:80) [HTTP %s]\n" "$ADMIN_CODE"
    HC_FAILED=1
  fi
  if [[ "$ADMIN_UI_OK" -eq 0 ]] && command -v pihole >/dev/null 2>&1; then
    # Known cause: the "web" component sometimes doesn't actually get
    # pulled to v6 alongside core/FTL, and 404s as a result.
    WEB_VER_LINE=$(pihole -v 2>/dev/null | grep -i '^Web version' || true)
    if [[ -n "$WEB_VER_LINE" ]]; then
      warn "Pi-hole reports: ${WEB_VER_LINE}"
      warn "If that shows v5.x while Core/FTL show v6.x, the web interface didn't"
      warn "actually update — run: sudo pihole -r  (choose Repair) to fix it."
    fi
  fi
  check "dns-vpn-ui service is active"                 systemctl is-active --quiet dns-vpn-ui
  check "Custom web UI responds (${WG_SERVER_IP}:${WEBUI_PORT})" \
        bash -c "curl -fsS -o /dev/null --max-time 3 http://${WG_SERVER_IP}:${WEBUI_PORT}/login.php"
  check "UFW is active"                                bash -c "ufw status | grep -q 'Status: active'"

  if [[ "$HC_FAILED" -eq 1 ]]; then
    echo -e "\n\033[1;33mOne or more checks failed — scroll up for details.\033[0m"
    echo "Common fixes: re-run 'sudo ./install.sh' (it's safe to re-run), or check"
    echo "'journalctl -u <service>' for the failing service."
  else
    echo -e "\n\033[1;32mAll checks passed — stack is fully operational.\033[0m"
  fi
fi

# ---------------------------------------------------------------------------
# 9. Auto-create a first WireGuard client and print its QR code right here
#    in the terminal, so you can scan-and-connect without opening the panel.
# ---------------------------------------------------------------------------
if [[ "$SKIP_FIRST_CLIENT" != "yes" ]]; then
  log "Creating first WireGuard client: ${FIRST_CLIENT_NAME}"
  if [[ -f "${WG_CLIENTS_DIR}/${FIRST_CLIENT_NAME}.conf" ]]; then
    echo "  Client '${FIRST_CLIENT_NAME}' already exists — skipping creation, showing its QR below."
  else
    SERVER_PUB_IP="${SERVER_PUB_IP}" "${WEBUI_DIR}/scripts/wg-add-client.sh" "${FIRST_CLIENT_NAME}" >/dev/null
  fi
  echo
  qrencode -t ansiutf8 < "${WG_CLIENTS_DIR}/${FIRST_CLIENT_NAME}.conf"
  echo "Scan the QR above in the WireGuard app, or import the file directly:"
  echo "  ${WG_CLIENTS_DIR}/${FIRST_CLIENT_NAME}.conf"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<SUMMARY

============================================================
  dns-vpn-stack installed
============================================================
  WireGuard endpoint : ${SERVER_PUB_IP}:${WG_PORT}
  WireGuard server pk: ${SERVER_PUB}
  WireGuard subnet    : ${WG_SUBNET}  (server ${WG_SERVER_IP})

  Custom Web UI (VPN-only) : https://${WG_SERVER_IP}:${WEBUI_PORT}
     -> connect WireGuard first, then open the URL above
  Web UI login             : ${ADMIN_USER} / ${ADMIN_PASS}

  Pi-hole admin (VPN-only) : http://${WG_SERVER_IP}/admin/
  Pi-hole password          : ${ADMIN_PASS}  (same as above)

  Add more WireGuard clients from the Web UI, or run:
    sudo ${WEBUI_DIR}/scripts/wg-add-client.sh <client-name>

  To remove everything this installer set up, run:
    sudo ./uninstall.sh

  Save this output — the password is not printed again.
============================================================
SUMMARY
