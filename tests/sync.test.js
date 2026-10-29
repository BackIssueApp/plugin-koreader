// The sync additions: browse views (continue reading, authors, series,
// descriptions), reading status, the sweep's stale-position skip, devices,
// highlights kept and mirrored with web edits and deletes folded back, and
// page events grouped into sittings.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openKoreaderStore } from '../store.js';
import { seeded } from './seed.js';

test('browse views: continue reading, authors, series, description', () => {
  const db = seeded();
  db.prepare("UPDATE series SET description='A desert planet.' WHERE id=10").run();
  db.prepare("UPDATE series SET publisher='Terry Pratchett, Neil Gaiman' WHERE id=11").run();
  const s = openKoreaderStore(db);
  s.saveProgress(7, 101, { fraction: 0.5, position: '12', kind: 'page' });
  s.saveProgress(7, 100, { fraction: 0.99 });
  s.saveProgress(7, 102, { fraction: 0.1 });
  const cont = s.listBooks({ userId: 7, sort: 'progress' });
  assert.deepEqual(cont.books.map((b) => b.id), [102, 101], 'finished books drop out; newest read first');
  assert.equal(s.book(100, { userId: 7 }).finished, true);
  assert.equal(s.book(100).description, 'A desert planet.');
  assert.deepEqual(s.authors().map((a) => [a.name, a.books]),
    [['Anon', 1], ['Frank Herbert', 1], ['Neil Gaiman', 2], ['Terry Pratchett', 2]]);
  assert.deepEqual(s.authors({ includeRestricted: false }).map((a) => a.name), ['Frank Herbert', 'Neil Gaiman', 'Terry Pratchett']);
  assert.deepEqual(s.listBooks({ author: 'Neil Gaiman' }).books.map((b) => b.id), [102, 101]);
  assert.deepEqual(s.listBooks({ author: 'Gaiman' }).books, [], 'a whole name, not a fragment');
  assert.deepEqual(s.seriesList().map((x) => [x.id, x.title, x.books]), [[11, 'Discworld', 2]], 'a standalone book is not a series');
  assert.deepEqual(s.listBooks({ seriesId: 11 }).books.map((b) => b.title), ['Mort', 'Guards! Guards!'], 'in reading order');
});

test('status: complete marks the book finished; a sweep skips stale positions; devices are noted', () => {
  const db = seeded();
  const s = openKoreaderStore(db);
  const r = s.saveProgress(7, 100, { fraction: 0.6, status: 'complete', device_id: 'd1', device: 'Kobo' });
  assert.equal(r.fraction, 1);
  assert.equal(s.progress(7, 100).finished, true);
  assert.equal(s.progress(7, 100).status, 'complete');
  // A later push without a status keeps the one we have.
  s.saveProgress(7, 100, { fraction: 0.7 });
  assert.equal(s.progress(7, 100).status, 'complete');
  assert.equal(s.saveProgress(7, 100, { fraction: 0.7, status: 'weird' }).status, null);
  // A sweep sends the device's last-access time: older than the record → skipped.
  const old = s.saveProgress(7, 100, { fraction: 0.2, at: Math.floor(Date.now() / 1000) - 3600 });
  assert.equal(old.skipped, true);
  assert.equal(s.progress(7, 100).fraction, 0.7);
  const fresh = s.saveProgress(7, 100, { fraction: 0.8, at: Math.floor(Date.now() / 1000) + 5 });
  assert.equal(fresh.skipped, undefined);
  assert.equal(s.progress(7, 100).fraction, 0.8);
  // The file changed under the position: flagged.
  assert.equal(s.progress(7, 100).file_changed_at, null);
  s.saveFingerprint(100, { fp: 'a'.repeat(32), size: 1, mtime: Date.now() + 60_000 });
  assert.ok(s.progress(7, 100).file_changed_at);
  // Devices were noted along the way.
  const devs = s.devices(7);
  assert.equal(devs.length, 1);
  assert.equal(devs[0].name, 'Kobo');
  assert.equal(devs[0].last_book, 'Dune');
  assert.ok(devs[0].last_sync_at);
  assert.equal(s.forgetDevice(7, 'd1'), 1);
  assert.equal(s.devices(7).length, 0);
});

