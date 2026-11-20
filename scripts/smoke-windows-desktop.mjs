// Run only on a disposable Windows runner. Click the production UI and check independent OS state.
import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';

assert.equal(process.platform, 'win32');
assert.equal(process.env.RUNNER_ENVIRONMENT, 'github-hosted');
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
const route = async (address = '192.0.2.123') => (await promisify(execFile)('python', ['scripts/windows_routes.py', address])).stdout.trim();
const initialProxy = await proxy();
const initialRoute = await route();
const gateway = await ps(`([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { $_.GetIPProperties().GetIPv4Properties().Index -eq ${Number(initialRoute)} }).GetIPProperties().GatewayAddresses.Address.IPAddressToString | Where-Object { $_ -match '^[0-9.]+$' } | Select-Object -First 1`);
assert.ok(Number(initialRoute) > 0);
const port = await unusedPort();
assert.ok(!fs.existsSync(data), 'Expected a fresh user profile');
fs.mkdirSync(data, { recursive: true });
fs.writeFileSync(path.join(data, 'mihomo.json'), JSON.stringify({
  'mixed-port': port, mode: 'rule', ipv6: false, 'log-level': 'info',
  hosts: { 'xeyl-acceptance.test': '127.0.0.1' },
  rules: ['IP-CIDR,192.0.2.123/32,REJECT,no-resolve', 'MATCH,DIRECT'],
}));

let app;
const labels = {
  sideSysProxy: '系统代理开关', sideTunToggle: '虚拟网卡开关',
  sheetConfirmCancel: '取消', sheetConfirmOk: '继续授权',
};

async function control(id, action = 'click') {
  await promisify(execFile)('powershell.exe', ['-NoProfile', '-NonInteractive', '-STA', '-File',
    'scripts/windows-desktop-control.ps1', app.pid.toString(), id.slice(1), labels[id.slice(1)], action],
  { timeout: 50000 });
}

async function launch() {
  app = spawn(exe, [], { stdio: 'inherit' });
  await waitToggle('#sideSysProxy', false);
}

async function terminate() {
  if (!app || app.exitCode !== null || app.signalCode !== null) return;
  const exited = once(app, 'exit');
  app.kill();
  await exited;
}

async function toggle(id, checked) {
  await control(id);
  await waitToggle(id, checked);
}

function waitToggle(id, checked) {
  return control(id, checked ? 'On' : 'Off');
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

  await control('#sideTunToggle');
  await control('#sheetConfirmCancel');
  await waitToggle('#sideTunToggle', false);
  assert.equal(await route(), initialRoute);
  await control('#sideTunToggle');
  await control('#sheetConfirmOk');
  await waitToggle('#sideTunToggle', true);
  const activeRoute = await route();
  assert.ok(Number(activeRoute) > 0 && activeRoute !== initialRoute);
  let failoverError;
  try {
    assert.equal(net.isIPv4(gateway), true, 'Expected an IPv4 gateway for the test uplink');
    const routeArgs = ['interface', 'ipv4', 'route', 'prefix=192.0.2.123/32',
      'interface=' + initialRoute, 'nexthop=' + gateway, 'store=active'];
    const netsh = (action, ...extra) => promisify(execFile)('netsh.exe',
      [...routeArgs.slice(0, 2), action, ...routeArgs.slice(2), ...extra]);
    await netsh('add', 'metric=1');
    try {
      await until('test address to return to the original interface', async () => (await route()) === initialRoute);
    } finally {
      await netsh('delete');
    }
    await until('TUN route after deleting the host route', async () => (await route()) === activeRoute);
    console.log('Windows moved the test address from TUN to the uplink and back.');
  } catch (error) {
    failoverError = error;
    console.error('Interface change:', error.message);
  }
  await promisify(execFile)('curl.exe', ['--noproxy', '*', '--max-time', '3', 'http://192.0.2.123:18080/']).catch(() => {});
  await until('actual TUN decision', () => fs.readFileSync(path.join(data, 'mihomo.log'), 'utf8')
    .split('\n').some(line => line.includes('192.0.2.123:18080') && line.includes('REJECT')));
  await control('#sideTunToggle');
  await waitToggle('#sideTunToggle', false);
  assert.equal(await route(), initialRoute);
  console.log('App confirmation cancel/accept, global TUN traffic and normal route restoration passed.');

  await toggle('#sideSysProxy', true);
  await control('#sideTunToggle');
  await control('#sheetConfirmOk');
  await waitToggle('#sideTunToggle', true);
  assert.ok(fs.existsSync(journal));
  await terminate();
  await until('TUN lease release after abrupt exit', async () => (await route()) === initialRoute);
  await launch();
  await until('automatic recovery after abrupt exit', () => !fs.existsSync(journal));
  assert.equal(await proxy(), initialProxy);
  assert.equal(await route(), initialRoute);
  console.log('Desktop restart after abrupt exit restored the original settings.');

  await toggle('#sideSysProxy', true);
  await promisify(execFile)('powershell.exe', ['-NoProfile', '-NonInteractive', '-STA', '-File',
    'scripts/windows-tray-quit.ps1', 'RoutePilot · 系统代理', '退出 RoutePilot'], { timeout: 30000 });
  await until('normal exit through the tray', () => app.exitCode === 0);
  assert.equal(await proxy(), initialProxy);
  assert.ok(!fs.existsSync(journal));
  console.log('Quit through the system tray restored the original proxy settings.');
  if (failoverError) throw failoverError;
} catch (error) {
  console.error('Desktop processes:', await ps('Get-Process routepilot-desktop,msedgewebview2 -ErrorAction SilentlyContinue | Select-Object Name,SessionId,MainWindowTitle | Out-String').catch(() => 'unavailable'));
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
