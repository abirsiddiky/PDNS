<?php
declare(strict_types=1);
require_once __DIR__ . '/functions.php';

$c = cfg();
if (!ip_in_cidr(client_ip(), $c['allowed_cidr'])) {
    http_response_code(403);
    header('Content-Type: text/plain');
    echo "403 Forbidden\nThis panel is only reachable while connected to the WireGuard VPN.";
    exit;
}
