#!/usr/bin/env bash
#
# dns-vpn-stack uninstaller
# Reverses everything install.sh did. Safe to run even if install was partial.
#
set -uo pipefail

WG_IFACE="${WG_IFACE:-wg0}"
WG_DIR="/etc/wireguard"
WG_CLIENTS_DIR="${WG_CLIENTS_DIR:-/etc/wireguard-clients}"
WEBUI_DIR="/opt/dns-vpn-ui"

if [[ $EUID -ne 0 ]]; then
  echo "Run this as root (sudo bash uninstall.sh)"; exit 1
fi

PURGE_PACKAGES="no"
KEEP_CONFIGS="no"
for arg in "$@"; do
  case "$arg" in
    --purge-packages) PURGE_PACKAGES="yes" ;;
    --keep-configs)   KEEP_CONFIGS="yes" ;;
    -y|--yes)         ASSUME_YES="yes" ;;
    -h|--help)
      cat <<EOF
Usage: sudo ./uninstall.sh [options]

  --purge-packages   Also apt-remove wireguard, unbound, pi-hole and PHP
                      packages this stack installed (leaves other apps alone
                      only if you didn't rely on the same packages elsewhere).
  --keep-configs     Keep /etc/wireguard client configs and Pi-hole's own
                      data (blocklists, query history) instead of deleting.
  -y, --yes          Don't prompt for confirmation.
EOF
      exit 0 ;;
  esac
done

log() { echo -e "\n\033[1;33m==> $*\033[0m"; }
warn() { echo -e "\033[1;31m! $*\033[0m"; }

if [[ "${ASSUME_YES:-no}" != "yes" ]]; then
  echo "This will stop and remove:"
  echo "  - dns-vpn-ui service + files ($WEBUI_DIR)"
  echo "  - WireGuard interface ${WG_IFACE} + all client configs ($WG_DIR)"
  echo "  - Pi-hole (full uninstall)"
  echo "  - Unbound config added by this stack"
  echo "  - UFW rules added by this stack"
  [[ "$PURGE_PACKAGES" == "yes" ]] && echo "  - the underlying packages (--purge-packages)"
  read -rp "Continue? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# 1. Web UI
# ---------------------------------------------------------------------------
log "Removing custom web UI"
systemctl disable --now dns-vpn-ui.service 2>/dev/null || true
rm -f /etc/systemd/system/dns-vpn-ui.service
rm -f /etc/sudoers.d/dns-vpn-ui
[[ "$KEEP_CONFIGS" == "yes" ]] || rm -rf "$WEBUI_DIR"
systemctl daemon-reload

# ---------------------------------------------------------------------------
# 2. Pi-hole
# ---------------------------------------------------------------------------
log "Uninstalling Pi-hole"
export DEBIAN_FRONTEND=noninteractive
if command -v pihole >/dev/null 2>&1; then
  # Pi-hole's own uninstaller asks an interactive [Y/n] confirmation that
  # --unattended does NOT suppress, so with no TTY input it just hangs.
  # `yes |` auto-answers it; `timeout` is a hard safety net either way.
  if ! yes | timeout 240 pihole uninstall >/tmp/pihole-uninstall.log 2>&1; then
    warn "Pi-hole's own uninstaller didn't finish cleanly (see /tmp/pihole-uninstall.log)."
    warn "Continuing with manual cleanup of its files."
  fi
fi
systemctl disable --now pihole-FTL 2>/dev/null || true
systemctl disable --now lighttpd 2>/dev/null || true
if [[ "$KEEP_CONFIGS" != "yes" ]]; then
  rm -rf /etc/pihole /etc/.pihole /opt/pihole /etc/dnsmasq.d /var/log/pihole* \
         /usr/local/bin/pihole /usr/bin/pihole-FTL /etc/lighttpd \
         /etc/cron.d/pihole /var/www/html/admin 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 3. Unbound
# ---------------------------------------------------------------------------
log "Removing Unbound config for this stack"
rm -f /etc/unbound/unbound.conf.d/dns-vpn-stack.conf
systemctl restart unbound 2>/dev/null || true
if [[ "$PURGE_PACKAGES" == "yes" ]]; then
  systemctl disable --now unbound 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. WireGuard
# ---------------------------------------------------------------------------
log "Tearing down WireGuard"
systemctl disable --now "wg-quick@${WG_IFACE}" 2>/dev/null || wg-quick down "${WG_IFACE}" 2>/dev/null || true
if [[ "$KEEP_CONFIGS" == "yes" ]]; then
  echo "  Keeping ${WG_DIR} and ${WG_CLIENTS_DIR} (client configs preserved)."
else
  rm -rf "$WG_DIR" "$WG_CLIENTS_DIR"
fi

# ---------------------------------------------------------------------------
# 5. Firewall rules added by install.sh
# ---------------------------------------------------------------------------
log "Removing UFW rules added by this stack"
if command -v ufw >/dev/null 2>&1; then
  # Remove rules referencing the tunnel subnet or the WG port; leaves SSH/other rules intact.
  ufw status numbered 2>/dev/null | grep -E "51820/udp|10\.66\.0\.0/24" | \
    awk -F'[][]' '{print $2}' | sort -rn | while read -r n; do
      [[ -n "$n" ]] && yes | ufw delete "$n" >/dev/null 2>&1 || true
    done
fi

# ---------------------------------------------------------------------------
# 6. sysctl
# ---------------------------------------------------------------------------
sed -i '/^net.ipv4.ip_forward=1$/d' /etc/sysctl.conf 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Packages (optional)
# ---------------------------------------------------------------------------
if [[ "$PURGE_PACKAGES" == "yes" ]]; then
  log "Purging packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y wireguard wireguard-tools unbound unbound-anchor \
    php-cli php-sqlite3 qrencode 2>/dev/null || true
  apt-get autoremove -y || true
fi

cat <<DONE

============================================================
  dns-vpn-stack removed.
$( [[ "$KEEP_CONFIGS" == "yes" ]] && echo "  WireGuard/Pi-hole data was kept (--keep-configs)." )
$( [[ "$PURGE_PACKAGES" != "yes" ]] && echo "  Packages (wireguard, unbound, php, qrencode) were left installed." )
  UFW is still enabled — check 'ufw status' if you want to disable it too.
============================================================
DONE
