<?php
declare(strict_types=1);
require_once __DIR__ . '/../includes/auth.php';
require_login();

// --- CPU load ---
$load = sys_getloadavg(); // [1m, 5m, 15m]

// --- CPU usage % (sample /proc/stat twice, 150ms apart) ---
function cpu_snapshot(): array {
    $line = trim((string)file_get_contents('/proc/stat'));
    $parts = preg_split('/\s+/', $line);
    // user nice system idle iowait irq softirq steal
    $vals = array_map('intval', array_slice($parts, 1, 8));
    $idle = $vals[3] + $vals[4];
    $total = array_sum($vals);
    return [$idle, $total];
}
[$idle1, $total1] = cpu_snapshot();
usleep(150000);
[$idle2, $total2] = cpu_snapshot();
$deltaIdle = $idle2 - $idle1;
$deltaTotal = $total2 - $total1;
$cpuPct = $deltaTotal > 0 ? round((1 - $deltaIdle / $deltaTotal) * 100, 1) : 0.0;

// --- Memory ---
$mem = [];
foreach (explode("\n", (string)file_get_contents('/proc/meminfo')) as $l) {
    if (preg_match('/^(\w+):\s+(\d+)/', $l, $m)) $mem[$m[1]] = (int)$m[2] * 1024;
}
$memTotal = $mem['MemTotal'] ?? 0;
$memAvail = $mem['MemAvailable'] ?? 0;
$memUsed = $memTotal - $memAvail;

// --- Disk (root fs) ---
$diskTotal = @disk_total_space('/') ?: 0;
$diskFree  = @disk_free_space('/') ?: 0;
$diskUsed  = $diskTotal - $diskFree;

// --- Uptime ---
$uptimeSeconds = 0;
if (preg_match('/^([\d.]+)/', (string)file_get_contents('/proc/uptime'), $m)) {
    $uptimeSeconds = (int)floatval($m[1]);
}

// --- Network (aggregate rx/tx bytes across interfaces, excluding lo) ---
$rx = 0; $tx = 0;
foreach (explode("\n", (string)@file_get_contents('/proc/net/dev')) as $l) {
    if (strpos($l, ':') === false) continue;
    [$iface, $rest] = explode(':', $l, 2);
    $iface = trim($iface);
    if ($iface === 'lo' || $iface === '') continue;
    $cols = preg_split('/\s+/', trim($rest));
    $rx += (int)($cols[0] ?? 0);
    $tx += (int)($cols[8] ?? 0);
}

// --- WireGuard peer count + last handshakes ---
$wgPeers = 0;
$wgOut = @shell_exec('wg show ' . escapeshellarg(cfg()['wg_iface']) . ' peers 2>/dev/null');
if ($wgOut) $wgPeers = count(array_filter(explode("\n", trim($wgOut))));

json_out([
    'load'        => $load,
    'cpu_pct'     => $cpuPct,
    'mem_total'   => $memTotal,
    'mem_used'    => $memUsed,
    'mem_pct'     => $memTotal > 0 ? round($memUsed / $memTotal * 100, 1) : 0,
    'disk_total'  => $diskTotal,
    'disk_used'   => $diskUsed,
    'disk_pct'    => $diskTotal > 0 ? round($diskUsed / $diskTotal * 100, 1) : 0,
    'uptime_sec'  => $uptimeSeconds,
    'net_rx'      => $rx,
    'net_tx'      => $tx,
    'wg_peers'    => $wgPeers,
    'human'       => [
        'mem_used'  => human_bytes($memUsed) . ' / ' . human_bytes($memTotal),
        'disk_used' => human_bytes($diskUsed) . ' / ' . human_bytes($diskTotal),
        'net_rx'    => human_bytes($rx),
        'net_tx'    => human_bytes($tx),
    ],
]);
