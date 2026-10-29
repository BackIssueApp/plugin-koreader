// The store over a catalog shaped like core's plus the ebooks plugin's tables:
// listing (sort, search, standalone vs series, restricted), the newest-wins
// progress merge with the web reader, the mirror that clears a stale web
// locator, and fingerprints (catch-up pass, lookup, prune).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import Database from 'better-sqlite3';
import { openKoreaderStore } from '../store.js';
import { fingerprintFile, fingerprintBuffer } from '../fingerprint.js';

function seeded({ webProgress = true } = {}) {
  const db = new Database(':memory:');
  db.exec(`
    CREATE TABLE series (id INTEGER PRIMARY KEY, title TEXT, url TEXT, publisher TEXT, type TEXT DEFAULT 'comic', library_id INTEGER, restricted INTEGER DEFAULT 0);
    CREATE TABLE issues (id INTEGER PRIMARY KEY, series_id INTEGER, title TEXT, issue_number TEXT);
    CREATE TABLE libraries (id INTEGER PRIMARY KEY, name TEXT, type TEXT);
    CREATE TABLE ebooks_files (path TEXT, library_id INTEGER, series_id INTEGER, issue_id INTEGER, format TEXT, size INTEGER, mtime INTEGER, source TEXT, remote_id TEXT, added_at TEXT);
    INSERT INTO libraries VALUES (1,'Fiction','ebook'),(3,'Adult','ebook');
    INSERT INTO series VALUES (10,'Dune','ebook:l1:b:dune~herbert','Frank Herbert','ebook',1,0);
    INSERT INTO issues VALUES (100,10,'Dune','1');
    INSERT INTO ebooks_files VALUES ('/lib/dune.epub',1,10,100,'epub',500000,1000,NULL,NULL,'2026-01-01T00:00:00Z');
    INSERT INTO series VALUES (11,'Discworld','ebook:l1:s:discworld','Terry Pratchett','ebook',1,0);
    INSERT INTO issues VALUES (101,11,'Mort','4'),(102,11,'Guards! Guards!','8');
    INSERT INTO ebooks_files VALUES ('/lib/mort.pdf',1,11,101,'pdf',900000,2000,NULL,NULL,'2026-02-01T00:00:00Z');
    INSERT INTO ebooks_files VALUES (NULL,1,11,102,'epub',NULL,NULL,'warehouse','g8',  '2026-03-01T00:00:00Z');
    INSERT INTO series VALUES (12,'Secret','ebook:l3:b:secret','Anon','ebook',3,1);
    INSERT INTO issues VALUES (103,12,'Secret','1');
    INSERT INTO ebooks_files VALUES ('/adult/secret.epub',3,12,103,'epub',1000,3000,NULL,NULL,'2026-04-01T00:00:00Z');
    INSERT INTO series VALUES (20,'Batman','cv:1','DC','comic',2,0);
    INSERT INTO issues VALUES (200,20,'Batman #1','1');
  `);
  if (webProgress) {
    db.exec(`CREATE TABLE ebooks_progress (user_id INTEGER NOT NULL DEFAULT 0, issue_id INTEGER NOT NULL, locator TEXT,
      fraction REAL NOT NULL DEFAULT 0, updated_at TEXT, chapter TEXT, page INTEGER, pages INTEGER, PRIMARY KEY (user_id, issue_id));`);
  }
  return db;
}

test('lists books by title with authors, series and a download path', () => {
  const s = openKoreaderStore(seeded());
  const { total, books } = s.listBooks({ userId: 7 });
  assert.equal(total, 4);
  assert.deepEqual(books.map((b) => b.title), ['Dune', 'Guards! Guards!', 'Mort', 'Secret']);
  const dune = books[0];
  assert.equal(dune.series, null, 'a standalone book has no series');
  assert.deepEqual(dune.authors, ['Frank Herbert']);
  assert.equal(dune.filename, 'dune.epub');
  assert.equal(dune.download, '/api/ebooks/issue/100/file?dl=1');
  assert.equal(dune.library, 'Fiction');
  const mort = books.find((b) => b.id === 101);
  assert.equal(mort.series, 'Discworld');
  assert.equal(mort.series_index, '4');
  assert.equal(mort.format, 'pdf');
  const remote = books.find((b) => b.id === 102);
  assert.equal(remote.remote, true);
  assert.equal(remote.filename, 'Guards! Guards!.epub');
});

test('recent sort, search by word, paging and restricted gating', () => {
  const s = openKoreaderStore(seeded());
  assert.deepEqual(s.listBooks({ sort: 'recent' }).books.map((b) => b.id), [103, 102, 101, 100]);
  assert.deepEqual(s.listBooks({ q: 'pratchett guards' }).books.map((b) => b.id), [102]);
  assert.deepEqual(s.listBooks({ q: '100%' }).books, [], 'a LIKE wildcard in the query is literal');
  const page = s.listBooks({ limit: 2, offset: 2 });
  assert.equal(page.total, 4);
  assert.deepEqual(page.books.map((b) => b.id), [101, 103]);
  const visible = s.listBooks({ includeRestricted: false });
  assert.equal(visible.total, 3);
  assert.ok(!visible.books.some((b) => b.id === 103));
  assert.equal(s.book(103, { includeRestricted: false }), null);
  assert.equal(s.book(103).id, 103);
  assert.equal(s.book(200), null, 'a comic is not a book');
});

test('without the ebooks plugin there are no books, and nothing throws', () => {
  const db = new Database(':memory:');
  const s = openKoreaderStore(db);
  assert.equal(s.hasEbooks(), false);
  assert.deepEqual(s.listBooks(), { total: 0, books: [] });
  assert.equal(s.book(1), null);
  assert.equal(s.progress(1, 1), null);
  assert.deepEqual(s.pendingFingerprints(), []);
});

