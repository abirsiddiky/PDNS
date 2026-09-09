#!/usr/bin/env bash
# Prints `wg show <iface> dump` raw output (tab-separated). Invoked via sudo by the web UI.
set -euo pipefail
WG_IFACE="wg0"
wg show "$WG_IFACE" dump 2>/dev/null || true
