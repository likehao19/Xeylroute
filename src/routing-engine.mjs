import { normalizedProgramPath } from './running-apps.mjs';

export function hostMatches(host, pattern) {
  const h = String(host || '').trim().toLowerCase();
  const p = String(pattern || '').trim().toLowerCase();
  if (!h || !p) return false;
  return p.startsWith('*.') ? (h === p.slice(2) || h.endsWith(p.slice(1))) : h === p;
}

export function programRuleFields(processInfo, kind = 'app') {
  const base = {
    kind,
    label: processInfo.name || processInfo.exe || 'Program',
    value: processInfo.exe || processInfo.path,
    path: processInfo.path,
  };
  if (kind === 'process') {
    return { ...base, pid: processInfo.pid, startedAt: processInfo.startedAt };
  }
  return base;
}

/**
 * Pure route precedence evaluator matching Xeylroute / RoutePilot spec:
 * 1. Explicit REJECT
 * 2. Explicit DIRECT
 * 3. Running Process instance (pid + startedAt + path)
 * 4. Persistent Application (path / executable)
 * 5. Exact domain
 * 6. Most-specific wildcard domain
 * 7. Default rule exit
 */
export function evaluateRoute(state, conn) {
  if (!state.connected) {
    return { capture: '已断开', action: 'DIRECT', match: '代理已暂停', reason: '当前已断开连接', tone: 'green' };
  }

  const groupById = id => (state.groups || []).find(g => g.id === id);
  const activeNodes = () => (state.nodes || []).filter(n => !n.retired);
  const bestAuto = excludeId => {
    const live = activeNodes().filter(n => n.id !== excludeId);
    if (!live.length) return null;
    return [...live].sort((a, b) => (a.delay || 9999) - (b.delay || 9999))[0];
  };
  const effectiveExitId = rule => {
    if (rule.exit && rule.exit !== 'domain-rules') return rule.exit;
    const grp = groupById(rule.group);
    if (grp && grp.on !== false && grp.exit) return grp.exit;
    return rule.exit || state.defaultRuleExit;
  };

  const connPath = normalizedProgramPath(conn.path);
  const matched = (state.rules || []).filter(rule => {
    if (rule.on === false) return false;
    if (rule.kind === 'website') return hostMatches(conn.host, rule.value);
    if (rule.kind === 'process') {
      return Boolean(
        connPath
        && normalizedProgramPath(rule.path) === connPath
        && rule.pid === conn.pid
        && rule.startedAt === conn.startedAt
      );
    }
    if (!connPath) return false;
    if (rule.path) return normalizedProgramPath(rule.path) === connPath;
    return connPath.endsWith('/' + String(rule.value || '').toLowerCase()) || connPath === String(rule.value || '').toLowerCase();
  });

  const sysProxy = conn.sysProxy ?? conn.systemProxy ?? true;
  let capture = '未接管';
  if (state.tun && (state.tunScope === 'all' || state.mode !== 'rule')) {
    capture = 'TUN 接管';
  } else if (state.tun && state.tunScope === 'selected' && state.mode === 'rule') {
    const explicitOff = matched.find(r => r.tun === 'off' || r.tun === false);
    const explicitOn = matched.find(r => r.tun === 'on' || r.tun === true);
    if (explicitOff) {
      capture = state.systemProxy && sysProxy ? '系统代理' : '未接管';
    } else if (explicitOn || matched.some(r => {
      const grp = groupById(r.group);
      return grp && grp.on !== false && grp.tun;
    })) {
      capture = '指定目标 TUN';
    } else if (state.systemProxy && sysProxy) {
      capture = '系统代理';
    }
  } else if (state.systemProxy && sysProxy) {
    capture = '系统代理';
  }

  if (capture === '未接管') {
    return { capture, action: 'DIRECT', match: '未进入接管范围', reason: '未开启对应接管或应用绕过系统代理', tone: 'green' };
  }
  if (state.mode === 'direct') {
    return { capture, action: 'DIRECT', match: '直连模式', reason: '直连模式下所有已接管流量直接访问', tone: 'green' };
  }

  const finalize = (exitId, match, reason) => {
    const id = (!exitId || exitId === 'global-follow') ? state.selectedNodeId : exitId;
    if (id === 'direct' || id === 'DIRECT') return { capture, action: 'DIRECT', match, reason, tone: 'green' };
    if (id === 'reject' || id === 'REJECT') return { capture, action: 'REJECT', match, reason, tone: 'red' };
    if (id === 'auto' || id === 'AUTO') {
      const first = bestAuto();
      if (!first) return { capture, action: state.fallback ? 'DIRECT' : 'REJECT', match, reason: `${reason} · 无可用节点`, tone: 'orange' };
      if (conn.failed) {
        const backup = bestAuto(first.id);
        if (backup) {
          return { capture, action: backup.name, match, reason: `${reason} · AUTO 故障切换至备用节点 ${backup.name}`, tone: 'orange' };
        }
        return { capture, action: state.fallback ? 'DIRECT' : 'REJECT', match, reason: `${reason} · AUTO 全部节点故障`, tone: 'red' };
      }
      return { capture, action: first.name, match, reason, tone: 'blue' };
    }
    const node = activeNodes().find(x => x.id === id || x.name === id);
    if (conn.failed || !node) {
      return {
        capture,
        action: state.fallback ? 'DIRECT' : 'REJECT',
        match,
        reason: `${reason} · 代理故障按设置${state.fallback ? '回退直连' : '阻断'}`,
        tone: state.fallback ? 'orange' : 'red',
      };
    }
    return { capture, action: node.name, match, reason, tone: 'blue' };
  };

  if (state.mode === 'global') {
    return finalize(state.selectedNodeId, '全局模式', '全局模式统一使用首页默认节点');
  }

  const wilds = matched
    .filter(r => r.kind === 'website' && String(r.value).startsWith('*.'))
    .sort((a, b) => b.value.length - a.value.length);
  const nonWilds = matched.filter(r => !wilds.includes(r));
  const ordered = [...nonWilds, ...wilds];

  const chosen =
    ordered.find(r => effectiveExitId(r) === 'reject' || effectiveExitId(r) === 'REJECT')
    || ordered.find(r => effectiveExitId(r) === 'direct' || effectiveExitId(r) === 'DIRECT')
    || ordered.find(r => r.kind === 'process' && effectiveExitId(r) !== 'domain-rules')
    || ordered.find(r => r.kind === 'app' && effectiveExitId(r) !== 'domain-rules')
    || ordered.find(r => r.kind === 'website' && !String(r.value).startsWith('*.'))
    || ordered.find(r => effectiveExitId(r) !== 'domain-rules');

  if (!chosen) {
    return finalize(state.defaultRuleExit, '未命中规则', '按默认出口处理');
  }
  const eff = effectiveExitId(chosen);
  const reason = (eff === 'reject' || eff === 'REJECT')
    ? '显式 REJECT 策略最高优先'
    : (eff === 'direct' || eff === 'DIRECT')
      ? '显式 DIRECT 排除优先'
      : '按进程 > 软件 > 精确域名 > 通配域名优先级命中';
  return finalize(eff, `${chosen.label} · ${groupById(chosen.group)?.name || '未分组'}`, reason);
}