test('highlights: the device list is kept, mirrored, and web edits and deletes fold back', () => {
  const db = seeded();
  const s = openKoreaderStore(db);
  const h1 = { key: '2026-10-29 10:00:00|/body/p[1]', kind: 'xpointer', pos0: '/body/p[1]/text().0', pos1: '/body/p[1]/text().20', text: 'Fear is the mind-killer', color: 'yellow', drawer: 'lighten', fraction: 0.12, chapter: 'One', created_at: '2026-10-29 10:00:00' };
  const h2 = { key: '2026-10-29 10:05:00|/body/p[9]', kind: 'xpointer', pos0: '/body/p[9]/text().0', pos1: '/body/p[9]/text().9', text: 'Arrakis', note: 'look up', fraction: 0.3, created_at: '2026-10-29 10:05:00' };
  let r = s.syncHighlights(7, 100, { items: [h1, h2], device: 'Kobo', device_id: 'd1' });
  assert.deepEqual(r.items.map((x) => x.key), [h1.key, h2.key]);
  assert.deepEqual(r.deleted, []);
  const mirrors = db.prepare('SELECT id, locator, text, note, color, fraction FROM ebooks_bookmarks WHERE user_id=7 AND issue_id=100 ORDER BY id').all();
  assert.equal(mirrors.length, 2, 'each highlight is a bookmark the web and the apps can list');
  assert.equal(mirrors[0].text, 'Fear is the mind-killer');
  assert.equal(mirrors[0].color, 'yellow');
  assert.equal(mirrors[1].note, 'look up');
  assert.match(mirrors[0].locator, /^koreader:xpointer:/);

  // The same list again changes nothing; a changed note on the device updates both.
  r = s.syncHighlights(7, 100, { items: [h1, { ...h2, note: 'spice', changed: true }], device_id: 'd1' });
  assert.equal(r.items[1].note, 'spice');
  assert.equal(db.prepare('SELECT note FROM ebooks_bookmarks WHERE id=?').get(mirrors[1].id).note, 'spice');
  assert.equal(db.prepare('SELECT COUNT(*) c FROM ebooks_bookmarks').get().c, 2);

  // An app edits the mirror's note: the device sees it on its next pull.
  db.prepare('UPDATE ebooks_bookmarks SET note=? WHERE id=?').run('melange', mirrors[1].id);
  assert.equal(s.highlights(7, 100).items[1].note, 'melange');
  // The web deletes the first mark: reported deleted, and a device that still
  // sends it does not bring it back.
  db.prepare('DELETE FROM ebooks_bookmarks WHERE id=?').run(mirrors[0].id);
  r = s.highlights(7, 100);
  assert.deepEqual(r.deleted, [h1.key]);
  assert.deepEqual(r.items.map((x) => x.key), [h2.key]);
  r = s.syncHighlights(7, 100, { items: [h1, h2], device_id: 'd1' });
  assert.deepEqual(r.deleted, [h1.key]);
  // The device deletes the second: gone everywhere.
  r = s.syncHighlights(7, 100, { items: [], deleted: [h2.key], device_id: 'd1' });
  assert.deepEqual(r.items, []);
  assert.equal(db.prepare('SELECT COUNT(*) c FROM ebooks_bookmarks').get().c, 0);
  assert.equal(s.pruneHighlights(30), 0, 'a fresh tombstone is kept');
  db.prepare("UPDATE koreader_highlights SET deleted_at='2020-01-01T00:00:00Z'").run();
  assert.equal(s.pruneHighlights(30), 1);
});

test('reading events become sittings: 30-minute gaps split, under 10 s dropped', () => {
  const s = openKoreaderStore(seeded());
  const t0 = Math.floor(Date.now() / 1000) - 3 * 86400;
  assert.equal(s.eventsCursor(7, 100, 'd1'), 0);
  const n = s.addEvents(7, 100, 'd1', [
    { start_time: t0, duration: 60, page: 1, pages: 300 },
    { start_time: t0 + 60, duration: 50, page: 2, pages: 300 },
    { start_time: t0 + 60, duration: 50, page: 2, pages: 300 }, // a repeat
    { start_time: t0 + 7200, duration: 5, page: 3, pages: 300 }, // two hours on: a new sitting
    { start_time: t0 + 7300, duration: 40, page: 3, pages: 300 },
    { start_time: 0, duration: 9 }, // junk
  ]);
  assert.equal(n, 4);
  assert.equal(s.eventsCursor(7, 100, 'd1'), t0 + 7300);
  assert.equal(s.eventsCursor(7, 100, 'd2'), 0, 'per device');
  s.addEvents(7, 101, 'd2', [{ start_time: t0 - 30 * 86400, duration: 600, page: 10 }]);
  const st = s.readingStats(7, { days: 7 });
  assert.deepEqual(st.total, { seconds: 755, sessions: 3, pages: 4 });
  assert.deepEqual(st.recent, { days: 7, seconds: 155, sessions: 2, pages: 3 }, 'the month-old sitting is outside the window');
  assert.deepEqual(st.books.map((b) => [b.title, b.seconds]), [['Dune', 155], ['Mort', 600]]);
  assert.equal(s.devices(7).find((d) => d.device_id === 'd1').events, 4);
});
