<?php
declare(strict_types=1);
require_once __DIR__ . '/../includes/auth.php';
require_login();

$c = cfg();
$dbPath = $c['pihole_db'];
$sinceId = isset($_GET['since_id']) ? (int)$_GET['since_id'] : 0;
$limit = min(200, max(1, (int)($_GET['limit'] ?? 50)));

if (!is_file($dbPath)) {
    json_out(['queries' => [], 'max_id' => $sinceId, 'error' => 'pihole-FTL.db not found']);
}

try {
    // Read-only connection; Pi-hole FTL owns write access.
    $pdo = new PDO('sqlite:' . $dbPath, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $pdo->exec('PRAGMA query_only = ON;');

    if ($sinceId > 0) {
        $stmt = $pdo->prepare(
            'SELECT id, timestamp, type, domain, client, status
             FROM queries WHERE id > :sid ORDER BY id ASC LIMIT :lim'
        );
        $stmt->bindValue(':sid', $sinceId, PDO::PARAM_INT);
    } else {
        $stmt = $pdo->prepare(
            'SELECT id, timestamp, type, domain, client, status
             FROM queries ORDER BY id DESC LIMIT :lim'
        );
    }
    $stmt->bindValue(':lim', $limit, PDO::PARAM_INT);
    $stmt->execute();
    $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);
    if ($sinceId === 0) $rows = array_reverse($rows);

    $statusMap = [
        1 => 'blocked (gravity)', 2 => 'forwarded', 3 => 'cached',
        4 => 'blocked (wildcard)', 5 => 'blocked (blacklist)', 6 => 'blocked (upstream)',
        9 => 'blocked (gravity+CNAME)', 10 => 'blocked (regex)', 11 => 'blocked (denylist)',
    ];
    $out = array_map(function ($r) use ($statusMap) {
        $r['status_label'] = $statusMap[(int)$r['status']] ?? ('status ' . $r['status']);
        $r['blocked'] = in_array((int)$r['status'], [1, 4, 5, 6, 9, 10, 11], true);
        $r['time'] = date('H:i:s', (int)$r['timestamp']);
        return $r;
    }, $rows);

    $maxId = $out ? (int)end($out)['id'] : $sinceId;
    json_out(['queries' => $out, 'max_id' => $maxId]);
} catch (Throwable $e) {
    json_out(['queries' => [], 'max_id' => $sinceId, 'error' => 'db read failed'], 500);
}
