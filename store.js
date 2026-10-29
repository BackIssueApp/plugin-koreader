// What the KOReader plugin keeps in the core database: per-user reading
// positions as KOReader expresses them (an xpointer or a page, with the
// fraction), and a fingerprint per book file so a device can name a book it
// didn't download through us. Books themselves are the ebooks plugin's rows
// (ebooks_files joined to core's issues/series); this store only reads them.
import path from 'node:path';
import Database from 'better-sqlite3';

const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');

export function openKoreaderStore(dbPath, { fingerprintFile } = {}) {
  const db = typeof dbPath === 'string' ? new Database(dbPath) : dbPath;
  try { db.pragma('busy_timeout = 5000'); } catch { /* in-memory */ }
  db.exec(`
    CREATE TABLE IF NOT EXISTS koreader_progress (
      user_id    INTEGER NOT NULL DEFAULT 0,
      issue_id   INTEGER NOT NULL,
      fraction   REAL NOT NULL DEFAULT 0,
      position   TEXT,            -- an xpointer (EPUB) or a page number (PDF), as KOReader gave it
      kind       TEXT,            -- 'xpointer' | 'page'
      device     TEXT,            -- the device's name, for "synced from …"
      device_id  TEXT,            -- KOReader's own device id, so a device skips its own record
      updated_at TEXT,
      PRIMARY KEY (user_id, issue_id)
    );
    CREATE TABLE IF NOT EXISTS koreader_fingerprints (
      issue_id    INTEGER PRIMARY KEY,
      fp          TEXT NOT NULL,
      size        INTEGER,
      mtime       INTEGER,        -- with size, says when a file changed under us
      computed_at TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_koreader_fp ON koreader_fingerprints (fp);
    -- Highlights and notes as KOReader keeps them (an xpointer pair, or a page
    -- with coordinates), one row per annotation. Each is mirrored into the
    -- ebooks plugin's bookmarks so the web and the apps list it; the mirror's
    -- id is kept so a note edited or a mark deleted there flows back.
    CREATE TABLE IF NOT EXISTS koreader_highlights (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id     INTEGER NOT NULL DEFAULT 0,
      issue_id    INTEGER NOT NULL,
      key         TEXT NOT NULL,    -- the device's stable key: creation time + start position
      kind        TEXT,             -- 'xpointer' | 'page'
      pos0        TEXT,
      pos1        TEXT,
      page        INTEGER,
      chapter     TEXT,
      text        TEXT,
      note        TEXT,
      color       TEXT,
      drawer      TEXT,
      fraction    REAL NOT NULL DEFAULT 0,
      device      TEXT,
      device_id   TEXT,
      created_at  TEXT,             -- the device's own creation stamp
      updated_at  TEXT,             -- server time of the last change, from any side
      bookmark_id INTEGER,          -- the mirror row in ebooks_bookmarks
      deleted_at  TEXT,             -- removed on the web/app; devices drop it on their next sync
      UNIQUE (user_id, issue_id, key)
    );
    CREATE INDEX IF NOT EXISTS idx_koreader_hl_book ON koreader_highlights (user_id, issue_id);
    -- Raw page-reading events from KOReader's statistics (one per page turn,
    -- with how long the page was open). Sessions are derived on read.
    CREATE TABLE IF NOT EXISTS koreader_reading_events (
      user_id    INTEGER NOT NULL DEFAULT 0,
      issue_id   INTEGER NOT NULL,
      device_id  TEXT NOT NULL DEFAULT '',
      start_time INTEGER NOT NULL,  -- unix seconds, device clock
      duration   INTEGER NOT NULL DEFAULT 0,
      page       INTEGER,
      pages      INTEGER,
      PRIMARY KEY (user_id, issue_id, device_id, start_time)
    );
    -- Every device that has talked to this server, for the Profile card.
    CREATE TABLE IF NOT EXISTS koreader_devices (
      user_id        INTEGER NOT NULL DEFAULT 0,
      device_id      TEXT NOT NULL,
      name           TEXT,
      model          TEXT,
      plugin_version TEXT,
      last_seen      TEXT,
      last_sync_at   TEXT,          -- last "sync all" or progress push
      last_issue_id  INTEGER,
      PRIMARY KEY (user_id, device_id)
    );
  `);
  // A reading status the device set (reading | complete | abandoned), kept
  // beside the position; older tables gain the column in place.
  const kpCols = db.prepare("SELECT name FROM pragma_table_info('koreader_progress')").all().map((r) => r.name);
  if (!kpCols.includes('status')) db.exec('ALTER TABLE koreader_progress ADD COLUMN status TEXT');

  const FINISHED = 0.98; // the ebooks plugin's own "finished" threshold
  const SESSION_GAP_S = 30 * 60; // events closer than this are one sitting
  const SESSION_MIN_S = 10; // shorter sittings are a mis-tap, not reading

  const hasTable = (name) => !!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name);
  const hasEbooks = () => hasTable('ebooks_files');
  const hasWebProgress = () => hasTable('ebooks_progress');

  // A standalone book is a one-issue series the ebooks plugin minted for it;
  // a calibre-style series groups several. Only the latter is a "series" to a
  // reader.
  const isStandalone = (url) => /^ebook:l\d+:b:/.test(String(url || ''));
  const shapeBook = (r) => ({
    id: r.issue_id,
    title: r.title || r.series_title || path.basename(String(r.path || ''), path.extname(String(r.path || ''))),
    authors: String(r.publisher || '').split(',').map((a) => a.trim()).filter(Boolean),
    series: isStandalone(r.series_url) ? null : (r.series_title || null),
    series_index: isStandalone(r.series_url) ? null : (r.issue_number ?? null),
    format: r.format || null,
    size: r.size ?? null,
    library: r.library_name || null,
    remote: !r.path,
    filename: r.path ? path.basename(r.path) : `${(r.title || 'book').replace(/[\\/:*?"<>|]+/g, ' ').trim()}.${r.format || 'epub'}`,
    added_at: r.added_at || null,
    fraction: Number(r.fraction) || 0,
    finished: (Number(r.fraction) || 0) >= FINISHED,
    last_read_at: r.progress_at || null,
    series_id: isStandalone(r.series_url) ? null : (r.series_id ?? null),
    description: r.description ? String(r.description).slice(0, 4000) : null,
    download: `/api/ebooks/issue/${r.issue_id}/file?dl=1`,
    cover: `/api/ebooks/issue/${r.issue_id}/cover`,
  });

  const BOOK_FROM = (userId) => `
    FROM ebooks_files ef
    JOIN issues i ON i.id = ef.issue_id
    JOIN series s ON s.id = i.series_id
    LEFT JOIN libraries l ON l.id = s.library_id
    ${hasWebProgress()
      ? 'LEFT JOIN ebooks_progress p ON p.issue_id = i.id AND p.user_id = ' + Number(userId || 0)
      : 'LEFT JOIN koreader_progress p ON p.issue_id = i.id AND p.user_id = ' + Number(userId || 0)}
    WHERE s.type = 'ebook'`;
  const BOOK_COLS = `ef.issue_id, ef.path, ef.format, ef.size, ef.added_at, i.title, i.issue_number,
    s.id AS series_id, s.title AS series_title, s.url AS series_url, s.publisher, s.description,
    l.name AS library_name, p.fraction, p.updated_at AS progress_at`;

  // Reading sittings from raw page events: sorted by start, a gap longer
  // than SESSION_GAP_S opens a new one, and sittings shorter than
  // SESSION_MIN_S are dropped. Returns [{ start, end, seconds, pages }].
  const sessionsOf = (events) => {
    const out = [];
    let cur = null;
    for (const e of [...events].sort((a, b) => a.start_time - b.start_time)) {
      const s = Number(e.start_time) || 0;
      const d = Math.max(0, Number(e.duration) || 0);
      if (cur && s - cur.end <= SESSION_GAP_S) {
        cur.end = Math.max(cur.end, s + d);
        cur.seconds += d;
        cur.pages.add(e.page);
      } else {
        if (cur) out.push(cur);
        cur = { start: s, end: s + d, seconds: d, pages: new Set([e.page]), issue_id: e.issue_id, device_id: e.device_id };
      }
    }
    if (cur) out.push(cur);
    return out.filter((x) => x.seconds >= SESSION_MIN_S).map((x) => ({ ...x, pages: x.pages.size }));
  };

  return {
    db,
    hasEbooks,

    /** One page of the Books library, as a device lists it. */
    listBooks({ userId = 0, q = '', offset = 0, limit = 100, sort = 'title', author = '', seriesId = null, finished = false, includeRestricted = true } = {}) {
      if (!hasEbooks()) return { total: 0, books: [] };
      const conds = [];
      const params = [];
      if (!includeRestricted) conds.push('s.restricted = 0');
      const needle = String(q || '').trim();
      if (needle) {
        // Each word must appear somewhere in the title, series or author.
        for (const word of needle.split(/\s+/)) {
          conds.push("(i.title LIKE ? ESCAPE '\\' OR s.title LIKE ? ESCAPE '\\' OR s.publisher LIKE ? ESCAPE '\\')");
          const like = `%${word.replace(/[\\%_]/g, (c) => '\\' + c)}%`;
          params.push(like, like, like);
        }
      }
      const by = String(author || '').trim();
      if (by) {
        // The author slot is a comma-joined list; match a whole name in it.
        conds.push("(',' || REPLACE(s.publisher, ', ', ',') || ',') LIKE ? ESCAPE '\\'");
        params.push(`%,${by.replace(/[\\%_]/g, (c) => '\\' + c)},%`);
      }
      if (seriesId != null && seriesId !== '') { conds.push('s.id = ?'); params.push(Number(seriesId)); }
      // "progress": books under way, most recently read first.
      if (sort === 'progress') conds.push(`p.fraction > 0 AND p.fraction < ${FINISHED}`);
      if (finished) conds.push(`p.fraction >= ${FINISHED}`);
      const whereSql = conds.length ? ' AND ' + conds.join(' AND ') : '';
      const order = sort === 'recent' ? 'ORDER BY ef.added_at DESC, ef.rowid DESC'
        : sort === 'progress' ? 'ORDER BY p.updated_at DESC, ef.rowid DESC'
        : seriesId != null && seriesId !== '' ? 'ORDER BY CAST(i.issue_number AS REAL), i.title COLLATE NOCASE, ef.rowid'
        : 'ORDER BY i.title COLLATE NOCASE, ef.rowid';
      const lim = Math.min(500, Math.max(1, Number(limit) || 100));
      const off = Math.max(0, Number(offset) || 0);
      const total = db.prepare(`SELECT COUNT(*) c ${BOOK_FROM(userId)}${whereSql}`).get(...params).c;
      const rows = db.prepare(`SELECT ${BOOK_COLS} ${BOOK_FROM(userId)}${whereSql} ${order} LIMIT ? OFFSET ?`).all(...params, lim, off);
      return { total, books: rows.map(shapeBook) };
    },

    /** One book by core issue id, or null. */
    book(issueId, { userId = 0, includeRestricted = true } = {}) {
      if (!hasEbooks()) return null;
      const r = db.prepare(`SELECT ${BOOK_COLS}, s.restricted ${BOOK_FROM(userId)} AND ef.issue_id = ?`).get(Number(issueId));
      if (!r || (!includeRestricted && r.restricted)) return null;
      return shapeBook(r);
    },

    /** Authors with how many books each: [{ name, books }]. */
    authors({ includeRestricted = true } = {}) {
      if (!hasEbooks()) return [];
      const rows = db.prepare(`SELECT s.publisher AS by, COUNT(*) c FROM ebooks_files ef
        JOIN issues i ON i.id = ef.issue_id JOIN series s ON s.id = i.series_id
        WHERE s.type = 'ebook'${includeRestricted ? '' : ' AND s.restricted = 0'} GROUP BY s.publisher`).all();
      const counts = new Map();
      for (const r of rows) {
        for (const name of String(r.by || '').split(',').map((a) => a.trim()).filter(Boolean)) {
          counts.set(name, (counts.get(name) || 0) + r.c);
        }
      }
      return [...counts].map(([name, books]) => ({ name, books })).sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));
    },

    /** Multi-book series (a standalone book's own series is not one): [{ id, title, authors, books }]. */
    seriesList({ includeRestricted = true } = {}) {
      if (!hasEbooks()) return [];
      return db.prepare(`SELECT s.id, s.title, s.publisher, COUNT(*) c FROM ebooks_files ef
        JOIN issues i ON i.id = ef.issue_id JOIN series s ON s.id = i.series_id
        WHERE s.type = 'ebook' AND s.url NOT LIKE 'ebook:l%:b:%'${includeRestricted ? '' : ' AND s.restricted = 0'}
        GROUP BY s.id ORDER BY s.title COLLATE NOCASE`).all()
        .map((r) => ({ id: r.id, title: r.title, authors: String(r.publisher || '').split(',').map((a) => a.trim()).filter(Boolean), books: r.c }));
    },

    /** The newest position for a book across KOReader devices and the web
     *  reader: { fraction, position, kind, device, device_id, source, status,
     *  finished, updated_at, file_changed_at } or null. The web reader's
     *  record carries no KOReader position, so a device landing on it goes by
     *  percentage. */
    progress(userId, issueId) {
      const ko = db.prepare('SELECT fraction, position, kind, device, device_id, status, updated_at FROM koreader_progress WHERE user_id=? AND issue_id=?')
        .get(userId || 0, Number(issueId)) || null;
      let web = null;
      if (hasWebProgress()) {
        const w = db.prepare('SELECT fraction, updated_at FROM ebooks_progress WHERE user_id=? AND issue_id=?').get(userId || 0, Number(issueId));
        if (w) web = { fraction: w.fraction, position: null, kind: null, device: null, device_id: null, status: null, updated_at: w.updated_at };
      }
      if (!ko && !web) return null;
      // Each KOReader push is mirrored into the web record with the same
      // stamp, so a web record strictly newer than the KOReader one means the
      // web reader moved since.
      const pick = !web || (ko && String(ko.updated_at || '') >= String(web.updated_at || '')) ? { ...ko, source: 'koreader' } : { ...web, source: 'web' };
      pick.status = ko?.status || null;
      pick.finished = pick.status === 'complete' || (Number(pick.fraction) || 0) >= FINISHED;
      // The server's copy of the file changed after this position was taken:
      // a re-download, or a replaced file. The device can say so.
      const fp = db.prepare('SELECT computed_at, mtime FROM koreader_fingerprints WHERE issue_id=?').get(Number(issueId));
      pick.file_changed_at = fp && ko && fp.mtime && Number(fp.mtime) > Date.parse(ko.updated_at || 0) ? fp.computed_at : null; // mtime is ms
      return pick;
    },

    /** A device's position. Mirrors the fraction into the web reader's record
     *  (through the ebooks store when given, so reading stats count it).
     *  `status` is KOReader's reading | complete | abandoned; complete also
     *  marks the book finished for the web. `at` (unix seconds, the device's
     *  last access time) lets a sweep skip positions older than what the
     *  server already has. */
    saveProgress(userId, issueId, { fraction, position, kind, device, device_id, status, at } = {}, { ebooks } = {}) {
      const f0 = Math.min(1, Math.max(0, Number(fraction) || 0));
      const st = ['reading', 'complete', 'abandoned'].includes(status) ? status : null;
      const f = st === 'complete' ? Math.max(f0, 1) : f0;
      const k = kind === 'page' || kind === 'xpointer' ? kind : null;
      const pos = position == null || position === '' ? null : String(position).slice(0, 2000);
      const stamp = now();
      if (Number.isFinite(Number(at)) && Number(at) > 0) {
        const prev = db.prepare('SELECT updated_at FROM koreader_progress WHERE user_id=? AND issue_id=?').get(userId || 0, Number(issueId));
        if (prev?.updated_at && Date.parse(prev.updated_at) >= Number(at) * 1000) {
          return { skipped: true, fraction: f, position: pos, kind: k, updated_at: prev.updated_at };
        }
      }
      db.prepare(`INSERT INTO koreader_progress (user_id, issue_id, fraction, position, kind, device, device_id, status, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(user_id, issue_id) DO UPDATE SET fraction = excluded.fraction, position = excluded.position,
          kind = excluded.kind, device = excluded.device, device_id = excluded.device_id,
          status = COALESCE(excluded.status, koreader_progress.status), updated_at = excluded.updated_at`)
        .run(userId || 0, Number(issueId), f, pos, k, device ? String(device).slice(0, 100) : null, device_id ? String(device_id).slice(0, 100) : null, st, stamp);
      // The web reader resumes by its own locator when it has one; after a
      // device moved the book on, that locator is stale, so it is cleared and
      // the fraction stands (the reader falls back to it).
      const dev = device ? String(device).slice(0, 100) : null;
      if (ebooks && typeof ebooks.saveProgress === 'function') {
        try { ebooks.saveProgress(userId || 0, Number(issueId), { locator: null, fraction: f, device: dev }); } catch { /* the device record is what matters */ }
      } else if (hasWebProgress()) {
        db.prepare(`INSERT INTO ebooks_progress (user_id, issue_id, locator, fraction, updated_at) VALUES (?, ?, NULL, ?, ?)
          ON CONFLICT(user_id, issue_id) DO UPDATE SET locator = NULL, fraction = excluded.fraction, updated_at = excluded.updated_at`)
          .run(userId || 0, Number(issueId), f, stamp);
      }
      if (device_id) this.touchDevice(userId, { device_id, name: device, last_issue_id: Number(issueId), synced: true });
      return { fraction: f, position: pos, kind: k, status: st, updated_at: stamp };
    },

    // ---- highlights -----------------------------------------------------------
    /** KOReader's highlights for a book as the server holds them, plus the
     *  keys removed on the web or in an app since. Edits made to the mirror
     *  (a note changed in an app, the mark deleted) are folded in first. */
    highlights(userId, issueId) {
      const rows = db.prepare('SELECT * FROM koreader_highlights WHERE user_id=? AND issue_id=? ORDER BY fraction, id').all(userId || 0, Number(issueId));
      const mirrors = hasTable('ebooks_bookmarks');
      const stamp = now();
      for (const r of rows) {
        if (r.deleted_at || !mirrors || !r.bookmark_id) continue;
        const m = db.prepare('SELECT note, color FROM ebooks_bookmarks WHERE id=? AND user_id=?').get(r.bookmark_id, userId || 0);
        if (!m) {
          db.prepare('UPDATE koreader_highlights SET deleted_at=?, updated_at=? WHERE id=?').run(stamp, stamp, r.id);
          r.deleted_at = stamp;
        } else if ((m.note || null) !== (r.note || null)) {
          db.prepare('UPDATE koreader_highlights SET note=?, updated_at=? WHERE id=?').run(m.note || null, stamp, r.id);
          r.note = m.note || null; r.updated_at = stamp;
        }
      }
      const shape = (r) => ({
        key: r.key, kind: r.kind, pos0: r.pos0, pos1: r.pos1, page: r.page, chapter: r.chapter, text: r.text,
        note: r.note, color: r.color, drawer: r.drawer, fraction: r.fraction, device: r.device, device_id: r.device_id,
        created_at: r.created_at, updated_at: r.updated_at,
      });
      return {
        items: rows.filter((r) => !r.deleted_at).map(shape),
        deleted: rows.filter((r) => r.deleted_at).map((r) => r.key),
      };
    },

    /** A device's full list for a book after it merged the server's answer:
     *  new keys are added (and mirrored), known ones updated where the device
     *  says they changed, `deleted` keys removed everywhere. A key the web
     *  deleted and the device still sends (it hasn't pulled yet) stays
     *  deleted. Returns the same shape as highlights(). */
    syncHighlights(userId, issueId, { items = [], deleted = [], device, device_id } = {}) {
      const uid = userId || 0;
      const iid = Number(issueId);
      const stamp = now();
      // The mirror rows are written on this connection, inside the same
      // transaction: the ebooks store's own connection would wait on our lock.
      const mirrors = hasTable('ebooks_bookmarks');
      const mirrorLocator = (h) => `koreader:${h.kind || 'xpointer'}:${h.pos0 || h.key}`;
      const tx = db.transaction(() => {
        for (const key of deleted) {
          const r = db.prepare('SELECT id, bookmark_id FROM koreader_highlights WHERE user_id=? AND issue_id=? AND key=?').get(uid, iid, String(key));
          if (!r) continue;
          if (r.bookmark_id && mirrors) db.prepare('DELETE FROM ebooks_bookmarks WHERE id=? AND user_id=?').run(r.bookmark_id, uid);
          db.prepare('DELETE FROM koreader_highlights WHERE id=?').run(r.id);
        }
        for (const it of items) {
          if (!it || !it.key) continue;
          const key = String(it.key).slice(0, 300);
          const clean = {
            kind: it.kind === 'page' ? 'page' : 'xpointer',
            pos0: it.pos0 == null ? null : String(it.pos0).slice(0, 2000),
            pos1: it.pos1 == null ? null : String(it.pos1).slice(0, 2000),
            page: Number.isFinite(Number(it.page)) ? Math.round(Number(it.page)) : null,
            chapter: it.chapter ? String(it.chapter).slice(0, 200) : null,
            text: it.text ? String(it.text).slice(0, 2000) : null,
            note: it.note ? String(it.note).slice(0, 500) : null,
            color: it.color ? String(it.color).slice(0, 16) : null,
            drawer: it.drawer ? String(it.drawer).slice(0, 16) : null,
            fraction: Math.min(1, Math.max(0, Number(it.fraction) || 0)),
            created_at: it.created_at ? String(it.created_at).slice(0, 40) : null,
          };
          const r = db.prepare('SELECT * FROM koreader_highlights WHERE user_id=? AND issue_id=? AND key=?').get(uid, iid, key);
          if (r?.deleted_at) continue;
          if (!r) {
            let bookmarkId = null;
            if (mirrors) {
              const bm = { locator: mirrorLocator({ ...clean, key }), fraction: clean.fraction, note: clean.note, color: clean.color, text: clean.text };
              try {
                bookmarkId = db.prepare(`INSERT INTO ebooks_bookmarks (user_id, issue_id, locator, fraction, note, color, text, created_at)
                  VALUES (?,?,?,?,?,?,?,?)`).run(uid, iid, bm.locator, bm.fraction, bm.note, bm.color, bm.text, stamp).lastInsertRowid;
              } catch { /* the KOReader row still stands */ }
            }
            db.prepare(`INSERT INTO koreader_highlights (user_id, issue_id, key, kind, pos0, pos1, page, chapter, text, note, color, drawer,
                fraction, device, device_id, created_at, updated_at, bookmark_id)
              VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
              .run(uid, iid, key, clean.kind, clean.pos0, clean.pos1, clean.page, clean.chapter, clean.text, clean.note, clean.color, clean.drawer,
                clean.fraction, device ? String(device).slice(0, 100) : null, device_id ? String(device_id).slice(0, 100) : null,
                clean.created_at, stamp, bookmarkId == null ? null : Number(bookmarkId));
          } else if (it.changed) {
            db.prepare(`UPDATE koreader_highlights SET note=?, color=?, drawer=?, text=?, chapter=?, fraction=?, updated_at=? WHERE id=?`)
              .run(clean.note, clean.color, clean.drawer, clean.text, clean.chapter, clean.fraction, stamp, r.id);
            if (r.bookmark_id && mirrors) {
              db.prepare('UPDATE ebooks_bookmarks SET note=?, color=?, text=? WHERE id=? AND user_id=?').run(clean.note, clean.color, clean.text, r.bookmark_id, uid);
            }
          }
        }
      });
      tx();
      if (device_id) this.touchDevice(uid, { device_id, name: device, last_issue_id: iid });
      return this.highlights(uid, iid);
    },

    /** Drop web-deleted rows every device has had a month to notice. */
    pruneHighlights(days = 30) {
      return db.prepare("DELETE FROM koreader_highlights WHERE deleted_at IS NOT NULL AND deleted_at < strftime('%Y-%m-%dT%H:%M:%SZ','now', ?)")
        .run(`-${Math.max(1, Number(days) || 30)} days`).changes;
    },

    // ---- reading events ---------------------------------------------------------
    /** The newest event this device sent for a book (unix seconds), so it
     *  only uploads what came after. 0 when none. */
    eventsCursor(userId, issueId, deviceId) {
      const r = db.prepare('SELECT MAX(start_time) t FROM koreader_reading_events WHERE user_id=? AND issue_id=? AND device_id=?')
        .get(userId || 0, Number(issueId), String(deviceId || ''));
      return Number(r?.t) || 0;
    },

    /** Store page events [{ start_time, duration, page, pages }]; repeats are
     *  ignored. Returns how many were new. */
    addEvents(userId, issueId, deviceId, events = []) {
      const ins = db.prepare(`INSERT OR IGNORE INTO koreader_reading_events (user_id, issue_id, device_id, start_time, duration, page, pages)
        VALUES (?,?,?,?,?,?,?)`);
      let n = 0;
      const tx = db.transaction(() => {
        for (const e of events) {
          const s = Math.round(Number(e?.start_time ?? e?.start));
          if (!Number.isFinite(s) || s <= 0) continue;
          const d = Math.min(24 * 3600, Math.max(0, Math.round(Number(e.duration) || 0)));
          n += ins.run(userId || 0, Number(issueId), String(deviceId || ''), s, d,
            Number.isFinite(Number(e.page)) ? Math.round(Number(e.page)) : null,
            Number.isFinite(Number(e.pages)) ? Math.round(Number(e.pages)) : null).changes;
        }
      });
      tx();
      if (deviceId) this.touchDevice(userId, { device_id: deviceId, last_issue_id: Number(issueId) });
      return n;
    },

    /** Reading time on KOReader for one user: totals, the last 7 days, and
     *  per book. Sessions are sittings separated by more than 30 minutes. */
    readingStats(userId, { days = 7, limit = 10 } = {}) {
      const uid = userId || 0;
      const events = db.prepare('SELECT issue_id, device_id, start_time, duration, page FROM koreader_reading_events WHERE user_id=?').all(uid);
      const byBook = new Map();
      for (const e of events) {
        if (!byBook.has(e.issue_id)) byBook.set(e.issue_id, []);
        byBook.get(e.issue_id).push(e);
      }
      const since = Math.floor(Date.now() / 1000) - Math.max(1, Number(days) || 7) * 86400;
      const total = { seconds: 0, sessions: 0, pages: 0 };
      const recent = { seconds: 0, sessions: 0, pages: 0 };
      const books = [];
      for (const [issueId, evs] of byBook) {
        const ss = sessionsOf(evs);
        const sum = (list) => list.reduce((a, s) => ({ seconds: a.seconds + s.seconds, sessions: a.sessions + 1, pages: a.pages + s.pages }), { seconds: 0, sessions: 0, pages: 0 });
        const all = sum(ss);
        const last = sum(ss.filter((s) => s.end >= since));
        total.seconds += all.seconds; total.sessions += all.sessions; total.pages += all.pages;
        recent.seconds += last.seconds; recent.sessions += last.sessions; recent.pages += last.pages;
        const title = hasEbooks() ? db.prepare('SELECT i.title FROM issues i WHERE i.id=?').get(issueId)?.title : null;
        books.push({ issue_id: issueId, title: title || null, ...all, last_read: ss.length ? Math.max(...ss.map((s) => s.end)) : null });
      }
      books.sort((a, b) => (b.last_read || 0) - (a.last_read || 0));
      return { total, recent: { days: Math.max(1, Number(days) || 7), ...recent }, books: books.slice(0, Math.max(1, Number(limit) || 10)) };
    },

    // ---- devices ----------------------------------------------------------------
    touchDevice(userId, { device_id, name, model, plugin_version, last_issue_id, synced = false } = {}) {
      if (!device_id) return;
      const stamp = now();
      db.prepare(`INSERT INTO koreader_devices (user_id, device_id, name, model, plugin_version, last_seen, last_sync_at, last_issue_id)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(user_id, device_id) DO UPDATE SET
          name = COALESCE(excluded.name, koreader_devices.name), model = COALESCE(excluded.model, koreader_devices.model),
          plugin_version = COALESCE(excluded.plugin_version, koreader_devices.plugin_version), last_seen = excluded.last_seen,
          last_sync_at = COALESCE(excluded.last_sync_at, koreader_devices.last_sync_at),
          last_issue_id = COALESCE(excluded.last_issue_id, koreader_devices.last_issue_id)`)
        .run(userId || 0, String(device_id).slice(0, 100), name ? String(name).slice(0, 100) : null, model ? String(model).slice(0, 100) : null,
          plugin_version ? String(plugin_version).slice(0, 40) : null, stamp, synced ? stamp : null,
          Number.isFinite(Number(last_issue_id)) ? Number(last_issue_id) : null);
    },

    /** The user's devices, most recently seen first, with what each read last. */
    devices(userId) {
      const rows = db.prepare('SELECT * FROM koreader_devices WHERE user_id=? ORDER BY last_seen DESC').all(userId || 0);
      return rows.map((r) => {
        const last = r.last_issue_id && hasEbooks() ? db.prepare('SELECT title FROM issues WHERE id=?').get(r.last_issue_id) : null;
        const hl = db.prepare('SELECT COUNT(*) c FROM koreader_highlights WHERE user_id=? AND device_id=? AND deleted_at IS NULL').get(userId || 0, r.device_id).c;
        const ev = db.prepare('SELECT COUNT(*) c FROM koreader_reading_events WHERE user_id=? AND device_id=?').get(userId || 0, r.device_id).c;
        const books = db.prepare('SELECT COUNT(*) c FROM koreader_progress WHERE user_id=? AND device_id=?').get(userId || 0, r.device_id).c;
        return {
          device_id: r.device_id, name: r.name || r.model || r.device_id, model: r.model, plugin_version: r.plugin_version,
          last_seen: r.last_seen, last_sync_at: r.last_sync_at, last_book: last?.title || null, last_issue_id: r.last_issue_id,
          books, highlights: hl, events: ev,
        };
      });
    },

    forgetDevice(userId, deviceId) {
      return db.prepare('DELETE FROM koreader_devices WHERE user_id=? AND device_id=?').run(userId || 0, String(deviceId)).changes;
    },

    // ---- fingerprints -------------------------------------------------------
    /** The issue a fingerprint belongs to (size narrows a collision), or null. */
    lookup(fp, size) {
      const clean = String(fp || '').toLowerCase().trim();
      if (!/^[0-9a-f]{32}$/.test(clean)) return null;
      const rows = db.prepare('SELECT issue_id, size FROM koreader_fingerprints WHERE fp = ?').all(clean);
      if (!rows.length) return null;
      const n = Number(size);
      const hit = (Number.isFinite(n) && rows.find((r) => r.size === n)) || rows[0];
      return hit.issue_id;
    },

    /** Local book files with no fingerprint yet, or whose size/mtime moved. */
    pendingFingerprints(limit = 500) {
      if (!hasEbooks()) return [];
      return db.prepare(`SELECT ef.issue_id, ef.path, ef.size, ef.mtime FROM ebooks_files ef
        LEFT JOIN koreader_fingerprints k ON k.issue_id = ef.issue_id
        WHERE ef.path IS NOT NULL AND (k.issue_id IS NULL OR k.size IS NOT ef.size OR k.mtime IS NOT ef.mtime)
        LIMIT ?`).all(Math.max(1, Number(limit) || 500));
    },

    saveFingerprint(issueId, { fp, size, mtime }) {
      db.prepare(`INSERT INTO koreader_fingerprints (issue_id, fp, size, mtime, computed_at) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(issue_id) DO UPDATE SET fp = excluded.fp, size = excluded.size, mtime = excluded.mtime, computed_at = excluded.computed_at`)
        .run(Number(issueId), String(fp), size ?? null, mtime ?? null, now());
    },

    /** Fingerprint every pending file; a file that can't be read is skipped
     *  and tried again next pass. Returns how many were done. */
    async fingerprintPending({ limit = 500, log = () => {} } = {}) {
      if (typeof fingerprintFile !== 'function') return 0;
      let done = 0;
      for (const r of this.pendingFingerprints(limit)) {
        try {
          const f = await fingerprintFile(r.path);
          // Record the catalog's own size/mtime so the pending check compares
          // like with like (the ebooks scanner rounds mtime its own way).
          this.saveFingerprint(r.issue_id, { fp: f.fp, size: r.size, mtime: r.mtime });
          done++;
        } catch (e) { log(`koreader: could not fingerprint ${r.path}: ${e?.message || e}`); }
      }
      return done;
    },

    /** Drop fingerprints of books that left the catalog. */
    pruneFingerprints() {
      if (!hasEbooks()) return 0;
      return db.prepare('DELETE FROM koreader_fingerprints WHERE issue_id NOT IN (SELECT issue_id FROM ebooks_files)').run().changes;
    },

    close() { try { db.close(); } catch { /* already closed */ } },
  };
}
