import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';

const source = fs.readFileSync('routepilot-v08-fixed.html', 'utf8');
const script = source.slice(source.indexOf('<script>') + 8, source.lastIndexOf('</script>'));
const take = (first, last) => {
  const start = script.indexOf(first);
  const end = script.indexOf(last, start);
  assert.ok(start >= 0 && end > start, first);
  return script.slice(start, end);
};

function model() {
  const defaults = take('const DEFAULT=', '\nlet db;');
  const exits = take('const builtInExits', 'function navigate');
  const processes = take('const normalizedPath', 'function showFastAssign');
  const routes = take('function resolveExit', "document.addEventListener('click'");
  return new Function(defaults + 'const db=DEFAULT;' + exits + processes + routes +
    'return {db,route,programRuleFields};')();
}

test('uses the proper exit in each routing mode', () => {
  const { db, route } = model();
  const connection = { host: 'github.com' };
  assert.equal(route(connection).action, db.nodes[0].name);
  db.routingMode = 'rule';
  assert.equal(route(connection).action, db.nodes[2].name);
  db.routingMode = 'direct';
  assert.equal(route(connection).action, '直连');
});

test('TUN off overrides a matching website; system proxy still applies', () => {
  const { db, route } = model();
  db.routingMode = 'rule';
  db.network.tun = true;
  db.network.tunScope = 'selected';
  db.groups[1].tun = true;
  db.rules[0].tun = false;
  const connection = { path: db.rules[0].path, host: 'github.com', systemProxy: false };
  assert.equal(route(connection).capture, '未接管');
  assert.equal(route({ ...connection, systemProxy: true }).capture, '系统代理');
});

test('reject wins and an AUTO failure tries another candidate', () => {
  const { db, route } = model();
  const connection = { path: db.rules[0].path, host: 'github.com' };
  db.routingMode = 'rule';
  db.groups[0].node = 'direct';
  db.groups[1].node = 'reject';
  assert.equal(route(connection).action, '阻断');
  db.routingMode = 'global';
  db.globalNode = 'auto';
  const original = route(connection).action;
  const failed = route({ ...connection, failed: true });
  assert.notEqual(failed.action, original);
  assert.match(failed.reason, /备用节点/);
});

test('a restarted process matches the persistent rule only', () => {
  const { db, route, programRuleFields } = model();
  db.routingMode = 'rule';
  const executable = { name: 'App', exe: 'App.exe', path: 'C:/Apps/App.exe', pid: 7, startedAt: 1 };
  db.rules.push(
    { ...programRuleFields(executable, 'app'), exit: 'n1', on: true },
    { ...programRuleFields(executable, 'process'), exit: 'n2', on: true },
  );
  assert.equal(route({ ...executable, host: 'example.com' }).action, db.nodes[1].name);
  assert.equal(route({ ...executable, startedAt: 2, host: 'example.com' }).action, db.nodes[0].name);
});
