import { openRuleBatch } from './rule-batch';
import {
  createSiteCatalog,
  DEFAULT_DEMO_STATE,
  DEMO_RUNNING,
  DEMO_STORAGE_KEY,
  type DemoState,
} from './demo-state';
import { flagSvg, renderSiteIcon, SF_REFRESH, SF_TRASH } from './icons';
import { evaluateRoute } from './routing-engine.mjs';
import type { ShellController } from './shell';
import {
  $,
  closeMacMenu,
  closeSheet,
  esc,
  fmtTime,
  macPopupBtnHtml,
  notify,
  openMacMenu,
  openSheet,
  type PopupMenuItem,
  TelemetryVisualizer,
} from './ui-kit';

export function mountPreviewApp(shell: ShellController): void {
  document.documentElement.classList.add('platform-macos');
  const sites = createSiteCatalog(false);
  const telemetry = new TelemetryVisualizer(true);
  telemetry.bindInteractions();

  let state: DemoState;
  try {
    const raw = localStorage.getItem(DEMO_STORAGE_KEY);
    state = raw
      ? { ...structuredClone(DEFAULT_DEMO_STATE), ...JSON.parse(raw) }
      : structuredClone(DEFAULT_DEMO_STATE);
  } catch {
    state = structuredClone(DEFAULT_DEMO_STATE);
  }
  state.theme = shell.getTheme();

  let nodesSub: 'groups' | 'sites' = 'groups';
  let splitSub: 'rules' | 'groups' | 'procs' = 'rules';
  let simAppValue = '';
  let totalMB = 246.4;
  const expandedGroups = new Set<string>(['SHARED']);

  $('sideCoreLabel').textContent = 'Mihomo v1.19.34';
  $('sideMemText').textContent = '36.2 MB';
  $('exportBackupBtn').textContent = '导出备份';
  $('resetStateBtn').textContent = '重置示例';

  function save(): void {
    state.theme = shell.getTheme();
    try {
      localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify(state));
    } catch {}
  }

  const groupById = (id: string) => state.groups.find(g => g.id === id);
  const activeNodes = () => state.nodes.filter(n => !n.retired);
  const bestAuto = (excludeId?: string) => {
    const live = activeNodes().filter(n => n.id !== excludeId);
    return [...live].sort((a, b) => a.delay - b.delay)[0] || state.nodes[0];
  };
  const currentNode = () => {
    if (state.selectedNodeId === 'auto') return bestAuto();
    return activeNodes().find(n => n.id === state.selectedNodeId) || activeNodes()[0] || state.nodes[0];
  };

  function captureSummary(): string {
    const parts: string[] = [];
    if (state.systemProxy) parts.push('系统代理');
    if (state.tun) parts.push(state.tunScope === 'selected' ? '指定目标 TUN' : '全局 TUN');
    return parts.join(' + ');
  }

  function exitName(id: string): string {
    if (id === 'global-follow' || !id) return '跟随共享出口';
    if (id === 'domain-rules') return '按域名规则';
    if (id === 'auto') return `AUTO (${bestAuto().name})`;
    if (id === 'direct') return 'DIRECT · 直连';
    if (id === 'reject') return 'REJECT · 阻断';
    return state.nodes.find(n => n.id === id)?.name || id;
  }

  function resolvedExit(id: string): string {
    if (id === 'global-follow' || !id) return currentNode().name;
    if (id === 'domain-rules') return '按域名规则';
    if (id === 'auto') return `AUTO · ${bestAuto().name}`;
    if (id === 'direct') return 'DIRECT';
    if (id === 'reject') return 'REJECT';
    return state.nodes.find(n => n.id === id)?.name || id;
  }

  function effectiveExitId(rule: DemoState['rules'][number]): string {
    if (rule.exit) return rule.exit;
    const g = groupById(rule.group);
    return g?.exit || state.defaultRuleExit;
  }

  function exitMenuItems(includeDomainRules = false): PopupMenuItem[] {
    const items: PopupMenuItem[] = [
      { value: 'global-follow', label: '跟随共享出口', meta: currentNode().name },
      ...(includeDomainRules ? [{ value: 'domain-rules', label: '按域名规则' }] : []),
      { value: 'auto', label: 'AUTO · 自动优选', meta: `${bestAuto().delay} ms` },
      { value: 'direct', label: 'DIRECT · 直连' },
      { value: 'reject', label: 'REJECT · 阻断' },
      { sep: true },
      ...activeNodes().slice(0, 8).map(n => ({ value: n.id, label: n.name, meta: `${n.delay} ms` })),
    ];
    return items;
  }

  function renderHeaderState(): void {
    const active = currentNode();
    const cap = captureSummary();
    $('captureIdleBanner').hidden = !!cap || !activeNodes().length;
    const modeLabel = { rule: '规则模式', global: '全局模式', direct: '直连模式' }[state.mode];
    const modeIdx = { rule: 0, global: 1, direct: 2 }[state.mode] || 0;

    $('modePill').dataset.idx = String(modeIdx);
    document.querySelectorAll<HTMLElement>('.mode-pill button').forEach(b =>
      b.classList.toggle('active', b.dataset.mode === state.mode)
    );
    $('sidebarBrandSub').textContent = `${modeLabel} · ${cap || '未接管'}`;
    $<HTMLInputElement>('sideSysProxy').checked = state.systemProxy;
    $<HTMLInputElement>('sideTunToggle').checked = state.tun;
    $('navNodeBadge').textContent = String(activeNodes().length);
    $('navRuleBadge').textContent = String(state.rules.length);
    $('navSubBadge').textContent = String(state.subscriptions.length);

    const pill = $('topOnlinePill');
    pill.className = 'online-pill' + (!state.connected ? ' off' : !cap ? ' warn' : '');
    $('topStatusText').textContent = !state.connected
      ? '已断开'
      : !cap
        ? '未接管'
        : `${state.mode === 'direct' ? '直连' : '已连接'} · ${active.name}`;

    $('coreControlBtn').textContent = state.connected ? '停止内核' : '启动内核';
    $('setCoreSub').textContent = state.connected ? '运行中' : '已停止';
  }

  function renderConnect(): void {
    const active = currentNode();
    const live = activeNodes();
    $('kpiTimer').textContent = fmtTime(state.elapsed);
    $('kpiTotal').textContent = `${totalMB.toFixed(1)} MB`;
    $('kpiRules').textContent = `${state.rules.filter(r => r.on).length} 条`;
    $('goAllNodesBtn').textContent = `全部 ${live.length} 个节点 ›`;
    $('homePortFoot').textContent = `127.0.0.1:${state.ports.mixed || state.ports.http}`;

    $('heroFlag').innerHTML = flagSvg(active.name, active.flag);
    $('heroNodeName').textContent = active.name;
    $('heroNodeProto').textContent = active.proto;
    $('heroNodeDelay').innerHTML = `<i class="mini-dot"></i> ${active.delay} ms`;
    $('heroNodeMeta').textContent = `${active.source} · ${active.tag} · 出口 ${active.ip}`;
    $('chartModeBadge').textContent = `${{ rule: '规则', global: '全局', direct: '直连' }[state.mode]}模式 · ${captureSummary() || '未接管'}`;

    const best = bestAuto();
    $('homeAutoFoot').textContent = state.selectedNodeId === 'auto'
      ? `已启用 AUTO 智能优选 · 当前 ${best.name} (${best.delay} ms)`
      : `自动优选推荐：${best.name} · ${best.delay} ms`;
    $('pickAutoQuickBtn').hidden = state.selectedNodeId === 'auto';
    $('pickAutoQuickBtn').dataset.pickNode = 'auto';

    const q = shell.getSearch().trim().toLowerCase();
    const list = q
      ? live.filter(n => [n.name, n.proto, n.tag].join(' ').toLowerCase().includes(q))
      : live.slice(0, 6);

    $('homeQuickNodes').innerHTML = list.map(n => {
      const msCls = n.delay < 80 ? '' : n.delay < 160 ? 'mid' : 'slow';
      return `
        <button type="button" class="cp-node ${n.id === active.id ? 'selected' : ''}" data-pick-node="${esc(n.id)}">
          <div class="cp-node-left">
            <span class="flag-box">${flagSvg(n.name, n.flag)}</span>
            <div style="min-width:0">
              <div class="cp-node-title">${esc(n.name)}</div>
              <span class="cp-node-sub">${esc(n.proto)} · ${esc(n.tag)}</span>
            </div>
          </div>
          <span class="cp-node-ms ${msCls}">${n.delay}<small>ms</small></span>
        </button>
      `;
    }).join('') || `<div style="grid-column:1/-1;text-align:center;padding:24px;color:var(--muted)">没有匹配的节点</div>`;

    $('homeAppExits').innerHTML = DEMO_RUNNING.slice(0, 4).map(app => {
      const rule = state.rules.find(r => r.kind === 'app' && r.value.toLowerCase() === app.exe.toLowerCase());
      const val = rule?.exit || '';
      return `
        <div class="mac-row">
          <div class="mac-row-left">
            <span class="sq md ${app.tone}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round">${app.glyph}</svg></span>
            <div style="min-width:0">
              <span class="mac-row-title">${esc(app.name)}</span>
              <span class="mac-row-sub"><i class="mini-dot"></i> ${esc(app.exe)} · PID ${app.pid}</span>
            </div>
          </div>
          ${macPopupBtnHtml({ value: val, label: val ? exitName(val) : '按分流规则', width: 128, popupKind: 'app-exit', popupKey: app.exe })}
        </div>
      `;
    }).join('');

    const sub = state.subscriptions.find(s => s.active) || state.subscriptions[0];
    if (sub) {
      const pct = Math.min(100, Math.round((sub.used / sub.quota) * 100));
      $('homeSubCard').innerHTML = `
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:9px">
          <div style="display:flex;align-items:center;gap:10px">
            <span class="sq md blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/></svg></span>
            <div>
              <strong class="card-title" style="display:block">${esc(sub.name)}</strong>
              <small style="color:var(--muted);font-size:var(--type-caption)">更新于 ${esc(sub.updated)}</small>
            </div>
          </div>
        </div>
        <div style="display:flex;justify-content:space-between;font-size:var(--type-caption);color:var(--muted);margin-bottom:5px;font-family:var(--font-mono)">
          <span>已用 ${sub.used} GB / ${sub.quota} GB</span>
          <span style="color:var(--ink-2);font-weight:var(--weight-title)">${pct}%</span>
        </div>
        <div class="mac-progress"><span style="width:${pct}%"></span></div>
      `;
    }
  }

  function renderNodes(): void {
    $('nodesGroupsPane').hidden = nodesSub !== 'groups';
    $('nodesSitesPane').hidden = nodesSub !== 'sites';
    $('nodesActionBtn').textContent = nodesSub === 'groups' ? '全部节点测速' : '全部站点测速';

    const q = shell.getSearch().trim().toLowerCase();
    const live = activeNodes().filter(n => !q || [n.name, n.proto, n.tag].join(' ').toLowerCase().includes(q));

    type DrawerNode = {
      id: string;
      name: string;
      proto: string;
      delay: number;
      builtin?: boolean;
      tone?: string;
      flag?: string;
      speed?: number;
    };

    const drawers: {
      id: string;
      name: string;
      sub: string;
      selected: string;
      isGroup?: boolean;
      nodes: DrawerNode[];
    }[] = [
      {
        id: 'SHARED',
        name: '全局出口',
        sub: `当前使用 ${exitName(state.selectedNodeId)}`,
        selected: state.selectedNodeId,
        nodes: [
          { id: 'auto', name: 'AUTO · 自动优选', proto: 'URLTest', tone: 'blue', delay: bestAuto().delay, builtin: true },
          { id: 'direct', name: 'DIRECT', proto: '直连', tone: 'green', delay: 12, builtin: true },
          { id: 'reject', name: 'REJECT', proto: '阻断', tone: 'red', delay: 0, builtin: true },
          ...live,
        ],
      },
      ...state.groups.map(g => ({
        id: g.id,
        name: g.name,
        sub: `${g.type} · 当前 ${exitName(g.exit)}`,
        selected: g.exit,
        isGroup: true,
        nodes: [
          { id: 'global-follow', name: '跟随共享出口', proto: currentNode().name, tone: 'blue', delay: currentNode().delay, builtin: true },
          ...live.slice(0, 5),
        ],
      })),
    ];

    $('nodesGroupsPane').innerHTML = drawers.map(d => {
      const open = expandedGroups.has(d.id);
      return `
        <div class="group-drawer ${open ? 'open' : ''}">
          <button type="button" class="group-drawer-head" aria-expanded="${open}" data-toggle-drawer="${esc(d.id)}">
            <span>
              <strong class="card-title" style="display:block">${esc(d.name)}</strong>
              <small style="color:var(--muted);font-size:var(--type-label)">${esc(d.sub)}</small>
            </span>
            <svg class="drawer-chevron" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m6 3.5 4.5 4.5L6 12.5"/></svg>
          </button>
          ${open ? `
            <div class="group-drawer-body">
              <div class="node-pills-grid cols-3">
                ${d.nodes.map(n => `
                  <button type="button" class="cp-node ${d.selected === n.id ? 'selected' : ''}" ${d.isGroup ? `data-group-pick="${esc(d.id)}:${esc(n.id)}"` : `data-pick-node="${esc(n.id)}"`}>
                    <div class="cp-node-left">
                      ${n.builtin ? `<span class="pill ${n.tone || ''}">${esc(n.proto)}</span>` : `<span class="flag-box">${flagSvg(n.name, n.flag)}</span>`}
                      <div style="min-width:0">
                        <div class="cp-node-title">${esc(n.name)}</div>
                        ${!n.builtin && n.speed ? `<span class="cp-node-sub">${esc(n.proto)} · ${n.speed} Mbps</span>` : ''}
                      </div>
                    </div>
                    <span class="cp-node-ms ${n.delay >= 160 ? 'slow' : n.delay >= 80 ? 'mid' : ''}">${n.delay ? n.delay : '—'}</span>
                  </button>
                `).join('')}
              </div>
            </div>
          ` : ''}
        </div>
      `;
    }).join('');

    const usedExit = state.mode === 'direct' ? 'DIRECT' : currentNode().name;
    $('nodesSitesPane').innerHTML = `
      <div class="grid-2col">
        ${sites.map(([cat, items], ci) => `
          <div>
            <p class="section-label">${esc(cat)}</p>
            <div class="mac-card flush">
              ${items.map((s, si) => `
                <div class="mac-row">
                  <div class="mac-row-left">
                    ${renderSiteIcon(s.h, s.n, s.c)}
                    <div>
                      <span class="mac-row-title">${esc(s.n)}</span>
                      <span class="mac-row-sub" style="font-family:var(--font-mono)">${esc(s.h)}</span>
                    </div>
                  </div>
                  <div style="display:flex;align-items:center;gap:8px">
                    <span class="pill green">${s.ms ?? '—'} ms · ${esc(usedExit)}</span>
                    <button type="button" class="sf-icon-btn" data-probe-site="${ci}-${si}" data-tip="重新测速">${SF_REFRESH}</button>
                  </div>
                </div>
              `).join('')}
            </div>
          </div>
        `).join('')}
      </div>
    `;
  }

  function renderSplit(): void {
    $('splitRulesPane').hidden = splitSub !== 'rules';
    $('bulkRulesBtn').hidden = splitSub !== 'rules';
    $('splitGroupsPane').hidden = splitSub !== 'groups';
    $('splitProcsPane').hidden = splitSub !== 'procs';
    $('splitPrimaryAddBtn').hidden = splitSub === 'procs';
    $('splitDefaultWrap').style.display = splitSub === 'procs' ? 'none' : 'flex';
    $('procToolsWrap').style.display = 'none';
    $('splitPrimaryAddBtn').textContent = splitSub === 'groups' ? '+ 创建分组' : '+ 添加规则';

    $('defaultExitSelectHost').innerHTML = macPopupBtnHtml({
      id: 'defaultExitBtn',
      value: state.defaultRuleExit,
      label: exitName(state.defaultRuleExit),
      width: 148,
      popupKind: 'default-exit',
    });

    const q = shell.getSearch().trim().toLowerCase();
    const filteredRules = state.rules.filter(r =>
      !q || [r.label, r.value, groupById(r.group)?.name || ''].join(' ').toLowerCase().includes(q)
    );
    const bulk = $<HTMLButtonElement>('bulkRulesBtn');
    bulk.disabled = !filteredRules.length;
    bulk.onclick = () => openRuleBatch(filteredRules.map(r => ({ title: r.label, detail: r.value, enabled: r.on })), (action, selected) => {
      const ids = new Set(selected.map(i => filteredRules[i].id));
      if (action === 'delete') state.rules = state.rules.filter(r => !ids.has(r.id));
      else state.rules.forEach(r => { if (ids.has(r.id)) r.on = action === 'enable'; });
      renderAll();
    });
    $('splitRulesPane').innerHTML = `
      <div class="mac-card flush">
        ${filteredRules.map(r => {
          const eff = effectiveExitId(r);
          const tone = eff === 'direct' ? 'green' : eff === 'reject' ? 'red' : eff === 'domain-rules' ? 'purple' : 'blue';
          const appMatch = DEMO_RUNNING.find(p => p.exe.toLowerCase() === r.value.toLowerCase());
          const iconTone = appMatch ? appMatch.tone : (r.kind === 'website' ? 'blue' : 'purple');
          const iconSvg = appMatch ? appMatch.glyph : (r.kind === 'website' ? '<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/>' : '<rect x="4" y="4" width="16" height="16" rx="3"/>');
          return `
            <div class="mac-row">
              <div class="mac-row-left">
                <span class="sq md ${iconTone}">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round">${iconSvg}</svg>
                </span>
                <div style="min-width:0">
                  <span class="mac-row-title">${esc(r.label)}</span>
                  <span class="mac-row-sub">${r.kind === 'website' ? '网站域名' : '软件 · 长期'} · <span style="font-family:var(--font-mono)">${esc(r.value)}</span></span>
                </div>
              </div>
              <div class="rule-right-cols">
                <span class="pill">${esc(groupById(r.group)?.name || '未分组')}</span>
                <span class="pill ${tone}">${esc(resolvedExit(eff))}</span>
                <label class="mac-switch"><input type="checkbox" data-toggle-rule="${esc(r.id)}" ${r.on ? 'checked' : ''}><i></i></label>
                <button type="button" class="sf-icon-btn danger" data-del-rule="${esc(r.id)}" data-tip="删除规则">${SF_TRASH}</button>
              </div>
            </div>
          `;
        }).join('')}
      </div>
    `;

    $('splitGroupsPane').innerHTML = `
      <div class="grid-2col">
        ${state.groups.map(g => {
          const members = state.rules.filter(r => r.group === g.id);
          return `
            <div class="mac-card" style="display:flex;flex-direction:column;gap:12px;${g.on === false ? 'opacity:0.58' : ''}">
              <div style="display:flex;justify-content:space-between;align-items:center">
                <div style="display:flex;align-items:center;gap:10px">
                  <span class="sq md blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg></span>
                  <div>
                    <strong class="card-title" style="display:block">${esc(g.name)}</strong>
                    <small style="color:var(--muted);font-size:var(--type-caption)">${members.length} 个成员 · ${esc(g.type)}</small>
                  </div>
                </div>
                <div style="display:flex;align-items:center;gap:8px">
                  <label class="mac-switch"><input type="checkbox" data-toggle-group="${esc(g.id)}" ${g.on === false ? '' : 'checked'}><i></i></label>
                  <button type="button" class="sf-icon-btn danger" data-del-group="${esc(g.id)}" data-tip="删除分组">${SF_TRASH}</button>
                </div>
              </div>
              <div style="display:flex;align-items:center;justify-content:space-between;gap:10px">
                ${macPopupBtnHtml({ value: g.exit, label: exitName(g.exit), width: 158, popupKind: 'group-exit', popupKey: g.id })}
                <label style="display:inline-flex;align-items:center;gap:7px;font-size:var(--type-label);color:var(--muted);cursor:pointer">
                  <span>组 TUN</span>
                  <span class="mac-switch"><input type="checkbox" data-group-tun="${esc(g.id)}" ${g.tun ? 'checked' : ''}><i></i></span>
                </label>
              </div>
              <details style="border-top:0.5px solid var(--inset-divider);padding-top:9px;font-size:var(--type-label)">
                <summary style="cursor:pointer;color:var(--accent);font-weight:var(--weight-control)">管理组成员 (${members.length})</summary>
                <div style="margin-top:8px;display:grid;gap:6px">
                  ${members.map(m => `
                    <div style="display:flex;justify-content:space-between;align-items:center">
                      <span>${esc(m.label)}</span>
                      <button type="button" class="glass-btn-soft" style="height:24px;padding:0 9px" data-rm-member="${esc(m.id)}">移出</button>
                    </div>
                  `).join('') || '<span style="color:var(--muted)">暂无成员</span>'}
                </div>
              </details>
            </div>
          `;
        }).join('')}
      </div>
    `;

    $('splitProcsPane').innerHTML = `
      <div class="mac-card flush">
        ${DEMO_RUNNING.map(p => {
          const r = state.rules.find(x => x.kind === 'app' && x.value.toLowerCase() === p.exe.toLowerCase());
          const eff = r ? resolvedExit(effectiveExitId(r)) : '按当前模式';
          const tunOn = (state.tun && state.tunScope === 'all') || r?.tun === 'on';
          const val = r?.exit || '';
          return `
            <div class="mac-row">
              <div class="mac-row-left">
                <span class="sq md ${p.tone}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round">${p.glyph}</svg></span>
                <div style="min-width:0">
                  <span class="mac-row-title">${esc(p.name)}</span>
                  <span class="mac-row-sub" style="font-family:var(--font-mono)">${esc(p.exe)} · PID ${p.pid} · ${p.threads} 线程</span>
                </div>
              </div>
              <div style="display:flex;align-items:center;gap:8px">
                <span class="pill">${esc(groupById(r?.group || '')?.name || '未分组')}</span>
                <span class="pill blue">${esc(eff)}</span>
                <span class="pill ${tunOn ? 'green' : ''}">TUN ${tunOn ? '开' : '关'}</span>
                ${macPopupBtnHtml({ value: val, label: val ? exitName(val) : '按分流规则', width: 136, popupKind: 'app-exit', popupKey: p.exe })}
              </div>
            </div>
          `;
        }).join('')}
      </div>
    `;
  }

  function renderLogs(): void {
    $<HTMLButtonElement>('clearLogsBtn').disabled = !state.logs.length;
    const curProc = DEMO_RUNNING.find(p => String(p.pid) === String(simAppValue));
    const curLabel = curProc ? `${curProc.name} (${curProc.exe})` : '仅测试域名';
    $('simAppSelectHost').innerHTML = macPopupBtnHtml({
      id: 'simAppBtn',
      value: simAppValue,
      label: curLabel,
      width: 176,
      popupKind: 'sim-app',
    });

    $('logsListCard').innerHTML = state.logs.map(l => `
      <div class="mac-row">
        <div class="mac-row-left">
          <span style="font-family:var(--font-mono);font-size:var(--type-caption);color:var(--muted);width:58px;flex:none">${esc(l.time)}</span>
          <div style="min-width:0">
            <span class="mac-row-title">${esc(l.app)} <span style="color:var(--muted);font-weight:400">→</span> <span style="font-family:var(--font-mono)">${esc(l.host)}</span></span>
            <span class="mac-row-sub">${esc(l.match)} · ${esc(l.reason)}</span>
          </div>
        </div>
        <div style="display:flex;gap:7px;flex:none">
          <span class="pill">${esc(l.capture)}</span>
          <span class="pill ${l.tone}">${esc(l.action)}</span>
        </div>
      </div>
    `).join('') || `<div style="padding:36px;text-align:center;color:var(--muted)">暂无连接记录</div>`;
  }

  function renderSubs(): void {
    $('subsGridPane').innerHTML = state.subscriptions.map(sub => {
      const pct = Math.min(100, Math.round((sub.used / sub.quota) * 100));
      const cnt = state.nodes.filter(n => n.source === sub.name && !n.retired).length;
      return `
        <div class="mac-card" style="display:flex;flex-direction:column;gap:12px">
          <div style="display:flex;justify-content:space-between;align-items:center">
            <div style="display:flex;align-items:center;gap:10px">
              <span class="sq md ${sub.active ? 'blue' : 'orange'}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/></svg></span>
              <div>
                <strong class="card-title" style="display:block">${esc(sub.name)}</strong>
                <small style="color:var(--muted);font-size:var(--type-caption)">${esc(sub.kind)} · ${cnt} 个节点</small>
              </div>
            </div>
            <div style="display:flex;align-items:center;gap:4px">
              <button type="button" class="glass-btn-soft" data-ref-sub="${esc(sub.id)}">刷新</button>
              <button type="button" class="sf-icon-btn danger" data-del-sub="${esc(sub.id)}" data-tip="移除订阅">${SF_TRASH}</button>
            </div>
          </div>
          <div style="font-family:var(--font-mono);font-size:var(--type-caption);color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(sub.url)}</div>
          <div>
            <div style="display:flex;justify-content:space-between;font-size:var(--type-caption);color:var(--muted);margin-bottom:5px;font-family:var(--font-mono)">
              <span>已用 ${sub.used} GB / ${sub.quota} GB (${pct}%)</span>
              <span>到期 ${esc(sub.expires)}</span>
            </div>
            <div class="mac-progress"><span style="width:${pct}%"></span></div>
          </div>
        </div>
      `;
    }).join('');
  }

  function renderSettings(): void {
    $('setTunScopeHost').innerHTML = macPopupBtnHtml({
      id: 'setTunScopeBtn',
      value: state.tunScope,
      label: state.tunScope === 'selected' ? '仅指定分组和程序' : '全部受支持流量',
      width: 166,
      popupKind: 'tun-scope',
    });
    $<HTMLInputElement>('setFallbackToggle').checked = state.fallback;
    $<HTMLInputElement>('portMixedInput').value = String(state.ports.mixed || '');
    $<HTMLInputElement>('portHttpInput').value = String(state.ports.http);
    $<HTMLInputElement>('portSocksInput').value = String(state.ports.socks);
    $('setExitIpSub').textContent = `${currentNode().ip} (${currentNode().name}) · 系统 DNS 223.5.5.5, 1.1.1.1`;
  }

  function renderAll(): void {
    renderHeaderState();
    renderConnect();
    renderNodes();
    renderSplit();
    renderLogs();
    renderSubs();
    renderSettings();
    save();
  }

  shell.onSearchChange(() => {
    renderConnect();
    renderNodes();
    renderSplit();
  });

  document.querySelectorAll<HTMLElement>('.mode-pill button').forEach(b => {
    b.addEventListener('click', () => {
      state.mode = (b.dataset.mode as DemoState['mode']) || 'rule';
      renderAll();
      notify(`已切换为${{ rule: '规则', global: '全局', direct: '直连' }[state.mode]}模式`);
    });
  });

  const setSysProxy = (v: boolean) => { state.systemProxy = v; if (v) state.connected = true; renderAll(); notify(v ? '系统代理已开启' : '系统代理已关闭'); };
  const setTun = (v: boolean) => { state.tun = v; if (v) state.connected = true; renderAll(); notify(v ? '虚拟网卡 (TUN) 已开启' : '虚拟网卡 (TUN) 已关闭'); };
  $('enableSystemProxyBtn').addEventListener('click', () => setSysProxy(true));
  $('sideSysProxy').addEventListener('change', e => setSysProxy((e.target as HTMLInputElement).checked));
  $('sideTunToggle').addEventListener('change', e => setTun((e.target as HTMLInputElement).checked));
  $('setFallbackToggle').addEventListener('change', e => {
    state.fallback = (e.target as HTMLInputElement).checked;
    renderAll();
    notify('故障回退策略已更新');
  });

  $('coreControlBtn').addEventListener('click', () => {
    state.connected = !state.connected;
    if (!state.connected) { state.systemProxy = false; state.tun = false; }
    renderAll();
    notify(state.connected ? `已连接 · ${currentNode().name}` : '已断开并暂停接管');
  });

  function batchSpeedTest(): void {
    notify('正在测速所有代理节点…');
    window.setTimeout(() => {
      state.nodes.forEach(n => {
        if (n.retired) return;
        n.delay = Math.max(16, n.delay + Math.floor(Math.random() * 15) - 7);
        n.speed = Number((65 + Math.random() * 130).toFixed(1));
      });
      renderAll();
      notify('全部节点延迟与下载测速完成');
    }, 320);
  }
  $('heroProbeBtn').addEventListener('click', () => {
    const n = currentNode();
    n.delay = Math.max(18, n.delay + Math.floor(Math.random() * 9) - 4);
    renderAll();
    notify(`${n.name} 延迟：${n.delay} ms`);
  });

  $('nodesSubSeg').addEventListener('click', e => {
    const b = (e.target as HTMLElement).closest<HTMLElement>('[data-nodes-sub]');
    if (!b?.dataset.nodesSub) return;
    nodesSub = b.dataset.nodesSub as 'groups' | 'sites';
    $('nodesSubSeg').querySelectorAll('button').forEach(x => x.classList.toggle('active', x === b));
    renderNodes();
  });
  $('nodesActionBtn').addEventListener('click', () => {
    if (nodesSub === 'groups') {
      batchSpeedTest();
    } else {
      sites.forEach(([, list]) => list.forEach(s => { s.ms = 18 + Math.floor(Math.random() * 95); }));
      renderNodes();
      notify('常用网站连通性测速完成');
    }
  });

  $('splitSubSeg').addEventListener('click', e => {
    const b = (e.target as HTMLElement).closest<HTMLElement>('[data-split-sub]');
    if (!b?.dataset.splitSub) return;
    splitSub = b.dataset.splitSub as 'rules' | 'groups' | 'procs';
    $('splitSubSeg').querySelectorAll('button').forEach(x => x.classList.toggle('active', x === b));
    renderSplit();
  });

  document.addEventListener('click', e => {
    const target = e.target as HTMLElement;
    const popTrigger = target.closest<HTMLElement>('[data-popup-kind]');
    if (popTrigger) {
      e.stopPropagation();
      const kind = popTrigger.dataset.popupKind || '';
      const key = popTrigger.dataset.popupKey || '';
      const val = popTrigger.dataset.popupVal || '';
      if (kind === 'app-exit') {
        const items: PopupMenuItem[] = [{ value: '', label: '按分流规则（无单独设置）' }, { sep: true }, ...exitMenuItems(true)];
        openMacMenu(popTrigger, items, val, nextVal => {
          let rule = state.rules.find(r => r.kind === 'app' && r.value.toLowerCase() === key.toLowerCase());
          if (!nextVal) {
            if (!rule) return;
            if (rule.group || rule.tun !== 'inherit') rule.exit = '';
            else state.rules = state.rules.filter(r => r !== rule);
            renderAll();
            notify('已清除单独出口，恢复按分流规则');
            return;
          }
          if (!rule) {
            const app = DEMO_RUNNING.find(p => p.exe === key);
            rule = {
              id: 'r-' + Date.now(),
              kind: 'app',
              label: app?.name || key,
              value: key,
              path: app?.path,
              group: '',
              exit: nextVal,
              tun: 'inherit',
              on: true,
            };
            state.rules.unshift(rule);
          } else {
            rule.exit = nextVal;
          }
          renderAll();
          notify(`${rule.label} 出口已设为 ${exitName(nextVal)}`);
        });
        return;
      }
      if (kind === 'group-exit') {
        openMacMenu(popTrigger, exitMenuItems(false), val, nextVal => {
          const g = groupById(key);
          if (g) { g.exit = nextVal; renderAll(); notify(`「${g.name}」出口已更新`); }
        });
        return;
      }
      if (kind === 'default-exit') {
        openMacMenu(popTrigger, exitMenuItems(false), val, nextVal => {
          state.defaultRuleExit = nextVal;
          renderAll();
          notify(`默认出口已设为 ${exitName(nextVal)}`);
        });
        return;
      }
      if (kind === 'tun-scope') {
        openMacMenu(popTrigger, [
          { value: 'all', label: '全部受支持流量' },
          { value: 'selected', label: '仅指定分组和程序' },
        ], val, nextVal => {
          state.tunScope = nextVal as 'all' | 'selected';
          renderAll();
          notify('TUN 接管范围已更新');
        });
        return;
      }
      if (kind === 'sim-app') {
        openMacMenu(popTrigger, [
          { value: '', label: '仅测试域名' },
          { sep: true },
          ...DEMO_RUNNING.map(p => ({ value: String(p.pid), label: p.name, meta: p.exe })),
        ], val, nextVal => {
          simAppValue = nextVal;
          renderLogs();
        });
        return;
      }
    }

    if (!target.closest('#macMenuPopover')) closeMacMenu();

    const drawerHead = target.closest<HTMLElement>('[data-toggle-drawer]');
    if (drawerHead?.dataset.toggleDrawer) {
      const id = drawerHead.dataset.toggleDrawer;
      if (expandedGroups.has(id)) expandedGroups.delete(id); else expandedGroups.add(id);
      renderNodes();
      document.querySelector<HTMLElement>(`[data-toggle-drawer="${CSS.escape(id)}"]`)?.focus({ preventScroll: true });
      return;
    }
    const pickNode = target.closest<HTMLElement>('[data-pick-node]');
    if (pickNode?.dataset.pickNode) {
      state.selectedNodeId = pickNode.dataset.pickNode.toLowerCase() === 'auto' ? 'auto' : pickNode.dataset.pickNode;
      renderAll();
      notify(`已切换至 ${exitName(state.selectedNodeId)}`);
      return;
    }
    const grpPick = target.closest<HTMLElement>('[data-group-pick]');
    if (grpPick?.dataset.groupPick) {
      const [gid, nid] = grpPick.dataset.groupPick.split(':');
      const g = groupById(gid);
      if (g) { g.exit = nid; renderAll(); notify(`「${g.name}」出口已切换至 ${exitName(nid)}`); }
      return;
    }
    const probeSite = target.closest<HTMLElement>('[data-probe-site]');
    if (probeSite?.dataset.probeSite) {
      const [ci, si] = probeSite.dataset.probeSite.split('-').map(Number);
      sites[ci][1][si].ms = 18 + Math.floor(Math.random() * 95);
      renderNodes();
      return;
    }
    const delRule = target.closest<HTMLElement>('[data-del-rule]');
    if (delRule?.dataset.delRule) {
      state.rules = state.rules.filter(r => r.id !== delRule.dataset.delRule);
      renderAll();
      notify('规则已删除');
      return;
    }
    const rmMember = target.closest<HTMLElement>('[data-rm-member]');
    if (rmMember?.dataset.rmMember) {
      const r = state.rules.find(x => x.id === rmMember.dataset.rmMember);
      if (r) { r.group = ''; renderAll(); notify('已移出分组，原规则与独立出口已保留'); }
      return;
    }
    const delGrp = target.closest<HTMLElement>('[data-del-group]');
    if (delGrp?.dataset.delGroup) {
      const gid = delGrp.dataset.delGroup;
      if (state.rules.some(r => r.group === gid)) { notify('请先移出分组内的成员后再删除'); return; }
      state.groups = state.groups.filter(g => g.id !== gid);
      renderAll();
      notify('分组已删除');
      return;
    }
    const refSub = target.closest<HTMLElement>('[data-ref-sub]');
    if (refSub?.dataset.refSub) {
      const s = state.subscriptions.find(x => x.id === refSub.dataset.refSub);
      if (s) { s.updated = '刚刚'; renderAll(); notify(`「${s.name}」已刷新`); }
      return;
    }
    const delSub = target.closest<HTMLElement>('[data-del-sub]');
    if (delSub?.dataset.delSub) {
      const s = state.subscriptions.find(x => x.id === delSub.dataset.delSub);
      if (s) {
        state.subscriptions = state.subscriptions.filter(x => x.id !== s.id);
        state.nodes.forEach(n => { if (n.source === s.name) n.retired = true; });
        renderAll();
        notify(`已移除「${s.name}」`);
      }
    }
  });

  document.addEventListener('change', e => {
    const target = e.target as HTMLInputElement;
    const tRule = target.closest<HTMLInputElement>('[data-toggle-rule]');
    if (tRule?.dataset.toggleRule) {
      const r = state.rules.find(x => x.id === tRule.dataset.toggleRule);
      if (r) { r.on = tRule.checked; renderAll(); }
      return;
    }
    const tGrp = target.closest<HTMLInputElement>('[data-toggle-group]');
    if (tGrp?.dataset.toggleGroup) {
      const g = groupById(tGrp.dataset.toggleGroup);
      if (g) { g.on = tGrp.checked; renderAll(); }
      return;
    }
    const gTun = target.closest<HTMLInputElement>('[data-group-tun]');
    if (gTun?.dataset.groupTun) {
      const g = groupById(gTun.dataset.groupTun);
      if (g) { g.tun = gTun.checked; renderAll(); }
    }
  });

  $('simForm').addEventListener('submit', e => {
    e.preventDefault();
    const host = $<HTMLInputElement>('simHostInput').value
      .trim().replace(/^https?:\/\//i, '').replace(/\/.*$/, '').toLowerCase();
    if (!host) return;
    const pid = Number(simAppValue || 0);
    const proc = DEMO_RUNNING.find(p => p.pid === pid);
    const res = evaluateRoute(state, {
      host,
      path: proc?.path,
      sysProxy: $<HTMLInputElement>('simSysProxyCheck').checked,
      failed: $<HTMLInputElement>('simFailCheck').checked,
    });
    state.logs.unshift({
      time: new Date().toTimeString().slice(0, 8),
      app: proc ? proc.exe : '浏览器 / 系统',
      host,
      ...res,
    });
    renderLogs();
    notify(`走向：${res.capture} → ${res.action}`);
  });
  $('clearLogsBtn').addEventListener('click', () => {
    state.logs = [];
    renderLogs();
    notify('连接记录已清空');
  });

  function importLink(raw: string): void {
    const firstLine = raw.trim().split(/\r?\n/)[0] || raw.trim();
    const name = firstLine.startsWith('http')
      ? '香港 IEPL 03'
      : (firstLine.includes('#') ? decodeURIComponent(firstLine.split('#')[1]) : firstLine);
    const id = 'n-' + Date.now();
    state.nodes.unshift({ id, name, tag: '新导入', flag: 'hk', proto: 'Hysteria2', delay: 31, speed: 165.0, source: '个人订阅', ip: '45.11.57.99' });
    state.selectedNodeId = id;
    renderAll();
    notify(`已导入并切换至 ${name}`);
  }
  $('subFileInput').addEventListener('change', e => {
    const input = e.target as HTMLInputElement;
    const f = input.files?.[0];
    if (f) { importLink(f.name); input.value = ''; }
  });

  $('subImportBtn').addEventListener('click', () => {
    openSheet({
      title: '导入订阅或节点',
      bodyHtml: `
        <div class="sheet-field">
          <label for="sheetImportVal">链接或节点列表</label>
          <textarea class="sheet-textarea" id="sheetImportVal" placeholder="粘贴订阅链接或单/多行分享链接…"></textarea>
        </div>
      `,
      actionsSplit: true,
      actionsHtml: `
        <button type="button" class="glass-btn-soft" id="sheetImportFileBtn">从文件导入…</button>
        <div class="sheet-actions-group"><button type="button" class="glass-btn-soft" id="sheetCancel">取消</button>
        <button type="button" class="glass-btn-primary compact" id="sheetConfirmImport" disabled>导入</button></div>
      `,
    });
    const input = $<HTMLTextAreaElement>('sheetImportVal');
    input.oninput = () => { $<HTMLButtonElement>('sheetConfirmImport').disabled = !input.value.trim(); };
    $('sheetImportFileBtn').onclick = () => { closeSheet(); $('subFileInput').click(); };
    $('sheetCancel').onclick = closeSheet;
    $('sheetConfirmImport').onclick = () => {
      const v = $<HTMLTextAreaElement>('sheetImportVal').value.trim();
      if (v) { importLink(v); closeSheet(); }
    };
    $<HTMLTextAreaElement>('sheetImportVal').focus();
  });

  $('splitPrimaryAddBtn').addEventListener('click', () => {
    if (splitSub === 'groups') {
      openSheet({
        title: '创建策略分组',
        subtitle: '将多个规则或软件归类到同一个分流出口组',
        iconHtml: `<span class="sq md blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg></span>`,
        bodyHtml: `
          <div class="sheet-field">
            <label for="shGrpName">分组名称</label>
            <input type="text" class="sheet-input" id="shGrpName" placeholder="例如：流媒体或办公工具">
          </div>
        `,
        actionsHtml: `
          <button type="button" class="glass-btn-soft" id="sheetCancel">取消</button>
          <button type="button" class="glass-btn-primary compact" id="shGrpSave">创建</button>
        `,
      });
      $('sheetCancel').onclick = closeSheet;
      $('shGrpSave').onclick = () => {
        const name = $<HTMLInputElement>('shGrpName').value.trim();
        if (!name) return;
        state.groups.push({ id: 'g-' + Date.now(), name, type: 'Selector', exit: 'global-follow', tun: false, on: true });
        renderAll();
        closeSheet();
        notify(`已创建分组「${name}」`);
      };
      $<HTMLInputElement>('shGrpName').focus();
    } else {
      openSheet({
        title: '添加分流规则',
        subtitle: '支持精确域名或通配域名（*.example.com）',
        iconHtml: `<span class="sq md purple"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><circle cx="6" cy="6" r="2.5"/><circle cx="18" cy="6" r="2.5"/><circle cx="12" cy="18" r="2.5"/><path d="M6 8.5v2a4 4 0 0 0 4 4h4a4 4 0 0 0 4-4v-2M12 14.5v1"/></svg></span>`,
        bodyHtml: `
          <div class="sheet-field">
            <label for="shRuleDomain">网站域名</label>
            <input type="text" class="sheet-input" id="shRuleDomain" placeholder="例如 openai.com 或 *.github.com">
          </div>
        `,
        actionsHtml: `
          <button type="button" class="glass-btn-soft" id="sheetCancel">取消</button>
          <button type="button" class="glass-btn-primary compact" id="shRuleSave">保存规则</button>
        `,
      });
      $('sheetCancel').onclick = closeSheet;
      $('shRuleSave').onclick = () => {
        const d = $<HTMLInputElement>('shRuleDomain').value.trim().toLowerCase();
        if (!d) return;
        state.rules.unshift({ id: 'r-' + Date.now(), kind: 'website', label: d, value: d, group: state.groups[0]?.id || '', exit: '', tun: 'inherit', on: true });
        renderAll();
        closeSheet();
        notify(`已添加规则 ${d}`);
      };
      $<HTMLInputElement>('shRuleDomain').focus();
    }
  });

  $('savePortsBtn').addEventListener('click', () => {
    const m = $<HTMLInputElement>('portMixedInput').value ? Number($<HTMLInputElement>('portMixedInput').value) : null;
    const h = Number($<HTMLInputElement>('portHttpInput').value);
    const s = Number($<HTMLInputElement>('portSocksInput').value);
    const list = [m, h, s].filter(Boolean) as number[];
    if (list.some(p => p < 1 || p > 65535) || new Set(list).size !== list.length) {
      notify('端口号无效或存在重复冲突', true);
      return;
    }
    state.ports = { mixed: m, http: h, socks: s };
    renderAll();
    notify('端口配置已保存');
  });
  $('copyEnvBtn').addEventListener('click', () => {
    const p = state.ports.mixed || state.ports.http;
    navigator.clipboard?.writeText(`export https_proxy=http://127.0.0.1:${p} http_proxy=http://127.0.0.1:${p}`).catch(() => {});
    notify(`已复制代理环境变量 (127.0.0.1:${p})`);
  });
  $('probeIpBtn').addEventListener('click', () => notify(`出口 IP 检测完成：${currentNode().ip}`));
  $('exportBackupBtn').addEventListener('click', () => {
    const blob = new Blob([JSON.stringify(state, null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'xeylroute-macos27-backup.json';
    a.click();
    notify('配置备份已导出');
  });
  $('resetStateBtn').addEventListener('click', () => {
    localStorage.removeItem(DEMO_STORAGE_KEY);
    state = structuredClone(DEFAULT_DEMO_STATE);
    shell.setTheme(state.theme);
    renderAll();
    notify('已恢复初始示例数据');
  });

  window.setInterval(() => {
    if (document.hidden) return;
    if (!state.connected || !captureSummary()) {
      $('kpiDown').textContent = '0.0 MB/s';
      $('kpiUp').textContent = '0.0 MB/s';
      $('sideDownRate').textContent = '0.0 MB/s ↓';
      $('sideUpRate').textContent = '0.0 MB/s ↑';
      telemetry.pushSample(0, 0);
      if (state.connected) telemetry.pushConnectionCount(0, { down: 0, up: 0 });
      return;
    }
    state.elapsed++;
    const prev = telemetry.down[telemetry.down.length - 1] || 10;
    const d = Number(Math.max(4.2, Math.min(17.6, prev + (Math.random() - 0.48) * 3.6)).toFixed(1));
    const u = Number((d * (0.11 + Math.random() * 0.06)).toFixed(1));
    totalMB += d * 0.12;
    $('kpiDown').textContent = `${d.toFixed(1)} MB/s`;
    $('kpiUp').textContent = `${u.toFixed(1)} MB/s`;
    $('kpiTimer').textContent = fmtTime(state.elapsed);
    $('kpiTotal').textContent = `${totalMB.toFixed(1)} MB`;
    $('sideDownRate').textContent = `${d.toFixed(1)} MB/s ↓`;
    $('sideUpRate').textContent = `${u.toFixed(1)} MB/s ↑`;
    telemetry.pushSample(d, u);
    telemetry.pushConnectionCount(Math.round(d * 2), { down: d, up: u });
  }, 1000);

  telemetry.renderConnections();
  telemetry.paintChart();
  renderAll();
}
