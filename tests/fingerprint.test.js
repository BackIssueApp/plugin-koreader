// The fingerprint reads only the first and last 64 KiB, so it is the same
// however the file is read, and blind to changes in the middle — which is what
// makes it cheap enough to compute for every book at scan time.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fingerprintBuffer, fingerprintFile, WINDOW } from '../fingerprint.js';

const md5 = (...parts) => { const h = createHash('md5'); for (const p of parts) h.update(p); return h.digest('hex'); };

test('buffer and file agree, for files smaller, equal to and larger than the window', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-'));
  for (const size of [0, 10, WINDOW - 1, WINDOW, WINDOW + 1, 3 * WINDOW + 17]) {
    const buf = Buffer.from(Array.from({ length: size }, (_, i) => (i * 7 + size) & 255));
    const p = path.join(dir, `f${size}`);
    await fs.writeFile(p, buf);
    const a = fingerprintBuffer(buf);
    const b = await fingerprintFile(p);
    assert.equal(b.fp, a.fp, `size ${size}`);
    assert.equal(b.size, size);
    assert.ok(Number.isInteger(b.mtime));
  }
  await fs.rm(dir, { recursive: true, force: true });
});

test('is MD5(head + tail) exactly as the device computes it', () => {
  const big = Buffer.from(Array.from({ length: 200_000 }, (_, i) => i & 255));
  assert.equal(fingerprintBuffer(big).fp, md5(big.subarray(0, WINDOW), big.subarray(big.length - WINDOW)));
  const small = Buffer.from('hello');
  assert.equal(fingerprintBuffer(small).fp, md5(small, small), 'a small file hashes its whole content twice');
});

test('a change in the middle is invisible; a change at either end is not', () => {
  const buf = Buffer.alloc(300_000, 5);
  const base = fingerprintBuffer(buf).fp;
  const mid = Buffer.from(buf); mid[150_000] = 6;
  assert.equal(fingerprintBuffer(mid).fp, base);
  const head = Buffer.from(buf); head[0] = 6;
  assert.notEqual(fingerprintBuffer(head).fp, base);
  const tail = Buffer.from(buf); tail[299_999] = 6;
  assert.notEqual(fingerprintBuffer(tail).fp, base);
});
