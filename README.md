# dns-vpn-stack

One-click WireGuard + Unbound + Pi-hole personal DNS stack, with a
password-protected, VPN-only PHP web UI on top (live DNS query log,
WireGuard client manager with QR codes, live VPS stats).

```
Android/Laptop --WireGuard(UDP 51820)--> VPS
                                           wg0 10.66.0.1/24
                                             │
                                       Pi-hole :53 (+ web UI :80, VPN-only)
                                             │  blocklists
                                             ▼
                                       Unbound 127.0.0.1:5335 (recursive)
                                             │
                                        DNS root hierarchy
```

Custom panel: `https://10.66.0.1:8443` — only reachable once you're
connected to the WireGuard tunnel, because the PHP server binds to the
tunnel IP only (plus an app-level IP allowlist + login as defense in depth).

## Install (on a fresh Debian/Ubuntu VPS, as root)

```bash
git clone <this-repo> dns-vpn-stack   # or just upload the folder
cd dns-vpn-stack
chmod +x install.sh scripts/*.sh scripts/*.py
sudo ./install.sh
```

Optional overrides (env vars before the command):

```bash
sudo WG_PORT=51999 ADMIN_USER=abir WEBUI_PORT=9443 ./install.sh
```

The installer finishes with three things automatically:
1. **Health check** — verifies WireGuard is up, Unbound resolves,
   Pi-hole resolves + its admin UI responds, the custom panel service
   is active and answering HTTP, and UFW is active. Each line prints
   ✔/✘; failures are reported but don't abort the install (safe to
   re-run `./install.sh` afterward). Skip with `RUN_HEALTHCHECK=no`.
2. **First client, auto-created** — a client named `first-client` is
   generated and its **QR code is printed directly in the terminal**
   (`qrencode -t ansiutf8`) so you can scan-and-connect immediately,
   no need to open the panel first. Skip with `SKIP_FIRST_CLIENT=yes`,
   or change the name with `FIRST_CLIENT_NAME=phone`.
3. **Summary** — WireGuard server public key + endpoint, Web UI URL +
   admin login, Pi-hole admin URL + password.

**Save that output — the generated password is not printed again**
(though you can always reset it: `pihole -a -p` for Pi-hole, and
re-run `php -r "echo password_hash('newpass', PASSWORD_BCRYPT);"` then
paste the hash into `webui/config.php` for the custom panel).

## Adding a client

Either use the "+ Add client" box in the **WireGuard Clients** tab
(shows a QR code immediately), or from the shell:

```bash
sudo /opt/dns-vpn-ui/scripts/wg-add-client.sh phone
cat /etc/wireguard-clients/phone.conf   # import this into the WireGuard app
```

## Uninstall

```bash
sudo ./uninstall.sh                 # prompts for confirmation, keeps packages installed
sudo ./uninstall.sh -y              # no prompt
sudo ./uninstall.sh --keep-configs  # remove services/panel but keep WireGuard client configs + Pi-hole data
sudo ./uninstall.sh --purge-packages -y   # also apt-remove wireguard/unbound/pi-hole/php/qrencode
```

Removes: the `dns-vpn-ui` service + `/opt/dns-vpn-ui`, WireGuard
interface + `/etc/wireguard` (all client configs), Pi-hole (its own
uninstaller), the Unbound config this stack added, the UFW rules this
stack added, and the `net.ipv4.ip_forward` line it appended to
`sysctl.conf`. UFW itself is left enabled (other rules like SSH stay).

## Permission model (why the panel can read what it reads)

- `/etc/wireguard` stays `chmod 700`, root-only — it holds the server
  private key and every peer's preshared key (`wg0.conf`). The web UI
  never reads this directory directly; peer status comes only through
  the whitelisted `wg-status.sh` sudo wrapper.
