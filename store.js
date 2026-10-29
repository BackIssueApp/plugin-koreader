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
  `);

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
    download: `/api/ebooks/issue/${r.issue_id}/file?dl=1`,
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
    s.title AS series_title, s.url AS series_url, s.publisher, l.name AS library_name, p.fraction`;

  return {
    db,
    hasEbooks,

    /** One page of the Books library, as a device lists it. */
    listBooks({ userId = 0, q = '', offset = 0, limit = 100, sort = 'title', includeRestricted = true } = {}) {
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
      const whereSql = conds.length ? ' AND ' + conds.join(' AND ') : '';
      const order = sort === 'recent'
        ? 'ORDER BY ef.added_at DESC, ef.rowid DESC'
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

    /** The newest position for a book across KOReader devices and the web
     *  reader: { fraction, position, kind, device, device_id, source,
     *  updated_at } or null. The web reader's record carries no KOReader
     *  position, so a device landing on it goes by percentage. */
    progress(userId, issueId) {
      const ko = db.prepare('SELECT fraction, position, kind, device, device_id, updated_at FROM koreader_progress WHERE user_id=? AND issue_id=?')
        .get(userId || 0, Number(issueId)) || null;
      let web = null;
      if (hasWebProgress()) {
        const w = db.prepare('SELECT fraction, updated_at FROM ebooks_progress WHERE user_id=? AND issue_id=?').get(userId || 0, Number(issueId));
        if (w) web = { fraction: w.fraction, position: null, kind: null, device: null, device_id: null, updated_at: w.updated_at };
      }
      if (!ko && !web) return null;
      // Each KOReader push is mirrored into the web record with the same
      // stamp, so a web record strictly newer than the KOReader one means the
      // web reader moved since.
      const pick = !web || (ko && String(ko.updated_at || '') >= String(web.updated_at || '')) ? { ...ko, source: 'koreader' } : { ...web, source: 'web' };
      return pick;
    },

    /** A device's position. Mirrors the fraction into the web reader's record
     *  (through the ebooks store when given, so reading stats count it). */
    saveProgress(userId, issueId, { fraction, position, kind, device, device_id } = {}, { ebooks } = {}) {
      const f = Math.min(1, Math.max(0, Number(fraction) || 0));
      const k = kind === 'page' || kind === 'xpointer' ? kind : null;
      const pos = position == null || position === '' ? null : String(position).slice(0, 2000);
      const stamp = now();
      db.prepare(`INSERT INTO koreader_progress (user_id, issue_id, fraction, position, kind, device, device_id, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(user_id, issue_id) DO UPDATE SET fraction = excluded.fraction, position = excluded.position,
          kind = excluded.kind, device = excluded.device, device_id = excluded.device_id, updated_at = excluded.updated_at`)
        .run(userId || 0, Number(issueId), f, pos, k, device ? String(device).slice(0, 100) : null, device_id ? String(device_id).slice(0, 100) : null, stamp);
      // The web reader resumes by its own locator when it has one; after a
      // device moved the book on, that locator is stale, so it is cleared and
      // the fraction stands (the reader falls back to it).
      if (ebooks && typeof ebooks.saveProgress === 'function') {
        try { ebooks.saveProgress(userId || 0, Number(issueId), { locator: null, fraction: f }); } catch { /* the device record is what matters */ }
      } else if (hasWebProgress()) {
        db.prepare(`INSERT INTO ebooks_progress (user_id, issue_id, locator, fraction, updated_at) VALUES (?, ?, NULL, ?, ?)
          ON CONFLICT(user_id, issue_id) DO UPDATE SET locator = NULL, fraction = excluded.fraction, updated_at = excluded.updated_at`)
          .run(userId || 0, Number(issueId), f, stamp);
      }
      return { fraction: f, position: pos, kind: k, updated_at: stamp };
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
