(() => {
  // ---------- Tabs ----------
  const tabBtns = document.querySelectorAll('.tab-btn');
  const panels = document.querySelectorAll('.tab-panel');
  tabBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      tabBtns.forEach(b => b.classList.remove('active'));
      panels.forEach(p => p.classList.remove('active'));
      btn.classList.add('active');
      document.getElementById('tab-' + btn.dataset.tab).classList.add('active');
    });
  });

  const fmtSecs = (s) => {
    const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    if (d > 0) return `${d}d ${h}h`;
    if (h > 0) return `${h}h ${m}m`;
    return `${m}m`;
  };
  const fmtAgo = (ts) => {
    if (!ts) return 'never';
    const secs = Math.floor(Date.now() / 1000) - ts;
    if (secs < 5) return 'just now';
    if (secs < 60) return secs + 's ago';
    if (secs < 3600) return Math.floor(secs / 60) + 'm ago';
    return Math.floor(secs / 3600) + 'h ago';
  };

  // ---------- Overview polling ----------
  async function pollStats() {
    try {
      const r = await fetch('/api/vps_info.php', { cache: 'no-store' });
      if (!r.ok) return;
      const d = await r.json();
      document.getElementById('s-cpu').textContent = d.cpu_pct + '%';
      document.getElementById('b-cpu').style.width = d.cpu_pct + '%';
      document.getElementById('s-mem').textContent = d.mem_pct + '%';
      document.getElementById('b-mem').style.width = d.mem_pct + '%';
      document.getElementById('s-disk').textContent = d.disk_pct + '%';
      document.getElementById('b-disk').style.width = d.disk_pct + '%';
      document.getElementById('s-load').textContent = d.load.map(x => x.toFixed(2)).join(' / ');
      document.getElementById('s-uptime').textContent = fmtSecs(d.uptime_sec);
      document.getElementById('s-net').textContent = `${d.human.net_rx} / ${d.human.net_tx}`;
      document.getElementById('s-peers').textContent = d.wg_peers;
    } catch (e) { console.error('vps_info poll failed:', e); }
  }
  pollStats();
  setInterval(pollStats, 3000);

  // ---------- Live DNS queries ----------
  let lastId = 0;
  const qBody = document.querySelector('#q-table tbody');
  const qStatus = document.getElementById('q-status');
  const MAX_ROWS = 100;

  async function pollQueries() {
    try {
      const url = lastId ? `/api/queries.php?since_id=${lastId}` : '/api/queries.php?limit=50';
      const r = await fetch(url, { cache: 'no-store' });
      let d;
      try { d = await r.json(); } catch (parseErr) { d = null; }
      if (!r.ok) {
        qStatus.textContent = (d && d.error) ? d.error : `error (HTTP ${r.status})`;
        return;
      }
      if (!d) { qStatus.textContent = 'error (bad response)'; return; }
      qStatus.textContent = d.error ? d.error : 'streaming…';
      if (d.queries && d.queries.length) {
        for (const q of d.queries) {
          const tr = document.createElement('tr');
          tr.className = q.blocked ? 'blocked' : 'allowed';
          tr.innerHTML = `<td>${q.time}</td><td>${escapeHtml(q.domain)}</td><td>${escapeHtml(q.client)}</td><td class="status">${escapeHtml(q.status_label)}</td>`;
          qBody.prepend(tr);
        }
        while (qBody.children.length > MAX_ROWS) qBody.removeChild(qBody.lastChild);
        lastId = d.max_id;
      }
    } catch (e) { qStatus.textContent = 'connection lost, retrying…'; }
  }
  function escapeHtml(s) {
    return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }
  pollQueries();
  setInterval(pollQueries, 2000);

  // ---------- WireGuard clients ----------
  const cBody = document.querySelector('#c-table tbody');
  async function loadClients() {
    try {
      const r = await fetch('/api/wg_clients.php', { cache: 'no-store' });
      const d = await r.json();
      cBody.innerHTML = '';
      (d.clients || []).forEach(c => {
        const tr = document.createElement('tr');
        tr.innerHTML = `
          <td><span class="dot ${c.online ? 'on' : 'off'}"></span>${c.online ? 'online' : 'offline'}</td>
          <td>${escapeHtml(c.name)}</td>
          <td>${escapeHtml(c.ip)}</td>
          <td>${fmtAgo(c.last_handshake)}</td>
          <td>${humanBytes(c.rx)} / ${humanBytes(c.tx)}</td>
          <td>
            <button class="btn-link" data-view="${escapeHtml(c.name)}">QR / config</button>
            <button class="btn-icon" data-remove="${escapeHtml(c.name)}">Remove</button>
          </td>`;
        cBody.appendChild(tr);
      });
    } catch (e) { console.error('load clients failed:', e); }
  }
  function humanBytes(b) {
    const u = ['B','KB','MB','GB','TB']; let i = 0; let v = Number(b) || 0;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return v.toFixed(1) + ' ' + u[i];
  }
  loadClients();
  setInterval(loadClients, 5000);

  document.getElementById('add-client-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const nameInput = document.getElementById('new-client-name');
    const name = nameInput.value.trim();
    const msg = document.getElementById('add-client-msg');
    msg.textContent = 'Generating keys…';
    try {
      const r = await fetch('/api/wg_clients.php', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'add', name })
      });
      const d = await r.json();
      if (!r.ok || d.error) { msg.textContent = 'Error: ' + (d.error || 'failed'); return; }
      msg.textContent = `Client "${name}" added.`;
      nameInput.value = '';
      loadClients();
      if (d.client && d.client.qr_png_b64) showQr(name, d.client.qr_png_b64, null);
      else viewClient(name);
    } catch (err) { msg.textContent = 'Request failed.'; }
  });

  cBody?.addEventListener('click', async (e) => {
    const removeName = e.target.getAttribute('data-remove');
    const viewName = e.target.getAttribute('data-view');
    if (removeName) {
      if (!confirm(`Remove client "${removeName}"? This immediately revokes its access.`)) return;
      await fetch('/api/wg_clients.php', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'remove', name: removeName })
      });
      loadClients();
      document.getElementById('qr-card').style.display = 'none';
    }
    if (viewName) viewClient(viewName);
  });

  async function viewClient(name) {
    try {
      const r = await fetch('/api/wg_clients.php', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'config', name })
      });
      const d = await r.json();
      if (d.error) return;
      showQr(name, null, d.config);
    } catch (e) { console.error('view client failed:', e); }
  }

  function showQr(name, qrB64, confText) {
    const card = document.getElementById('qr-card');
    document.getElementById('qr-title').textContent = `Client config — ${name}`;
    const img = document.getElementById('qr-img');
    if (qrB64) { img.src = 'data:image/png;base64,' + qrB64; img.style.display = ''; }
    else { img.style.display = 'none'; }
    document.getElementById('qr-conf').textContent = confText || '(scan the QR code in your WireGuard app)';
    card.style.display = '';
    card.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }
})();
