<?php
declare(strict_types=1);

function cfg(): array {
    static $c = null;
    if ($c === null) $c = require __DIR__ . '/../config.php';
    return $c;
}

/** True if $ip falls inside CIDR $cidr (IPv4 only). */
function ip_in_cidr(string $ip, string $cidr): bool {
    if (strpos($cidr, '/') === false) return $ip === $cidr;
    [$subnet, $bits] = explode('/', $cidr);
    $ipLong = ip2long($ip);
    $subLong = ip2long($subnet);
    if ($ipLong === false || $subLong === false) return false;
    $mask = -1 << (32 - (int)$bits);
    return ($ipLong & $mask) === ($subLong & $mask);
}

function client_ip(): string {
    return $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
}

function human_bytes(int $bytes): string {
    $units = ['B','KB','MB','GB','TB'];
    $i = 0;
    $val = (float)$bytes;
    while ($val >= 1024 && $i < count($units) - 1) { $val /= 1024; $i++; }
    return round($val, 1) . ' ' . $units[$i];
}

/** Run one of the whitelisted sudo wrapper scripts and return decoded JSON (or error array). */
function run_wrapper(string $script, array $args = []): array {
    $c = cfg();
    $path = __DIR__ . '/../../scripts/' . basename($script);
    $cmd = 'sudo ' . escapeshellarg($path);
    foreach ($args as $a) $cmd .= ' ' . escapeshellarg($a);
    $out = shell_exec($cmd . ' 2>&1');
    $decoded = json_decode((string)$out, true);
    if (!is_array($decoded)) {
        return ['error' => 'unexpected output', 'raw' => trim((string)$out)];
    }
    return $decoded;
}

function json_out(array $data, int $status = 200) {
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode($data);
    exit;
}
