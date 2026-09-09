<?php
declare(strict_types=1);
require_once __DIR__ . '/vpn_check.php';

$c = cfg();
session_name($c['session_name']);
session_set_cookie_params(['httponly' => true, 'samesite' => 'Strict']);
session_start();

function require_login(): void {
    if (empty($_SESSION['authed'])) {
        header('Location: /login.php');
        exit;
    }
}

function current_user(): ?string {
    return $_SESSION['user'] ?? null;
}
