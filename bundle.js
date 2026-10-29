// The device plugin as a zip, built on request. The server's own address is
// written into it (backissue_defaults.lua) so the person installing it only
// has to type an API key on the e-reader.
import fsp from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const KOPLUGIN_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), 'koplugin', 'backissue.koplugin');

/** Lua string literal, double-quoted. */
const luaString = (s) => '"' + String(s).replace(/[\\"]/g, (c) => '\\' + c).replace(/\n/g, '\\n') + '"';

export function defaultsLua({ server, version }) {
  return `-- Written by the BackIssue server that handed out this copy of the plugin.\n`
    + `-- Edit the server address in KOReader (BackIssue → Server) rather than here.\n`
    + `return {\n  server = ${luaString(server || '')},\n  version = ${luaString(version || '')},\n}\n`;
}

/** Every file of the device plugin as { 'backissue.koplugin/<name>': Buffer }. */
export async function pluginFiles({ server, version, dir = KOPLUGIN_DIR } = {}) {
  const out = {};
  for (const name of (await fsp.readdir(dir)).sort()) {
    if (name.startsWith('.')) continue;
    out[`backissue.koplugin/${name}`] = await fsp.readFile(path.join(dir, name));
  }
  out['backissue.koplugin/backissue_defaults.lua'] = Buffer.from(defaultsLua({ server, version }), 'utf8');
  return out;
}

/** The zip bytes. JSZip comes from the app's own dependencies. */
export async function buildPluginZip(opts = {}) {
  const { default: JSZip } = await import('jszip');
  const zip = new JSZip();
  for (const [name, buf] of Object.entries(await pluginFiles(opts))) zip.file(name, buf, { date: new Date(0) });
  return zip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE' });
}
