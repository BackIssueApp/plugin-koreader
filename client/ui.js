// KOReader client UI — a card on the core Profile page: download the device
// plugin (with this server's address inside), the three steps to install it,
// the devices that have synced with their plugin version, and reading time
// uploaded from them. Reuses core CSS classes.
(function () {
  window.BackIssue.registerClient((api) => {
    const NS = 'koreader.';
    const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const fill = (s, p) => (p ? String(s).replace(/\{(\w+)\}/g, (m, k) => (p[k] === undefined || p[k] === null ? m : String(p[k]))) : String(s));
    const tr = (key, en, params) => { if (typeof api.t !== 'function') return fill(en, params); const v = api.t(NS + key, params); return v === NS + key ? fill(en, params) : v; };
    const trh = (key, en, params) => {
      if (typeof api.th === 'function' && api.t(NS + key) !== NS + key) return api.th(NS + key, params);
      const tokens = params ? Object.fromEntries(Object.keys(params).map((k) => [k, '\u0000' + k + '\u0000'])) : undefined;
      let html = esc(fill(en, tokens)).replace(/&lt;(\/?)(b|i|em|strong|code|br|kbd)&gt;/g, '<$1$2>');
      if (params) for (const [k, v] of Object.entries(params)) html = html.split('\u0000' + k + '\u0000').join(esc(v ?? ''));
      return html;
    };
    const te = (key, en, params) => esc(tr(key, en, params));

    if (typeof api.can === 'function' && !api.can('koreader.use')) return;
    const slot = api.slot('profile-plugin-slot');
    if (!slot || slot.querySelector('#koreader-profile')) return;

    const duration = (seconds) => {
      const m = Math.round((Number(seconds) || 0) / 60);
      const h = Math.floor(m / 60);
      return h > 0 ? tr('hoursMinutes', '{h} h {m} min', { h, m: m % 60 }) : tr('minutes', '{m} min', { m });
    };
    const when = (iso) => {
      if (!iso) return '';
      const d = new Date(iso);
      return Number.isNaN(d.getTime()) ? '' : d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
    };

    const card = document.createElement('section');
    card.className = 'settings-section';
    card.id = 'koreader-profile';
    card.innerHTML =
      '<p class="modal__subhead">' + te('title', 'KOReader') + '</p>' +
      '<p class="modal__note">' + te('intro', 'Read your Books library on a Kobo, Kindle or other e-reader running KOReader: browse and download books from the device, and keep your place, finished status, highlights and reading time in sync with the browser and the apps.') + '</p>' +
      '<ol class="koreader-steps">' +
        '<li>' + trh('step1', 'Download the plugin and copy the <code>backissue.koplugin</code> folder from the zip into KOReader\'s <code>plugins</code> folder on the device, then restart KOReader.') + '</li>' +
        '<li>' + trh('step2', 'In KOReader open the top menu, then <b>Tools</b> → <b>BackIssue</b>. The server address is already filled in; paste a personal key from <b>API key</b> on this page.') + '</li>' +
        '<li>' + trh('step3', 'Use <b>Browse library</b> to download books. Positions, highlights and reading statistics sync as you open and close books; <b>Sync all books</b> catches up older ones, and each kind of sync can be switched off there.') + '</li>' +
      '</ol>' +
      '<div class="koreader-actions">' +
        '<a id="koreader-download" class="btn btn--sm" href="/api/koreader/plugin.zip" download="backissue.koplugin.zip">' + te('download', 'Download the KOReader plugin') + '</a>' +
      '</div>' +
      '<div class="koreader-devices"><p class="koreader-h">' + te('devices', 'Devices') + '</p><div class="koreader-devices-list"></div></div>' +
      '<div class="koreader-stats"><p class="koreader-h">' + te('readingTime', 'Reading time on KOReader') + '</p><div class="koreader-stats-body"></div></div>';
    slot.appendChild(card);

    const devicesEl = card.querySelector('.koreader-devices-list');
    const statsEl = card.querySelector('.koreader-stats-body');

    const renderDevices = (devices, offered) => {
      if (!devices.length) {
        devicesEl.innerHTML = '<p class="modal__note">' + te('noDevices', 'No device has connected yet.') + '</p>';
        return;
      }
      devicesEl.replaceChildren(...devices.map((d) => {
        const row = document.createElement('div');
        row.className = 'koreader-device';
        const current = !offered || !d.plugin_version || d.plugin_version === offered;
        row.innerHTML =
          '<div class="koreader-device-main">' +
            '<span class="koreader-device-name">' + esc(d.name || d.device_id) + '</span>' +
            (d.plugin_version
              ? ' <span class="koreader-badge' + (current ? '' : ' koreader-badge--warn') + '">' +
                  te('pluginVersion', 'Plugin {version}', { version: d.plugin_version }) + ' · ' +
                  (current ? te('upToDate', 'up to date') : te('updateAvailable', '{version} available, use Check for plugin update on the device', { version: offered })) +
                '</span>'
              : '') +
          '</div>' +
          '<div class="koreader-device-sub">' +
            esc(tr('lastSeen', 'Last seen {when}', { when: when(d.last_seen) })) +
            (d.last_book ? ' · ' + esc(tr('lastBook', 'Last read: {title}', { title: d.last_book })) : '') +
            '<br>' + esc(tr('counts', '{books} books · {highlights} highlights · {events} reading events', { books: d.books, highlights: d.highlights, events: d.events })) +
          '</div>';
        const forget = document.createElement('button');
        forget.type = 'button';
        forget.className = 'btn btn--sm btn--ghost koreader-forget';
        forget.textContent = tr('forget', 'Forget');
        forget.onclick = async () => {
          try {
            await fetch('/api/koreader/devices/' + encodeURIComponent(d.device_id), { method: 'DELETE', headers: { 'content-type': 'application/json' } });
            row.remove();
            if (!devicesEl.children.length) renderDevices([], offered);
          } catch { api.toast(tr('forgetFailed', 'Could not forget this device.'), 'error'); }
        };
        row.appendChild(forget);
        return row;
      }));
    };

    const renderStats = (st) => {
      if (!st || !st.total || !st.total.sessions) {
        statsEl.innerHTML = '<p class="modal__note">' + te('noReading', 'No reading time yet. It arrives after a book is closed on the device.') + '</p>';
        return;
      }
      const lines =
        '<p class="koreader-stat">' + te('recentLine', '{time} in {sessions} sittings in the last {days} days', { time: duration(st.recent.seconds), sessions: st.recent.sessions, days: st.recent.days }) + '</p>' +
        '<p class="koreader-stat koreader-stat--dim">' + te('totalLine', '{time} in {sessions} sittings, all time', { time: duration(st.total.seconds), sessions: st.total.sessions }) + '</p>';
      const books = (st.books || []).slice(0, 5).map((b) =>
        '<li><span>' + esc(b.title || '#' + b.issue_id) + '</span><span class="koreader-stat--dim">' + esc(duration(b.seconds)) + '</span></li>').join('');
      statsEl.innerHTML = lines + (books ? '<ul class="koreader-books">' + books + '</ul>' : '');
    };

    (async () => {
      try {
        const [me, dev, st] = await Promise.all([
          api.get('/api/koreader/me').catch(() => null),
          api.get('/api/koreader/devices'),
          api.get('/api/koreader/stats'),
        ]);
        renderDevices(dev.devices || [], me && me.plugin);
        renderStats(st);
      } catch {
        devicesEl.innerHTML = '<p class="modal__note">' + te('loadFailed', 'Could not load KOReader details.') + '</p>';
        statsEl.innerHTML = '';
      }
    })();
  });
})();
