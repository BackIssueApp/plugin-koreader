// KOReader companion plugin for BackIssue. Two halves:
//   • this server plugin: a small JSON API under /api/koreader for the device
//     (list and look up books, read and write positions), a per-user
//     "KOReader" card on the Profile page, and the device plugin itself zipped
//     on request with this server's address inside;
//   • the device plugin (koplugin/backissue.koplugin, Lua): a BackIssue entry
//     in KOReader's menu to browse and download the Books library, and
//     progress sync while reading.
// Book files come from the ebooks plugin's own route, so on-demand (file-less)
// books download the same way they open in the browser. Positions are kept
// exactly as KOReader states them, and mirrored as a fraction into the web
// reader's record so Home, Continue reading and reading stats agree.
import config from '../../src/config.js';
import { openKoreaderStore } from './store.js';
import { fingerprintFile } from './fingerprint.js';
import { buildPluginZip } from './bundle.js';

const PLUGIN_VERSION = '0.1.0';

export default async function register(api) {
  const CAN = api.registerPermission ? 'koreader.use' : 'viewer';
  api.registerPermission?.({
    key: 'koreader.use',
    label: 'KOReader',
    description: 'Browse and download books from KOReader and sync reading progress with it',
    tier: 'viewer',
  });
  api.registerClientAsset?.({ js: 'client/ui.js', css: 'client/koreader.css' });

  const store = openKoreaderStore(config.dbPath, { fingerprintFile });

  // The ebooks plugin's store, when it is installed: positions mirrored
  // through it count as reading there (stats, Continue reading). Without it
  // the mirror is a plain row write, and books simply aren't listed.
  let ebooks = null;
  try {
    const { openEbooksStore } = await import('../ebooks/store.js');
    ebooks = openEbooksStore(config.dbPath);
  } catch { /* no Books library on this server */ }

  // Mature/restricted gating as the OPDS catalog does it: a role without
  // library.restricted, or an account that switched mature content off, sees
  // no restricted books and can't look them up.
  let canRestricted = () => true;
  try {
    const { roleGrants, CORE_PERMISSIONS } = await import('../../src/users.js');
    const { registeredPermissions } = await import('../../src/plugins.js');
    const permCatalog = new Map([...CORE_PERMISSIONS, ...registeredPermissions()].map((p) => [p.key, p]));
    canRestricted = (req) => {
      if (!req.user || req.user.id === 0) return true;
      try { return roleGrants(store.db, req.user.role, 'library.restricted', permCatalog) && !req.user.hide_mature; } catch { return false; }
    };
  } catch { /* an older core without granular permissions: nothing hidden */ }

  const uid = (req) => req.user?.id ?? 0;
  // The device sends an API key (X-Api-Key) or HTTP Basic; basicAuth makes a
  // bare 401 carry the challenge KOReader's HTTP client expects.
  const OPTS = { access: CAN, basicAuth: true };
  const WRITE = { access: CAN, basicAuth: true };

  // Fingerprints: a pass shortly after boot, after each Books scan, and when a
  // lookup misses (at most once a minute) — the file may have been added
  // since the last pass.
  let fpRun = null;
  let fpLast = 0;
  const fingerprintSoon = (force = false) => {
    if (fpRun) return fpRun;
    if (!force && Date.now() - fpLast < 60_000) return Promise.resolve(0);
    fpRun = store.fingerprintPending({ log: console.warn })
      .then((n) => { if (n) console.log(`koreader: fingerprinted ${n} book file${n === 1 ? '' : 's'}`); store.pruneFingerprints(); return n; })
      .catch((e) => { console.warn('koreader: fingerprint pass failed:', e?.message || e); return 0; })
      .finally(() => { fpRun = null; fpLast = Date.now(); });
    return fpRun;
  };
  setTimeout(() => { fingerprintSoon(true); }, 45_000).unref?.();
  api.registerJob?.({
    id: 'koreader-fingerprints',
    label: 'Fingerprint book files for KOReader',
    scheduleKey: 'koreaderFingerprintHours',
    run: () => fingerprintSoon(true),
  });
  config.koreaderFingerprintCron ??= '30 */6 * * *';
  config.koreaderFingerprintEnabled ??= true;

  // The app's version, read the way core reads it (plugins sit two levels
  // under the app root).
  let serverVersion = () => null;
  try {
    const { readFileSync } = await import('node:fs');
    const v = JSON.parse(readFileSync(new URL('../../package.json', import.meta.url), 'utf8')).version || null;
    serverVersion = () => v;
  } catch { /* not under an app tree (tests) */ }
  // The address the device should talk to: what the browser used to reach
  // this page, proxy headers first.
  const originOf = (req) => {
    const proto = String(req.headers['x-forwarded-proto'] || req.protocol || 'http').split(',')[0].trim();
    const host = String(req.headers['x-forwarded-host'] || req.headers.host || '').split(',')[0].trim();
    return host ? `${proto}://${host}` : '';
  };

  // Every call from the device names it in headers; that keeps the Devices
  // list on the Profile page current without a call of its own.
  const seen = (req, extra = {}) => {
    const id = req.headers['x-device-id'];
    if (!id) return;
    store.touchDevice(uid(req), {
      device_id: String(id), name: req.headers['x-device-name'] ? decodeURIComponent(String(req.headers['x-device-name'])) : null,
      model: req.headers['x-device-model'] ? String(req.headers['x-device-model']) : null,
      plugin_version: req.headers['x-plugin-version'] ? String(req.headers['x-plugin-version']) : null, ...extra,
    });
  };
  // A list from the device: an empty Lua table arrives as {} rather than [].
  const listOf = (v) => (Array.isArray(v) ? v : v && typeof v === 'object' ? Object.values(v) : null);
  const deviceOf = (req, body = {}) => ({
    device: body.device || (req.headers['x-device-name'] ? decodeURIComponent(String(req.headers['x-device-name'])) : null),
    device_id: body.device_id || (req.headers['x-device-id'] ? String(req.headers['x-device-id']) : null),
  });

  // GET /api/koreader/me — who am I, and is the server ready for the device.
  api.registerRoute('get', '/api/koreader/me', (req, res) => {
    seen(req);
    res.json({
      ok: true,
      user: req.user?.username || null,
      server: 'BackIssue',
      version: serverVersion(),
      plugin: PLUGIN_VERSION,
      books: store.hasEbooks(),
    });
  }, OPTS);

  // GET /api/koreader/books?q=&offset=&limit=&sort=title|recent|progress&author=&series=
  api.registerRoute('get', '/api/koreader/books', (req, res) => {
    seen(req);
    res.json(store.listBooks({
      userId: uid(req), q: req.query.q, offset: req.query.offset, limit: req.query.limit,
      sort: ['recent', 'progress'].includes(req.query.sort) ? req.query.sort : 'title',
      author: req.query.author, seriesId: req.query.series, includeRestricted: canRestricted(req),
    }));
  }, OPTS);

  // GET /api/koreader/authors, GET /api/koreader/series — the browse views.
  api.registerRoute('get', '/api/koreader/authors', (req, res) => {
    res.json({ authors: store.authors({ includeRestricted: canRestricted(req) }) });
  }, OPTS);
  api.registerRoute('get', '/api/koreader/series', (req, res) => {
    res.json({ series: store.seriesList({ includeRestricted: canRestricted(req) }) });
  }, OPTS);

  // GET /api/koreader/books/:id — one book, with its download path.
  api.registerRoute('get', '/api/koreader/books/:id', (req, res) => {
    const b = store.book(req.params.id, { userId: uid(req), includeRestricted: canRestricted(req) });
    if (!b) return res.status(404).json({ error: 'not a book' });
    res.json({ book: b });
  }, OPTS);

  // GET /api/koreader/lookup?fp=<md5>&size=<bytes> — which book is this file.
  api.registerRoute('get', '/api/koreader/lookup', async (req, res) => {
    let id = store.lookup(req.query.fp, req.query.size);
    if (id == null) { await fingerprintSoon(); id = store.lookup(req.query.fp, req.query.size); }
    const b = id == null ? null : store.book(id, { userId: uid(req), includeRestricted: canRestricted(req) });
    if (!b) return res.status(404).json({ error: 'no such book here' });
    res.json({ book: b });
  }, OPTS);

  // GET /api/koreader/progress/:id — the newest position, from any device or
  // the web reader; 204 when the book was never opened.
  api.registerRoute('get', '/api/koreader/progress/:id', (req, res) => {
    const b = store.book(req.params.id, { userId: uid(req), includeRestricted: canRestricted(req) });
    if (!b) return res.status(404).json({ error: 'not a book' });
    const p = store.progress(uid(req), b.id);
    res.json({ progress: p });
  }, OPTS);

  // PUT /api/koreader/progress/:id { fraction, position, kind, device, device_id, status, at }
  api.registerRoute('put', '/api/koreader/progress/:id', (req, res) => {
    const b = store.book(req.params.id, { userId: uid(req), includeRestricted: canRestricted(req) });
    if (!b) return res.status(404).json({ error: 'not a book' });
    const body = req.body || {};
    if (!Number.isFinite(Number(body.fraction))) return res.status(400).json({ error: 'fraction (0..1) is required' });
    seen(req);
    res.json({ ok: true, progress: store.saveProgress(uid(req), b.id, { ...body, ...deviceOf(req, body) }, { ebooks }) });
  }, WRITE);

  // GET /api/koreader/highlights/:id — KOReader's highlights for a book as
  // the server holds them, with the keys deleted on the web since.
  api.registerRoute('get', '/api/koreader/highlights/:id', (req, res) => {
    const b = store.book(req.params.id, { userId: uid(req), includeRestricted: canRestricted(req) });
    if (!b) return res.status(404).json({ error: 'not a book' });
    seen(req);
    res.json(store.highlights(uid(req), b.id));
  }, OPTS);

  // PUT /api/koreader/highlights/:id { items: [...], deleted: [key] } — the
  // device's list after it merged the server's; answers with the result.
  api.registerRoute('put', '/api/koreader/highlights/:id', (req, res) => {
    const b = store.book(req.params.id, { userId: uid(req), includeRestricted: canRestricted(req) });
    if (!b) return res.status(404).json({ error: 'not a book' });
    const body = req.body || {};
    const items = listOf(body.items);
    if (!items) return res.status(400).json({ error: 'items (array) is required' });
    seen(req);
    res.json(store.syncHighlights(uid(req), b.id, {
      items, deleted: listOf(body.deleted) || [], ...deviceOf(req, body),
    }));
  }, WRITE);

  // GET /api/koreader/events/:id/cursor — the newest page event this device
  // already sent for a book, so it uploads only what followed.
  api.registerRoute('get', '/api/koreader/events/:id/cursor', (req, res) => {
    const b = store.book(req.params.id, { userId: uid(req), includeRestricted: canRestricted(req) });
    if (!b) return res.status(404).json({ error: 'not a book' });
    res.json({ since: store.eventsCursor(uid(req), b.id, deviceOf(req).device_id) });
  }, OPTS);

  // PUT /api/koreader/events/:id { events: [{ start_time, duration, page, pages }] }
  api.registerRoute('put', '/api/koreader/events/:id', (req, res) => {
    const b = store.book(req.params.id, { userId: uid(req), includeRestricted: canRestricted(req) });
    if (!b) return res.status(404).json({ error: 'not a book' });
    const body = req.body || {};
    const events = listOf(body.events);
    if (!events) return res.status(400).json({ error: 'events (array) is required' });
    seen(req);
    const added = store.addEvents(uid(req), b.id, deviceOf(req, body).device_id || '', events.slice(0, 5000));
    res.json({ ok: true, added });
  }, WRITE);

  // POST /api/koreader/synced — a device finished a "sync all" sweep.
  api.registerRoute('post', '/api/koreader/synced', (req, res) => {
    const d = deviceOf(req, req.body || {});
    if (d.device_id) store.touchDevice(uid(req), { device_id: d.device_id, name: d.device, synced: true });
    res.json({ ok: true });
  }, WRITE);

  // The Profile card: devices and reading time.
  api.registerRoute('get', '/api/koreader/devices', (req, res) => {
    res.json({ devices: store.devices(uid(req)) });
  }, { access: CAN });
  api.registerRoute('delete', '/api/koreader/devices/:id', (req, res) => {
    res.json({ ok: true, removed: store.forgetDevice(uid(req), req.params.id) });
  }, { access: CAN });
  api.registerRoute('get', '/api/koreader/stats', (req, res) => {
    res.json(store.readingStats(uid(req), { days: req.query.days, limit: req.query.limit }));
  }, { access: CAN });
  setInterval(() => { try { store.pruneHighlights(); } catch { /* next time */ } }, 6 * 3600 * 1000).unref?.();

  // GET /api/koreader/plugin.zip — the device plugin, with this server's
  // address written in. Downloaded from the Profile page.
  api.registerRoute('get', '/api/koreader/plugin.zip', async (req, res) => {
    try {
      const buf = await buildPluginZip({ server: originOf(req), version: PLUGIN_VERSION });
      res.set('Content-Type', 'application/zip');
      res.set('Content-Disposition', 'attachment; filename="backissue.koplugin.zip"');
      res.set('Cache-Control', 'private, no-store');
      res.send(buf);
    } catch (e) {
      res.status(500).json({ error: `could not build the plugin: ${e?.message || e}` });
    }
  }, OPTS);
}
