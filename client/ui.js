// KOReader client UI — a card on the core Profile page: download the device
// plugin (with this server's address inside), the three steps to install it,
// and where the API key comes from. Reuses core CSS classes.
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

    const card = document.createElement('section');
    card.className = 'settings-section';
    card.id = 'koreader-profile';
    card.innerHTML =
      '<p class="modal__subhead">' + te('title', 'KOReader') + '</p>' +
      '<p class="modal__note">' + te('intro', 'Read your Books library on a Kobo, Kindle or other e-reader running KOReader: browse and download books from the device, and pick up where you left off, on the device or in the browser.') + '</p>' +
      '<ol class="koreader-steps">' +
        '<li>' + trh('step1', 'Download the plugin and copy the <code>backissue.koplugin</code> folder from the zip into KOReader\'s <code>plugins</code> folder on the device, then restart KOReader.') + '</li>' +
        '<li>' + trh('step2', 'In KOReader open the top menu, then <b>Tools</b> → <b>BackIssue</b>. The server address is already filled in; paste a personal key from <b>API key</b> on this page.') + '</li>' +
        '<li>' + trh('step3', 'Use <b>Browse library</b> to download books. Progress syncs when you open and close a book; <b>Automatic sync</b> can be switched off there.') + '</li>' +
      '</ol>' +
      '<div class="koreader-actions">' +
        '<a id="koreader-download" class="btn btn--sm" href="/api/koreader/plugin.zip" download="backissue.koplugin.zip">' + te('download', 'Download the KOReader plugin') + '</a>' +
      '</div>';
    slot.appendChild(card);
  });
})();
