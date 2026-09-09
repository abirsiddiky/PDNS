<?php
declare(strict_types=1);
require_once __DIR__ . '/../includes/auth.php';
require_login();

$c = cfg();
$method = $_SERVER['REQUEST_METHOD'];

function list_clients(array $c): array {
    $clients = [];
    $dir = $c['wg_clients_dir'];
    $handshakes = []; // pubkey => last handshake unix ts / transfer
    $scriptPath = __DIR__ . '/../../scripts/wg-status.sh';
    $dump = @shell_exec('sudo -n ' . escapeshellarg($scriptPath) . ' 2>/dev/null');
    if ($dump) {
        foreach (explode("\n", trim($dump)) as $i => $line) {
            if ($i === 0) continue; // header/interface line
            $cols = explode("\t", $line);
            if (count($cols) < 8) continue;
            [$pubkey, , , , $latestHandshake, $rx, $tx] = $cols;
            $handshakes[$pubkey] = ['handshake' => (int)$latestHandshake, 'rx' => (int)$rx, 'tx' => (int)$tx];
        }
    }
    if (is_dir($dir)) {
        foreach (glob($dir . '/*.conf') as $file) {
            $name = basename($file, '.conf');
            $body = (string)file_get_contents($file);
            preg_match('/Address\s*=\s*([\d.]+)/', $body, $m1);
            preg_match('/^PrivateKey\s*=\s*(.+)$/m', $body, $m2);
            $pub = isset($m2[1]) ? trim((string)shell_exec('echo ' . escapeshellarg(trim($m2[1])) . ' | wg pubkey')) : '';
            $hs = $handshakes[$pub] ?? null;
            $clients[] = [
                'name' => $name,
                'ip' => $m1[1] ?? '?',
                'public_key' => $pub,
                'last_handshake' => $hs['handshake'] ?? 0,
                'online' => $hs && $hs['handshake'] > 0 && (time() - $hs['handshake']) < 180,
                'rx' => $hs['rx'] ?? 0,
                'tx' => $hs['tx'] ?? 0,
            ];
        }
    }
    usort($clients, fn($a, $b) => strcmp($a['name'], $b['name']));
    return $clients;
}

if ($method === 'GET') {
    json_out(['clients' => list_clients($c)]);
}

if ($method === 'POST') {
    $body = json_decode((string)file_get_contents('php://input'), true) ?: $_POST;
    $action = $body['action'] ?? '';

    if ($action === 'add') {
        $name = trim((string)($body['name'] ?? ''));
        if (!preg_match('/^[a-zA-Z0-9_-]{1,32}$/', $name)) {
            json_out(['error' => 'Name must be 1-32 chars: letters, numbers, - or _'], 422);
        }
        $result = run_wrapper('wg-add-client.sh', [$name]);
        if (isset($result['error'])) json_out($result, 400);
        json_out(['ok' => true, 'client' => $result]);
    }

    if ($action === 'remove') {
        $name = trim((string)($body['name'] ?? ''));
        if (!preg_match('/^[a-zA-Z0-9_-]{1,32}$/', $name)) {
            json_out(['error' => 'invalid name'], 422);
        }
        $result = run_wrapper('wg-remove-client.sh', [$name]);
        if (isset($result['error'])) json_out($result, 400);
        json_out(['ok' => true]);
    }

    if ($action === 'config') {
        $name = trim((string)($body['name'] ?? ''));
        $file = $c['wg_clients_dir'] . '/' . basename($name) . '.conf';
        if (!preg_match('/^[a-zA-Z0-9_-]{1,32}$/', $name) || !is_file($file)) {
            json_out(['error' => 'not found'], 404);
        }
        json_out(['name' => $name, 'config' => file_get_contents($file)]);
    }

    json_out(['error' => 'unknown action'], 400);
}

json_out(['error' => 'method not allowed'], 405);
