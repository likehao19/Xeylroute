import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sha256 = data => createHash('sha256').update(data).digest('hex');

test('normal core preparation succeeds without usable WinDivert archives', () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'xeylroute-core-test-'));
  try {
    const scripts = path.join(workspace, 'scripts');
    const binaries = path.join(workspace, 'src-tauri', 'binaries');
    fs.mkdirSync(scripts, { recursive: true });
    fs.mkdirSync(binaries, { recursive: true });
    const lock = JSON.parse(fs.readFileSync(path.join(root, 'scripts/core-lock.json'), 'utf8'));
    const patches = ['mihomo-process-instance.patch', 'mihomo-windows-tun.patch', 'mihomo-failure-fallback.patch'];
    for (const name of ['fetch-core.mjs', ...patches]) {
      fs.copyFileSync(path.join(root, 'scripts', name), path.join(scripts, name));
    }
    const target = 'x86_64-pc-windows-msvc';
    const hashes = patches.map(name => sha256(fs.readFileSync(path.join(scripts, name))));
    const key = sha256([lock.windowsSource.revision, lock.windowsSource.go, target, ...hashes].join(':'));
    const core = Buffer.from('cached core fixture');
    const cached = path.join(binaries, `mihomo-windows-${key}.exe`);
    fs.writeFileSync(cached, core);
    fs.writeFileSync(`${cached}.sha256`, sha256(core));
    // The archives pass their digest checks but cannot be extracted. Startup
    // must not depend on them when preparing the ordinary proxy core.
    const invalidArchive = Buffer.from('unusable driver archive');
    lock.winDivert.binary = sha256(invalidArchive);
    lock.winDivert.source = sha256(invalidArchive);
    fs.writeFileSync(path.join(binaries, 'WinDivert-2.2.2-A.zip'), invalidArchive);
    fs.writeFileSync(path.join(binaries, 'WinDivert-source.tar.gz'), invalidArchive);
    fs.writeFileSync(path.join(scripts, 'core-lock.json'), JSON.stringify(lock));
    execFileSync(process.execPath, [path.join(scripts, 'fetch-core.mjs'), '--target', target]);
    assert.deepEqual(fs.readFileSync(path.join(binaries, `xeylroute-mihomo-${target}.exe`)), core);
    assert.equal(fs.existsSync(path.join(binaries, 'WinDivert.dll')), false);
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
});
