import assert from 'node:assert/strict';
import { test } from 'node:test';
import { evaluateRoute, programRuleFields } from '../src/routing-engine.mjs';

function makeState() {
  return {
    connected: true,
    mode: 'global',
    systemProxy: true,
    tun: false,
    tunScope: 'all',
    fallback: true,
    selectedNodeId: 'n1',
    defaultRuleExit: 'global-follow',
    nodes: [
      { id: 'n1', name: '新加坡 01', delay: 38 },
      { id: 'n2', name: '香港 02', delay: 24 },
      { id: 'n3', name: '日本 01', delay: 62 },
    ],
    groups: [
      { id: 'g1', name: '开发工具', exit: 'n3', tun: false, on: true },
      { id: 'g2', name: 'AI 服务', exit: 'n2', tun: true, on: true },
    ],
    rules: [
      { id: 'r1', kind: 'app', label: 'Codex', value: 'Codex.exe', path: 'C:/Apps/Codex/Codex.exe', group: 'g1', exit: '', tun: 'inherit', on: true },
      { id: 'r2', kind: 'website', label: 'GitHub', value: '*.github.com', group: 'g1', exit: '', tun: 'inherit', on: true },
    ],
  };
}

test('uses the proper exit in each routing mode', () => {
  const state = makeState();
  const connection = { host: 'github.com' };
  assert.equal(evaluateRoute(state, connection).action, '新加坡 01');
  state.mode = 'rule';
  assert.equal(evaluateRoute(state, connection).action, '日本 01');
  state.mode = 'direct';
  assert.equal(evaluateRoute(state, connection).action, 'DIRECT');
});

test('TUN off overrides a matching group/website; system proxy still applies', () => {
  const state = makeState();
  state.mode = 'rule';
  state.tun = true;
  state.tunScope = 'selected';
  state.groups[0].tun = true;
  state.rules[0].tun = 'off';
  const connection = { path: state.rules[0].path, host: 'github.com', systemProxy: false };
  assert.equal(evaluateRoute(state, connection).capture, '未接管');
  assert.equal(evaluateRoute(state, { ...connection, systemProxy: true }).capture, '系统代理');
});

test('reject wins and an AUTO failure tries another candidate', () => {
  const state = makeState();
  const connection = { path: state.rules[0].path, host: 'github.com' };
  state.mode = 'rule';
  state.rules[0].exit = 'direct';
  state.rules[1].exit = 'reject';
  assert.equal(evaluateRoute(state, connection).action, 'REJECT');

  state.mode = 'global';
  state.selectedNodeId = 'auto';
  const original = evaluateRoute(state, connection).action;
  const failed = evaluateRoute(state, { ...connection, failed: true });
  assert.notEqual(failed.action, original);
  assert.match(failed.reason, /备用节点/);
});

test('a restarted process matches the persistent app rule only', () => {
  const state = makeState();
  state.mode = 'rule';
  const executable = { name: 'App', exe: 'App.exe', path: '/Applications/App.app/Contents/MacOS/App', pid: 7, startedAt: '1' };
  state.rules.push(
    { ...programRuleFields(executable, 'app'), id: 'ra', exit: 'n1', on: true },
    { ...programRuleFields(executable, 'process'), id: 'rp', exit: 'n2', on: true },
  );
  assert.equal(evaluateRoute(state, { ...executable, host: 'example.com' }).action, '香港 02');
  assert.equal(evaluateRoute(state, { ...executable, startedAt: '2', host: 'example.com' }).action, '新加坡 01');
});
