import { test } from 'node:test';
import assert from 'node:assert/strict';
import { groupRunningApps } from '../src/running-apps.mjs';

const process = (pid, path, name = path.split('/').at(-1)) => ({ pid, name, exe: path.split('/').at(-1), path });

test('one software row includes Codex helpers from the same Windows package', () => {
  const root = 'C:/Program Files/WindowsApps/OpenAI.Codex_26.1111.2228.0_x64__package/app';
  const desktop = [
    process(1, root + '/ChatGPT.exe', 'Codex'),
    process(2, root + '/ChatGPT.exe', 'Codex'),
    process(3, root + '/resources/codex.exe'),
    process(4, root + '/resources/codex-code-mode-host.exe'),
    process(5, root + '/resources/nested/codex-computer-use.exe'),
  ];
  const independent = process(6, 'D:/Tools/codex.exe', 'Codex CLI');
  const apps = groupRunningApps([...desktop, independent]);
  const codex = apps.find(item => item.name === 'Codex');
  assert.equal(apps.length, 2);
  assert.equal(codex.instances, 5);
  assert.equal(codex.paths.length, 4);
  assert.equal(codex.exe, 'ChatGPT.exe');
  assert.deepEqual(codex.members.map(item => item.pid).sort((a, b) => a - b), [1, 2, 3, 4, 5]);
  assert.deepEqual(apps.find(item => item.name === 'Codex CLI').paths, [independent.path]);
});

test('standalone helpers must share both the app directory and executable prefix', () => {
  const apps = groupRunningApps([
    process(1, 'D:/Apps/douyin/douyin.exe'),
    process(2, 'D:/Apps/douyin/douyin_guard.exe'),
    process(3, 'D:/Apps/douyin/8.7/tray/douyin_tray.exe'),
    process(4, 'D:/Apps/douyin/guard.exe'),
    process(5, 'E:/Apps/douyin/douyin.exe'),
    process(6, 'E:/Apps/douyin/douyin_tray.exe'),
  ]);
  assert.deepEqual(apps.map(app => app.instances).sort(), [1, 2, 3]);
});

test('macOS .app bundle groups main executable with nested Framework helper apps', () => {
  const chrome = [
    process(101, '/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)', 'Google Chrome'),
    process(102, '/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)', 'Google Chrome'),
    process(100, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', 'Google Chrome'),
  ];
  const cli = process(200, '/opt/homebrew/bin/node', 'node');
  const apps = groupRunningApps([...chrome, cli]);
  assert.equal(apps.length, 2);
  const grouped = apps.find(item => item.name === 'Google Chrome');
  assert.equal(grouped.instances, 3);
  assert.equal(grouped.exe, 'Google Chrome');
  assert.equal(grouped.paths.length, 3);
  assert.equal(grouped.paths[0], '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
});