test('progress: a device push is kept exactly and mirrored as a fraction; newest wins', async () => {
  const db = seeded();
  const s = openKoreaderStore(db);
  assert.equal(s.progress(7, 100), null);
  // The web reader was here first, with an exact locator.
  db.prepare("INSERT INTO ebooks_progress (user_id, issue_id, locator, fraction, updated_at) VALUES (7, 100, 'epubcfi(/6/4!/4/2)', 0.2, '2026-05-01T10:00:00Z')").run();
  let p = s.progress(7, 100);
  assert.equal(p.source, 'web');
  assert.equal(p.fraction, 0.2);
  assert.equal(p.position, null);

  const saved = s.saveProgress(7, 100, { fraction: 0.4321, position: '/body/DocFragment[5]/body/p[12]/text().0', kind: 'xpointer', device: 'Kobo Clara', device_id: 'dev-1' });
  assert.equal(saved.kind, 'xpointer');
  p = s.progress(7, 100);
  assert.equal(p.source, 'koreader');
  assert.equal(p.device, 'Kobo Clara');
  assert.equal(p.device_id, 'dev-1');
  assert.equal(p.position, '/body/DocFragment[5]/body/p[12]/text().0');
  assert.equal(p.fraction, 0.4321);
  const web = db.prepare('SELECT locator, fraction FROM ebooks_progress WHERE user_id=7 AND issue_id=100').get();
  assert.equal(web.locator, null, 'the stale web locator is cleared');
  assert.equal(web.fraction, 0.4321);

  // The web reader moves on later: it is the newest again, by fraction.
  await new Promise((r) => setTimeout(r, 1100));
  db.prepare("UPDATE ebooks_progress SET locator='epubcfi(/6/8!/4/2)', fraction=0.7, updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE user_id=7 AND issue_id=100").run();
  p = s.progress(7, 100);
  assert.equal(p.source, 'web');
  assert.equal(p.fraction, 0.7);
  assert.equal(p.position, null);

  // Another user's record is separate; a page position is kept as a page.
  s.saveProgress(8, 101, { fraction: 0.5, position: '120', kind: 'page' });
  assert.equal(s.progress(7, 101), null);
  assert.deepEqual([s.progress(8, 101).kind, s.progress(8, 101).position], ['page', '120']);
  // Garbage is clamped and unknown kinds dropped.
  const g = s.saveProgress(8, 101, { fraction: 7, position: 'x', kind: 'weird' });
  assert.deepEqual([g.fraction, g.kind], [1, null]);
});

test('progress goes through the ebooks store when it is there', () => {
  const s = openKoreaderStore(seeded());
  const calls = [];
  s.saveProgress(7, 100, { fraction: 0.3 }, { ebooks: { saveProgress: (u, i, p) => calls.push([u, i, p]) } });
  assert.deepEqual(calls, [[7, 100, { locator: null, fraction: 0.3 }]]);
});

test('progress mirror works without the ebooks_progress table', () => {
  const s = openKoreaderStore(seeded({ webProgress: false }));
  s.saveProgress(7, 100, { fraction: 0.3, position: 'p', kind: 'xpointer' });
  assert.equal(s.progress(7, 100).source, 'koreader');
  assert.equal(s.listBooks({ userId: 7 }).books[0].fraction, 0.3, 'the list still shows progress');
});

test('fingerprints: catch-up pass over local files, lookup by fp and size, prune', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'koreader-'));
  const a = path.join(dir, 'a.epub');
  const b = path.join(dir, 'b.pdf');
  await fs.writeFile(a, Buffer.alloc(200_000, 1));
  await fs.writeFile(b, Buffer.alloc(300, 2));
  const db = seeded();
  db.prepare('UPDATE ebooks_files SET path=? WHERE issue_id=100').run(a);
  db.prepare('UPDATE ebooks_files SET path=? WHERE issue_id=101').run(b);
  db.prepare('UPDATE ebooks_files SET path=? WHERE issue_id=103').run(path.join(dir, 'missing.epub'));
  const s = openKoreaderStore(db, { fingerprintFile });
  assert.equal(s.pendingFingerprints().length, 3, 'file-less remote books are not pending');
  const warnings = [];
  assert.equal(await s.fingerprintPending({ log: (m) => warnings.push(m) }), 2);
  assert.equal(warnings.length, 1, 'the missing file is reported, not fatal');
  assert.equal(s.pendingFingerprints().length, 1, 'and stays pending');

  const fa = fingerprintBuffer(Buffer.alloc(200_000, 1));
  assert.equal(s.lookup(fa.fp, fa.size), 100);
  assert.equal(s.lookup(fa.fp.toUpperCase(), 'nope'), 100, 'size only disambiguates');
  assert.equal(s.lookup('not-a-hash'), null);
  assert.equal(s.lookup('0'.repeat(32), 1), null);

  // A changed file (size/mtime moved in the catalog) is fingerprinted again.
  db.prepare('UPDATE ebooks_files SET mtime=9999 WHERE issue_id=100').run();
  assert.ok(s.pendingFingerprints().some((r) => r.issue_id === 100));

  db.prepare('DELETE FROM ebooks_files WHERE issue_id=101').run();
  assert.equal(s.pruneFingerprints(), 1);
  assert.equal(s.lookup(fingerprintBuffer(Buffer.alloc(300, 2)).fp, 300), null);
  await fs.rm(dir, { recursive: true, force: true });
});
