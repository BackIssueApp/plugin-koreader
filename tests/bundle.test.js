// The device plugin bundle: every Lua file of the plugin, plus a defaults file
// naming the server that handed it out, zipped under backissue.koplugin/.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pluginFiles, defaultsLua, buildPluginZip } from '../bundle.js';

test('the bundle holds the plugin files and the server address', async () => {
  const files = await pluginFiles({ server: 'https://books.example.com', version: '0.1.0' });
  const names = Object.keys(files);
  for (const n of ['_meta.lua', 'main.lua', 'backissue_api.lua', 'backissue_defaults.lua']) {
    assert.ok(names.includes(`backissue.koplugin/${n}`), n);
  }
  const defaults = files['backissue.koplugin/backissue_defaults.lua'].toString();
  assert.match(defaults, /server = "https:\/\/books\.example\.com"/);
  assert.match(defaults, /version = "0\.1\.0"/);
  // The plugin's own declared version matches the server plugin's.
  assert.match(files['backissue.koplugin/main.lua'].toString(), /PLUGIN_VERSION = "0\.1\.0"/);
});

test('the server address is a safe Lua string', () => {
  const lua = defaultsLua({ server: 'https://x"y\\z\nq', version: '' });
  assert.match(lua, /server = "https:\/\/x\\"y\\\\z\\nq"/);
});

test('the zip is a zip', async () => {
  let buf;
  try { buf = await buildPluginZip({ server: 'http://localhost:8787', version: '0.1.0' }); }
  catch (e) { if (/Cannot find package 'jszip'/.test(String(e?.message))) return; throw e; } // outside an app tree
  assert.equal(buf.subarray(0, 2).toString(), 'PK');
  const { default: JSZip } = await import('jszip');
  const z = await JSZip.loadAsync(buf);
  assert.ok(z.file('backissue.koplugin/main.lua'));
  assert.match(await z.file('backissue.koplugin/backissue_defaults.lua').async('string'), /localhost:8787/);
});
