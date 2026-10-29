// A book's identity when the device can't say which BackIssue issue it is:
// the MD5 of the file's first and last 64 KiB. The KOReader plugin computes
// the same thing in Lua (main.lua, `fingerprint`), so the two must stay in
// step: head = bytes [0, min(64 KiB, size)); tail = bytes [max(0, size −
// 64 KiB), size). A file under 64 KiB hashes its whole content twice, which is
// fine — deterministic on both sides is all that matters.
import { createHash } from 'node:crypto';
import fsp from 'node:fs/promises';

export const WINDOW = 64 * 1024;

/** Fingerprint of an in-memory file (tests, small files). */
export function fingerprintBuffer(buf) {
  const size = buf.length;
  const h = createHash('md5');
  h.update(buf.subarray(0, Math.min(WINDOW, size)));
  h.update(buf.subarray(Math.max(0, size - WINDOW), size));
  return { fp: h.digest('hex'), size };
}

/** Fingerprint of a file on disk, reading only the two windows. */
export async function fingerprintFile(path) {
  const fh = await fsp.open(path, 'r');
  try {
    const { size, mtimeMs } = await fh.stat();
    const h = createHash('md5');
    const headLen = Math.min(WINDOW, size);
    const head = Buffer.alloc(headLen);
    if (headLen) await fh.read(head, 0, headLen, 0);
    h.update(head);
    const tailStart = Math.max(0, size - WINDOW);
    const tailLen = size - tailStart;
    const tail = Buffer.alloc(tailLen);
    if (tailLen) await fh.read(tail, 0, tailLen, tailStart);
    h.update(tail);
    return { fp: h.digest('hex'), size, mtime: Math.round(mtimeMs) };
  } finally {
    await fh.close();
  }
}
