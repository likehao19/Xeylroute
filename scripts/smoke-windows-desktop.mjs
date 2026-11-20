// Run only on a disposable Windows runner. Click the production UI and check independent OS state.
import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs';
import http from 'node:http';
import { createRequire } from 'node:module';
import net from 'node:net';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';

assert.equal(process.platform, 'win32');
assert.equal(process.env.RUNNER_ENVIRONMENT, 'github-hosted');
const { chromium } = createRequire(path.join(process.env.RUNNER_TEMP, 'webview-test', 'package.json'))('playwright-core');
const exe = fs.realpathSync(process.argv[2]);
const data = path.join(process.env.APPDATA, 'app.routepilot.desktop', 'core');
const journal = path.join(data, 'system-proxy-recovery.json');
const ps = async command => (await promisify(execFile)('powershell.exe',
  ['-NoProfile', '-NonInteractive', '-Command', "$ErrorActionPreference='Stop'; " + command],
  { timeout: 20000 })).stdout.trim();

async function unusedPort() {
  const socket = net.createServer().listen(0, '127.0.0.1');
  await once(socket, 'listening');
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  return port;
}

async function until(description, read, timeout = 30000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const value = await read();
    if (value) return value;
    await delay(250);
  }
  throw Error('Timed out waiting for ' + description);
}

const proxy = () => ps("$s=Get-ItemProperty 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Internet Settings'; Write-Output ([string][int]$s.ProxyEnable + '|' + [string]$s.ProxyServer)");
const route = async () => (await promisify(execFile)('python', ['scripts/windows_routes.py', '192.0.2.123'])).stdout.trim();
const initialProxy = await proxy();
const initialRoute = await route();
assert.ok(Number(initialRoute) > 0);
const port = await unusedPort();
assert.ok(!fs.existsSync(data), 'Expected a fresh user profile');
fs.mkdirSync(data, { recursive: true });
fs.writeFileSync(path.join(data, 'mihomo.json'), JSON.stringify({
  'mixed-port': port, mode: 'rule', ipv6: false, 'log-level': 'info',
  hosts: { 'xeyl-acceptance.test': '127.0.0.1' },
  rules: ['IP-CIDR,192.0.2.123/32,REJECT,no-resolve', 'MATCH,DIRECT'],
}));

let app, page;
async function launch() {
  const debug = await unusedPort();
  app = spawn(exe, [], { stdio: 'inherit', env: { ...process.env,
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: '--remote-debugging-port=' + debug,
  } });
  const browser = await until('WebView2', async () => {
    assert.equal(app.exitCode, null, 'Desktop process exited');
    return chromium.connectOverCDP('http://127.0.0.1:' + debug, { timeout: 1000 }).catch(() => null);
  });
  page = await until('desktop page', () => browser.contexts().flatMap(c => c.pages())
    .find(p => p.url().includes('tauri.localhost')));
  await page.locator('#sideSysProxy').waitFor();
}

async function terminate() {
  if (!app || app.exitCode !== null || app.signalCode !== null) return;
  const exited = once(app, 'exit');
  app.kill();
  await exited;
}

async function toggle(id, checked) {
  await page.locator(id).click();
  await waitToggle(id, checked);
}

function waitToggle(id, checked) {
  return page.waitForFunction(([selector, value]) => {
    const input = document.querySelector(selector);
    return input && !input.disabled && input.checked === value;
  }, [id, checked], { timeout: 40000 });
}

const origin = http.createServer((_, res) => res.end('xeyl-local-origin')).listen(0, '127.0.0.1');
await once(origin, 'listening');
try {
  await launch();
  await toggle('#sideSysProxy', true);
  assert.equal(await proxy(), '1|127.0.0.1:' + port);
  const response = await ps(`$client=New-Object Net.WebClient; $client.Proxy=[Net.WebRequest]::GetSystemWebProxy(); $client.DownloadString('http://xeyl-acceptance.test:${origin.address().port}/')`);
  assert.equal(response, 'xeyl-local-origin');
  await toggle('#sideSysProxy', false);
  assert.equal(await proxy(), initialProxy);
  console.log('Homepage proxy switch, system-proxy HTTP request and normal switch-off passed.');

  await page.locator('#sideTunToggle').click();
  await page.locator('#sheetConfirmCancel').click();
  await waitToggle('#sideTunToggle', false);
  assert.equal(await route(), initialRoute);
  await page.locator('#sideTunToggle').click();
  await page.locator('#sheetConfirmOk').click();
  await waitToggle('#sideTunToggle', true);
  const activeRoute = await route();
  assert.ok(Number(activeRoute) > 0 && activeRoute !== initialRoute);
  await promisify(execFile)('curl.exe', ['--noproxy', '*', '--max-time', '3', 'http://192.0.2.123:18080/']).catch(() => {});
  await until('actual TUN decision', () => fs.readFileSync(path.join(data, 'mihomo.log'), 'utf8')
    .split('\n').some(line => line.includes('192.0.2.123:18080') && line.includes('REJECT')));
  await page.locator('#sideTunToggle').click();
  await waitToggle('#sideTunToggle', false);
  assert.equal(await route(), initialRoute);
  console.log('App confirmation cancel/accept, global TUN traffic and normal route restoration passed.');

  await toggle('#sideSysProxy', true);
  assert.ok(fs.existsSync(journal));
  await terminate();
  await launch();
  await until('automatic recovery after abrupt exit', () => !fs.existsSync(journal));
  assert.equal(await proxy(), initialProxy);
  assert.equal(await route(), initialRoute);
  console.log('Desktop restart after abrupt exit restored the original settings.');
} catch (error) {
  console.error('App status:', await page?.locator('#toast').textContent({ timeout: 1500 }).catch(() => 'unavailable'));
  throw error;
} finally {
  await terminate();
  origin.close();
  if (fs.existsSync(journal)) {
    app = spawn(exe, [], { stdio: 'inherit' });
    try {
      await until('cleanup of the test proxy', () => !fs.existsSync(journal));
    } finally {
      await terminate();
    }
  }
}
