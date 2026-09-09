<?php
declare(strict_types=1);
require_once __DIR__ . '/includes/vpn_check.php';

$c = cfg();
session_name($c['session_name']);
session_set_cookie_params(['httponly' => true, 'samesite' => 'Strict']);
session_start();

if (!empty($_SESSION['authed'])) {
    header('Location: /index.php');
    exit;
}

$error = '';
$lockFile = sys_get_temp_dir() . '/dnsvpnui_fail_' . md5(client_ip());

$fails = 0;
if (is_file($lockFile)) {
    $data = json_decode((string)file_get_contents($lockFile), true) ?: [];
    $fails = (int)($data['n'] ?? 0);
    $last = (int)($data['t'] ?? 0);
    if ($fails >= 5 && (time() - $last) < 300) {
        $error = 'Too many attempts. Try again in a few minutes.';
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $error === '') {
    $user = trim((string)($_POST['username'] ?? ''));
    $pass = (string)($_POST['password'] ?? '');
    if (hash_equals($c['admin_user'], $user) && password_verify($pass, $c['admin_hash'])) {
        session_regenerate_id(true);
        $_SESSION['authed'] = true;
        $_SESSION['user'] = $user;
        @unlink($lockFile);
        header('Location: /index.php');
        exit;
    }
    $fails++;
    file_put_contents($lockFile, json_encode(['n' => $fails, 't' => time()]));
    $error = 'Invalid username or password.';
}
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in — DNS/VPN Stack</title>
<link rel="stylesheet" href="/assets/style.css">
</head>
<body class="login-body">
  <div class="login-card">
    <h1>DNS / VPN Stack</h1>
    <p class="muted">Sign in — connected via WireGuard from <?= htmlspecialchars(client_ip()) ?></p>
    <?php if ($error): ?>
      <div class="alert"><?= htmlspecialchars($error) ?></div>
    <?php endif; ?>
    <form method="post" autocomplete="off">
      <label>Username
        <input type="text" name="username" required autofocus>
      </label>
      <label>Password
        <input type="password" name="password" required>
      </label>
      <button type="submit">Sign in</button>
    </form>
  </div>
</body>
</html>