- Client `.conf` files (each containing only *that* client's own keys)
  live in a separate `/etc/wireguard-clients/` directory instead,
  `chmod 750` and group-owned by the web UI user (`www-data` by
  default) — so the panel can read them to show QR codes / downloads,
  without weakening `/etc/wireguard` itself.
- The web UI user is added to the `pihole` group so it can read
  `pihole-FTL.db` (read-only, `PRAGMA query_only`) for the live query
  log, without needing Pi-hole's API token.

## Requirements

- Debian 11/12 or Ubuntu 20.04/22.04/24.04, root access.
- Works with whatever PHP version the distro's `php-cli` package
  installs (7.4 through 8.3 all tested paths) — the web UI avoids
  PHP 8-only syntax on purpose for that reason.

## What's actually running

| Component | Bind address | Notes |
|---|---|---|
| `wg-quick@wg0` | UDP 51820 (public) | tunnel: 10.66.0.0/24 |
| Unbound | 127.0.0.1:5335 | recursive resolver, DNSSEC-capable, root hints |
| Pi-hole FTL (dnsmasq) | wg0 IP :53 | upstream = Unbound; only reachable through the tunnel |
| Pi-hole lighttpd admin | wg0 IP :80 | Pi-hole's own full-feature dashboard |
| Custom PHP panel | wg0 IP :8443 | `dns-vpn-ui.service` (systemd), `php -S` |

## Security model

- The web UI and Pi-hole's own admin UI are bound to the WireGuard
  interface's IP, not `0.0.0.0` — so nothing on the public internet
  can even open a TCP connection to them, regardless of app-level
  checks.
- `includes/vpn_check.php` re-checks the source IP against the tunnel
  subnet on every request — useful if you ever move this behind a
  reverse proxy later.
- Login uses `password_hash`/`password_verify` (bcrypt) + PHP
  sessions, with a simple file-based lockout after 5 failed attempts
  from the same IP.
- The web server user (`www-data`) is **not** given general root —
  only `sudo` rights to three specific, argument-validated scripts
  (`wg-add-client.sh`, `wg-remove-client.sh`, `wg-status.sh`), set up
  via `/etc/sudoers.d/dns-vpn-ui`.
- UFW only opens SSH and the WireGuard UDP port to the public
  internet; DNS/web-UI ports are additionally scoped to the tunnel
  subnet.

## Files

```
install.sh                  # one-click installer
scripts/
  wg-add-client.sh           # generates keys, appends peer, live-syncs wg0, returns config+QR
  wg-remove-client.sh        # removes a peer by name, live-syncs wg0
  wg-status.sh               # `wg show wg0 dump`, used by the panel for online/offline + traffic
  _strip_peer.py             # helper used by wg-remove-client.sh
webui/
  index.php                  # dashboard (tabs: Overview / DNS Queries / WireGuard Clients)
  login.php / logout.php
  config.example.php         # reference only — install.sh writes the real config.php
  includes/
    auth.php                 # session guard
    vpn_check.php             # source-IP allowlist
    functions.php             # helpers (cidr check, sudo wrapper runner, byte formatting)
  api/
    vps_info.php               # CPU/mem/disk/net/uptime/peer-count, polled every 3s
    queries.php                 # tails Pi-hole's pihole-FTL.db, polled every 2s (since_id cursor)
    wg_clients.php               # list/add/remove/get-config for WireGuard peers
  assets/
    style.css / app.js
```

## Notes / things you may want to change

- The custom panel currently talks to Pi-hole's SQLite DB directly
  (read-only `PRAGMA query_only`), not through Pi-hole's API — this
  avoids needing Pi-hole's API token and keeps things fast, but means
  it's tied to the `queries` table schema of the installed FTL version.
- "Realtime" here means short-interval polling (2–3s), not
  WebSockets/SSE — simplest thing that works reliably behind
  `php -S`. If you want push updates instead, swap `dns-vpn-ui.service`
  to run under PHP-FPM + nginx and add an SSE endpoint.
- TLS: the panel is served plain HTTP over the WireGuard tunnel
  (already encrypted at the WireGuard layer). If you want HTTPS on
  top too, put nginx in front with a self-signed cert bound to the
  wg0 IP.
