<?php
declare(strict_types=1);
require_once __DIR__ . '/includes/auth.php';
require_login();
$c = cfg();
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DNS / VPN Stack</title>
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="topbar">
  <div class="brand">DNS <span>/</span> VPN Stack</div>
  <nav class="tabs">
    <button class="tab-btn active" data-tab="overview">Overview</button>
    <button class="tab-btn" data-tab="queries">DNS Queries</button>
    <button class="tab-btn" data-tab="clients">WireGuard Clients</button>
  </nav>
  <div class="topbar-right">
    <a href="<?= htmlspecialchars($c['pihole_admin_url']) ?>" target="_blank" rel="noopener">Pi-hole Admin ↗</a>
    <a href="/logout.php" class="logout">Logout</a>
  </div>
</header>

<main>

  <!-- ============ OVERVIEW ============ -->
  <section id="tab-overview" class="tab-panel active">
    <div class="grid stats-grid">
      <div class="card stat"><div class="stat-label">CPU</div><div class="stat-value" id="s-cpu">—</div>
        <div class="bar"><div class="bar-fill" id="b-cpu"></div></div></div>
      <div class="card stat"><div class="stat-label">Memory</div><div class="stat-value" id="s-mem">—</div>
        <div class="bar"><div class="bar-fill" id="b-mem"></div></div></div>
      <div class="card stat"><div class="stat-label">Disk</div><div class="stat-value" id="s-disk">—</div>
        <div class="bar"><div class="bar-fill" id="b-disk"></div></div></div>
      <div class="card stat"><div class="stat-label">Load Avg</div><div class="stat-value" id="s-load">—</div></div>
      <div class="card stat"><div class="stat-label">Uptime</div><div class="stat-value" id="s-uptime">—</div></div>
      <div class="card stat"><div class="stat-label">Network (rx / tx)</div><div class="stat-value" id="s-net">—</div></div>
      <div class="card stat"><div class="stat-label">WireGuard peers online</div><div class="stat-value" id="s-peers">—</div></div>
    </div>
  </section>

  <!-- ============ QUERIES ============ -->
  <section id="tab-queries" class="tab-panel">
    <div class="card">
      <div class="card-head">
        <h2>Live DNS Queries</h2>
        <span class="pulse-dot"></span>
        <span class="muted" id="q-status">streaming…</span>
      </div>
      <div class="table-wrap">
        <table id="q-table">
          <thead><tr><th>Time</th><th>Domain</th><th>Client</th><th>Status</th></tr></thead>
          <tbody></tbody>
        </table>
      </div>
    </div>
  </section>

  <!-- ============ CLIENTS ============ -->
  <section id="tab-clients" class="tab-panel">
    <div class="card">
      <div class="card-head">
        <h2>WireGuard Clients</h2>
        <form id="add-client-form">
          <input type="text" id="new-client-name" placeholder="client name, e.g. phone" required pattern="[a-zA-Z0-9_-]{1,32}">
          <button type="submit">+ Add client</button>
        </form>
      </div>
      <div id="add-client-msg" class="muted"></div>
      <div class="table-wrap">
        <table id="c-table">
          <thead><tr><th>Status</th><th>Name</th><th>IP</th><th>Last handshake</th><th>Data (rx/tx)</th><th></th></tr></thead>
          <tbody></tbody>
        </table>
      </div>
    </div>

    <div class="card" id="qr-card" style="display:none">
      <div class="card-head"><h2 id="qr-title">Client config</h2></div>
      <div class="qr-wrap">
        <img id="qr-img" alt="WireGuard QR code">
        <pre id="qr-conf"></pre>
      </div>
    </div>
  </section>

</main>

<script src="/assets/app.js"></script>
</body>
</html>
