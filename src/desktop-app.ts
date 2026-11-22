import { bindRuleProgramPicker } from './rule-program-picker';
import { openProfileEditor, type DocumentMode } from './profile-editor';
import { openRuleBatch } from './rule-batch';
import { createSiteCatalog } from './demo-state';
import {
  flagSvg,
  renderProgramIcon,
  renderSiteIcon,
  SF_DETAIL,
  SF_EDIT,
  SF_REFRESH,
  SF_TEST,
  SF_TRASH,
} from './icons';
import { groupRunningApps, normalizedProgramPath } from './running-apps.mjs';
import { formatRate, trafficRates } from './traffic.mjs';
import { runProbeQueue } from './probe-queue.mjs';
import type { ShellController } from './shell';
import {
  buildProxyEnvText,
  type ActiveRoute,
  type ConnectionLogRow,
  type CoreStatus,
  type CoreSettings,
  type DelayResult,
  formatBytes,
  formatProcessStartedAt,
  type GroupedRunningApp,
  listenTrayAction,
  listenWindowVisibility,
  looksLikeFullConfig,
  looksLikeShareLinks,
  type MihomoSnapshot,
  type NetworkDetails,
  platformLabel,
  type ProcessInstance,
  type ProfileEdit,
  type RuleConditions,
  type SharedRule,
  type ScopeMapping,
  type ProfileGroup,
  type ProfileNode,
  type ProfileSummary,
  type RoutingMode,
  type RunningProcess,
  type SubscriptionUsage,
  tauriApi,
  tunElevationMessage,
} from './tauri-bridge';
import {
  $,
  closeMacMenu,
  closeSheet,
  confirmSheet,
  esc,
  fmtTime,
  isSheetOpen,
  macPopupBtnHtml,
  notify,
  openMacMenu,
  openSheet,
  type PopupMenuItem,
  TelemetryVisualizer,
} from './ui-kit';

type CardMeta = {
  updatedAt: number;
  usage?: SubscriptionUsage;
  usageAt?: number;
};

type NodeCardItem = {
  name: string;
  type: string;
  provider: string | null;
  policy?: boolean;
  standalone?: boolean;
  now?: string;
};

type NetworkControlAction = {
  control: 'core' | 'system' | 'tun';
  enabled: boolean;
  fromTray?: boolean;
};

const INTERNAL_SPEED_GROUP = 'RoutePilot.Internal.SpeedTest';
const HIDDEN_NODES = new Set(['GLOBAL', 'PASS', 'PASS-RULE', 'COMPATIBLE', 'REJECT-DROP', INTERNAL_SPEED_GROUP]);
const POLICY_CARDS: { name: string; type: string; tone: string }[] = [
  { name: 'AUTO', type: '自动优选', tone: 'blue' },
  { name: 'DIRECT', type: '直连', tone: 'green' },
  { name: 'REJECT', type: '阻断', tone: 'red' },
];

const KEY_ACTIVE_SUB = 'routepilot-active-subscription';
const KEY_SUB_NODES = 'routepilot-subscription-nodes';
const KEY_SUB_EXITS = 'routepilot-subscription-exits';
const KEY_SUB_CARD = 'routepilot-subscription-card-data';
const KEY_GROUP_EXITS = 'routepilot-scoped-group-exits';
const KEY_PENDING_NODE = 'routepilot-pending-subscription-exit';

function loadMap<V>(key: string): Map<string, V> {
  try {
    return new Map(JSON.parse(localStorage.getItem(key) || '[]'));
  } catch {
    return new Map();
  }
}

function saveMap<V>(key: string, map: Map<string, V>): void {
  try {
    localStorage.setItem(key, JSON.stringify([...map]));
  } catch {}
}

function cleanError(err: unknown): string {
  return String(err ?? '操作失败').replace(/^Error:\s*/i, '');
}

export function mountDesktopApp(shell: ShellController): void {
  const root = document.documentElement;
  root.classList.add('tauri-native');

  function applyPlatformClass(platform: 'macos' | 'windows' | 'linux'): void {
    if (root.classList.contains(`platform-${platform}`)) return;
    root.classList.remove('platform-macos', 'platform-windows', 'platform-linux');
    root.classList.add(`platform-${platform}`);
    $(platform === 'windows' ? 'windowTitlebar' : 'toolbarActions').append($('winControls'));
    if (platform === 'windows') {
      $('windowTitlebar').prepend(document.querySelector<HTMLElement>('.sidebar-top-brand')!);
    }
  }
  const ua = `${navigator.platform || ''} ${navigator.userAgent || ''}`.toLowerCase();
  applyPlatformClass(ua.includes('mac') ? 'macos' : ua.includes('win') ? 'windows' : 'linux');

  function renderWinMaxIcon(maximized: boolean): void {
    $('winMaxBtn').innerHTML = maximized
      ? `<svg viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.35" stroke-linejoin="round"><rect x="2.6" y="4.6" width="6.6" height="6.6" rx="1.2"/><path d="M4.8 4.6V3.6a1.2 1.2 0 0 1 1.2-1.2h4.4a1.2 1.2 0 0 1 1.2 1.2V8a1.2 1.2 0 0 1-1.2 1.2H9.2"/></svg>`
      : `<svg viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.35" stroke-linejoin="round"><rect x="3.2" y="3.2" width="7.6" height="7.6" rx="1.4"/></svg>`;
  }
  const toggleMaximize = () => {
    void tauriApi.windowToggleMaximize().then(maximized => renderWinMaxIcon(Boolean(maximized))).catch(() => {});
  };

  $('winMinBtn').addEventListener('click', () => { void tauriApi.windowMinimize(); });
  $('winMaxBtn').addEventListener('click', toggleMaximize);
  $('winCloseBtn').addEventListener('click', () => { void tauriApi.windowClose(); });
  $('toolbarDragSpacer').addEventListener('dblclick', () => {
    toggleMaximize();
  });
  $('windowTitlebar').addEventListener('dblclick', e => {
    if (e.target === e.currentTarget) toggleMaximize();
  });

  const sites = createSiteCatalog(true);
  const telemetry = new TelemetryVisualizer(false);
  telemetry.bindInteractions();

  // Live state
  let liveStatus: CoreStatus | null = null;
  let liveProfile: ProfileSummary | null = null;
  let liveCore: MihomoSnapshot | null = null;
  let liveError = '';
  let liveProcesses: RunningProcess[] = [];
  let endedInstances = new Set<string>();
  let processStatus = '正在读取运行中的程序…';
  let liveApps: GroupedRunningApp[] = [];
  let liveLogs: ConnectionLogRow[] = [];
  let networkDetails: NetworkDetails | null = null;
  let lastNetworkRead = 0;
  let readingNetwork = false;
  let exitIp = '';

  let selectedSubscription = localStorage.getItem(KEY_ACTIVE_SUB) || '';
  const subscriptionNodes = loadMap<ProfileNode[]>(KEY_SUB_NODES);
  const subscriptionSelections = loadMap<string>(KEY_SUB_EXITS);
  const subscriptionCardData = loadMap<CardMeta>(KEY_SUB_CARD);
  const subscriptionCardReads = new Set<string>();
  const refreshResults = new Map<string, { message: string; failed?: boolean }>();
  let providerRefresh: { total: number; done: number; batch: boolean } | null = null;
  let subscriptionCardsHtml = '';
  const groupSelections = loadMap<string>(KEY_GROUP_EXITS);
  let restoredGroupScope: string | null = null;
  let scopeMigrationAttempted = false;

  const liveDelays = new Map<string, DelayResult | string>();
  const liveTesting = new Set<string>();
  const siteProbing = new Set<string>();

  // Operation guards
  let networkUpdating = false;
  let savingPorts = false;
  let profileBusy = false;
  let selectingNode = false;
  let changingMode = false;
  let changingSubscription = false;
  let pendingSubscription = '';
  let batchTesting = false;
  let probeGeneration = 0;
  let probeRenderTimer = 0;
  let localCoreStart: Promise<boolean> | null = null;
  let refreshPromise: Promise<void> | null = null;
  let refreshQueued = false;
  let logSeq = 0;
  let profileSeq = 0;

  // Traffic & timer tracking
  let sessionStartedAt: number | null = null;
  let lastTraffic: { time: number; down: number; up: number } | null = null;
  let lastRunning: boolean | null = null;

  // Tray deduplication
  let traySignature = '';
  let trayChain: Promise<void> = Promise.resolve();

  // Sub-view states
  let nodesSub: 'groups' | 'sites' | 'ports' = 'groups';
  let splitSub: 'rules' | 'groups' | 'procs' = 'rules';
  let procScanType: 'app' | 'process' = 'app';
  const expandedGroups = new Set<string>(['SHARED']);

  // Configure Live Mode UI labels
  $('simAppSelectHost').hidden = true;
  $('simSysProxyWrap').hidden = true;
  $('simFailWrap').hidden = true;
  $('simSubmitBtn').textContent = '实测连通';
  $('setFallbackRow').hidden = true;
  $('exportBackupBtn').textContent = '保存备份';
  $('resetStateBtn').textContent = '恢复备份';

  function currentMode(): RoutingMode {
    return liveCore?.config?.mode || liveProfile?.mode || 'rule';
  }

  function activeListenPort(): number | null {
    const cfg = liveCore?.config;
    return cfg?.['mixed-port'] || cfg?.port || liveProfile?.mixed || liveProfile?.http || liveStatus?.httpPort || null;
  }

  function isTestableNode(item: { name: string; type?: string }): boolean {
    if (!item || !item.name || HIDDEN_NODES.has(item.name)) return false;
    if (['DIRECT', 'REJECT', 'AUTO'].includes(item.name)) return false;
    if (['Direct', 'Reject', 'Pass'].includes(item.type || '')) return false;
    return true;
  }

  function activeSubscriptionNodes(): NodeCardItem[] {
    if (!selectedSubscription) return [];
    const liveList = liveCore?.providers?.providers?.[selectedSubscription]?.proxies;
    const raw = liveList ?? subscriptionNodes.get(selectedSubscription) ?? [];
    return raw
      .filter(isTestableNode)
      .map(n => ({ name: n.name, type: n.type || 'Proxy', provider: selectedSubscription }));
  }

  function standaloneNodes(): NodeCardItem[] {
    return (liveProfile?.nodes || [])
      .filter(isTestableNode)
      .map(n => ({ name: n.name, type: n.type || 'Proxy', provider: null, standalone: true }));
  }

  function allSelectableNodes(): NodeCardItem[] {
    const map = new Map<string, NodeCardItem>();
    for (const n of activeSubscriptionNodes()) map.set(n.name, n);
    for (const n of standaloneNodes()) {
      if (!map.has(n.name)) map.set(n.name, n);
    }
    if (liveCore?.proxies?.proxies) {
      for (const entry of Object.values(liveCore.proxies.proxies)) {
        if (isTestableNode(entry) && !Array.isArray(entry.all) && !map.has(entry.name)) {
          map.set(entry.name, { name: entry.name, type: entry.type || 'Proxy', provider: entry.provider || null });
        }
      }
    }
    return [...map.values()];
  }

  function hasAutoExit(): boolean {
    return liveCore ? Boolean(liveCore.proxies?.proxies?.AUTO) : Boolean(liveProfile?.exits.includes('AUTO'));
  }

  function sharedDrawerNodes(): NodeCardItem[] {
    const real = allSelectableNodes();
    const autoNow = liveCore?.proxies?.proxies?.AUTO?.now;
    const policies: NodeCardItem[] = [
      ...(hasAutoExit()
        ? [{ name: 'AUTO', type: '自动优选', provider: selectedSubscription || null, policy: true, now: autoNow }]
        : []),
      { name: 'DIRECT', type: '直连', provider: null, policy: true },
      { name: 'REJECT', type: '阻断', provider: null, policy: true },
    ];
    return [...policies, ...real];
  }

  function activeGlobalExit(): string {
    const global = liveCore?.proxies?.proxies?.GLOBAL;
    if (global?.now) return global.now;
    const saved = subscriptionSelections.get(selectedSubscription);
    if (saved) return saved;
    if (hasAutoExit()) return 'AUTO';
    return 'DIRECT';
  }

  function captureSummary(): string {
    const parts: string[] = [];
    if (liveStatus?.systemProxy) parts.push('系统代理');
    if (liveStatus?.tun) {
      parts.push(liveProfile?.tunScope === 'selected'
        ? (currentMode() === 'rule' ? '指定软件 TUN' : '指定软件 TUN（已暂停）')
        : '全局 TUN');
    }
    return parts.join(' + ');
  }

  function delayKey(provider: string | null, name: string): string {
    return JSON.stringify([provider || '', name]);
  }

  function delayForNode(node: NodeCardItem): { text: string; cls: string; raw?: number } {
    const key = delayKey(node.provider, node.name);
    if (liveTesting.has(key)) return { text: '测速中', cls: 'mid' };
    const cached = liveDelays.get(key);
    if (typeof cached === 'string') return { text: '测速失败', cls: 'slow' };
    if (cached && typeof cached.delay === 'number') {
      const ms = cached.delay;
      return {
        text: `${ms}`,
        cls: ms < 80 ? '' : ms < 160 ? 'mid' : 'slow',
        raw: ms,
      };
    }
    const hist = liveCore?.proxies?.proxies?.[node.name]?.history;
    const last = hist?.[hist.length - 1]?.delay;
    if (typeof last === 'number' && last > 0) {
      return { text: `${last}`, cls: last < 80 ? '' : last < 160 ? 'mid' : 'slow', raw: last };
    }
    return { text: '—', cls: '' };
  }

  function syncTray(): void {
    const global = liveCore?.proxies?.proxies?.GLOBAL;
    const trayNodes = global?.type === 'Selector'
      ? sharedDrawerNodes().map(n => n.name).filter(name => global.all?.includes(name))
      : [];
    const payload = {
      english: false,
      configured: Boolean(liveStatus?.configured),
      running: Boolean(liveStatus?.running),
      systemProxy: Boolean(liveStatus?.systemProxy),
      tun: Boolean(liveStatus?.tun),
      busy: networkUpdating || selectingNode || changingMode || changingSubscription,
      mode: currentMode(),
      nodes: trayNodes,
      selected: global?.now || '',
    };
    const sig = JSON.stringify(payload);
    if (sig === traySignature) return;
    traySignature = sig;
    trayChain = trayChain.then(() => tauriApi.updateTrayMenu(payload)).catch(() => {
      if (traySignature === sig) traySignature = '';
    });
  }

  /* =========================================================================
     Core & Subscription Synchronization
     ========================================================================= */
  function saveCardMeta(name: string, updatedAt: number, usage?: SubscriptionUsage | null): void {
    const old = subscriptionCardData.get(name) || { updatedAt: 0 };
    const hasUsage = Boolean(usage && Object.keys(usage).length && (!old.usage || updatedAt >= (old.usageAt || 0)));
    const next: CardMeta = {
      updatedAt: Math.max(old.updatedAt || 0, updatedAt || 0),
      usage: hasUsage && usage ? usage : old.usage,
      usageAt: hasUsage ? updatedAt : old.usageAt,
    };
    if (JSON.stringify(old) === JSON.stringify(next)) return;
    subscriptionCardData.set(name, next);
    saveMap(KEY_SUB_CARD, subscriptionCardData);
  }

  async function readOfflineNodes(name: string): Promise<void> {
    if (!name) return;
    const nodes = await tauriApi.subscriptionNodes(name).catch(() => null);
    if (!Array.isArray(nodes) || !liveProfile?.providers.some(p => p.name === name)) return;
    subscriptionNodes.set(name, nodes);
    saveMap(KEY_SUB_NODES, subscriptionNodes);
    if (shell.getView() === 'nodes' || shell.getView() === 'connect') renderView();
  }

  async function loadSubscriptionMeta(name: string, force = false): Promise<string> {
    if (!force && subscriptionCardReads.has(name)) return '';
    subscriptionCardReads.add(name);
    try {
      const data = await tauriApi.subscriptionCardMetadata(name);
      if (!liveProfile?.providers.some(p => p.name === name)) return '';
      saveCardMeta(name, data.updatedAt ? data.updatedAt * 1000 : 0, data.usage);
      if (Array.isArray(data.nodes) && !data.error) {
        subscriptionNodes.set(name, data.nodes);
        saveMap(KEY_SUB_NODES, subscriptionNodes);
      }
      if (data.error && !force && (shell.getView() === 'subs' || shell.getView() === 'nodes')) {
        notify(`${name}：${data.error}`, true);
      }
      renderView();
      return data.error || '';
    } catch (err) {
      return cleanError(err);
    }
  }

  function applyProfile(profile: ProfileSummary): void {
    liveProfile = profile;
    const providerNames = new Set(profile.providers.map(p => p.name));
    for (const name of refreshResults.keys()) if (!providerNames.has(name)) refreshResults.delete(name);
    for (const name of [...subscriptionCardData.keys()]) {
      if (!providerNames.has(name)) {
        subscriptionCardData.delete(name);
        subscriptionCardReads.delete(name);
      }
    }
    selectedSubscription = profile.subscriptionScope || '';
    if (selectedSubscription) localStorage.setItem(KEY_ACTIVE_SUB, selectedSubscription);
    else localStorage.removeItem(KEY_ACTIVE_SUB);
  }

  async function reloadProfile(): Promise<void> {
    const seq = ++profileSeq;
    if (changingSubscription) return;
    try {
      const res = await tauriApi.profileSummary();
      if (seq !== profileSeq || changingSubscription) return;
      const profile = res.profile;
      if (profile.subscriptionScope) scopeMigrationAttempted = false;
      if (!scopeMigrationAttempted && !profile.subscriptionScope && profile.providers.length) {
        scopeMigrationAttempted = true;
        const preferred = profile.providers.find(p => p.name === selectedSubscription)?.name;
        await switchSubscription(preferred || profile.providers[0].name);
        return;
      }
      applyProfile(profile);
      void readOfflineNodes(selectedSubscription);
      if (shell.getView() === 'subs') {
        for (const p of profile.providers) void loadSubscriptionMeta(p.name);
      } else if (shell.getView() === 'nodes' && selectedSubscription) {
        if (profile.providers.some(p => p.name === selectedSubscription && p.type === 'http')) {
          void loadSubscriptionMeta(selectedSubscription);
        }
      }
      renderAllSafe();
    } catch (err) {
      notify(cleanError(err), true);
    }
  }

  async function commitProfileEdit(edit: ProfileEdit, successMsg?: string, scope = liveProfile?.subscriptionScope ?? ''): Promise<ProfileSummary | null> {
    if (profileBusy) return null;
    profileBusy = true;
    try {
      const exit = 'exit' in edit ? edit.exit : undefined;
      const node = exit && editorNodePins().get(exit);
      const profile = await tauriApi.editProfile(edit, scope, exit && node ? { [exit]: node } : undefined);
      applyProfile(profile);
      renderAllSafe();
      if (successMsg) notify(successMsg);
      void refreshLiveState(true);
      return profile;
    } catch (err) {
      notify(cleanError(err), true);
      return null;
    } finally {
      profileBusy = false;
    }
  }

  function showScopeMapping(name: string, plan: ScopeMapping): void {
    openSheet({title:'为共享规则选择出口',subtitle:name,
      bodyHtml:plan.missing.map((exit,i) => `<div class="sheet-field"><label for="mappedExit${i}">${esc(exit)} 在此订阅中不可用</label>
        <select class="sheet-input" id="mappedExit${i}"><option value="">请选择替代出口</option>${plan.available.map(v => `<option value="${esc(v)}">${esc(exitDisplayLabel(v))}</option>`).join('')}</select></div>`).join(''),
      actionsHtml:'<button class="glass-btn-soft" id="mappingCancel">取消</button><button class="glass-btn-primary" id="mappingApply" disabled>应用并切换</button>'});
    const apply = $<HTMLButtonElement>('mappingApply');
    const fields = plan.missing.map((_,i) => $<HTMLSelectElement>(`mappedExit${i}`));
    fields.forEach(field => field.onchange = () => {apply.disabled = fields.some(f => !f.value);});
    $('mappingCancel').onclick = closeSheet;
    apply.onclick = async () => {
      apply.disabled = true;
      const mapping = Object.fromEntries(plan.missing.map((exit,i) => [exit, fields[i].value]));
      if (await switchSubscription(name,mapping) && apply.isConnected) closeSheet();
      apply.disabled = false;
    };
  }

  async function switchSubscription(name: string, mapping?: Record<string,string>): Promise<boolean> {
    if (changingSubscription || networkUpdating || selectingNode || changingMode) return false;
    probeGeneration++;
    changingSubscription = true;
    pendingSubscription = name;
    renderAllSafe();
    try {
      const previous = liveProfile?.subscriptionScope || '';
      for (const g of liveProfile?.groups || []) {
        const live = liveCore?.proxies?.proxies?.[g.name];
        if (live?.type === 'Selector' && live.now && !groupSelections.has(JSON.stringify([previous, g.name]))) {
          groupSelections.set(JSON.stringify([previous, g.name]), live.now);
          saveMap(KEY_GROUP_EXITS, groupSelections);
        }
      }
      if (name && !mapping) {
        const plan = await tauriApi.subscriptionMapping(name);
        if (plan.missing.length) {showScopeMapping(name,plan); return false;}
      }
      const profile = await tauriApi.setSubscriptionScope(name || null,mapping);
      applyProfile(profile);
      const remembered = subscriptionSelections.get(name);
      if (remembered) localStorage.setItem(KEY_PENDING_NODE, JSON.stringify([name, remembered]));
      restoredGroupScope = null;
      notify(name ? `已切换至订阅「${name}」` : '已切换至默认配置');
      return true;
    } catch (err) {
      notify(cleanError(err), true);
      return false;
    } finally {
      changingSubscription = false;
      pendingSubscription = '';
      await reloadProfile();
      await refreshLiveState(true);
    }
  }

  async function rememberLiveNodes(snapshot: MihomoSnapshot): Promise<void> {
    const providers = snapshot.providers?.providers || {};
    const global = snapshot.proxies?.proxies?.GLOBAL;
    const pendingRaw = localStorage.getItem(KEY_PENDING_NODE);
    let pendingProvider = '';
    let pendingName = '';
    if (pendingRaw) {
      try {
        [pendingProvider, pendingName] = JSON.parse(pendingRaw);
      } catch {}
    }
    for (const saved of liveProfile?.providers || []) {
      const data = providers[saved.name];
      const updatedAt = Date.parse(data?.updatedAt || '');
      if (data?.subscriptionInfo || (Number.isFinite(updatedAt) && new Date(updatedAt).getFullYear() > 1970)) {
        saveCardMeta(saved.name, new Date(updatedAt).getFullYear() > 1970 ? updatedAt : 0, data.subscriptionInfo);
      }
      if (Array.isArray(data?.proxies)) {
        subscriptionNodes.set(saved.name, data.proxies.map(({ name, type }) => ({ name, type })));
        if (saved.name !== pendingProvider && global?.now && data.proxies.some(n => n.name === global.now)) {
          if (subscriptionSelections.get(saved.name) !== global.now) {
            subscriptionSelections.set(saved.name, global.now);
            saveMap(KEY_SUB_EXITS, subscriptionSelections);
          }
        }
      }
    }
    saveMap(KEY_SUB_NODES, subscriptionNodes);

    if (!pendingRaw || pendingProvider !== selectedSubscription || snapshot.config?.mode === 'rule' || global?.type !== 'Selector') {
      return;
    }
    const belongs = POLICY_CARDS.some(p => p.name === pendingName)
      || providers[pendingProvider]?.proxies?.some(n => n.name === pendingName);
    if (!belongs || !global.all?.includes(pendingName)) return;
    if (global.now !== pendingName) {
      await tauriApi.mihomoSelect(pendingName);
      global.now = pendingName;
    }
    subscriptionSelections.set(pendingProvider, pendingName);
    saveMap(KEY_SUB_EXITS, subscriptionSelections);
    if (localStorage.getItem(KEY_PENDING_NODE) === pendingRaw) localStorage.removeItem(KEY_PENDING_NODE);
  }

  async function restoreGroupSelections(snapshot: MihomoSnapshot): Promise<void> {
    if (!liveProfile) return;
    const scope = liveProfile.subscriptionScope || '';
    if (restoredGroupScope === scope) return;
    const proxies = snapshot.proxies?.proxies;
    for (const g of liveProfile.groups || []) {
      const live = proxies?.[g.name];
      if (live?.type !== 'Selector' || !live.all?.length) continue;
      const saved = groupSelections.get(JSON.stringify([scope, g.name]));
      const target = saved && live.all.includes(saved) ? saved : live.now;
      if (target && target !== live.now) {
        await tauriApi.mihomoSelectGroup(g.name, target);
        live.now = target;
      }
    }
    restoredGroupScope = scope;
  }

  function recordTraffic(conn: MihomoSnapshot['connections'] | undefined): void {
    const down = conn?.downloadTotal;
    const up = conn?.uploadTotal;
    const current = typeof down === 'number' && typeof up === 'number' ? { time: performance.now(), down, up } : null;
    const rates = current && trafficRates(lastTraffic, current);
    lastTraffic = current;
    const downText = rates ? formatRate(rates.down) : '—';
    const upText = rates ? formatRate(rates.up) : '—';
    $('kpiDown').textContent = downText;
    $('kpiUp').textContent = upText;
    $('sideDownRate').textContent = `${downText} ↓`;
    $('sideUpRate').textContent = `${upText} ↑`;
    $('kpiTotal').textContent = current ? formatBytes(current.down + current.up) : '—';
    const stopped = !liveError && liveStatus?.running === false;
    $('sideMemText').textContent = current
      ? conn?.memory ? formatBytes(conn.memory) : `${conn?.count ?? 0} 连接`
      : stopped ? '未运行' : '暂无采样';
    $('chartLossFoot').textContent = rates ? '约每 2 秒采样' : stopped ? '内核已停止' : current ? '等待下次采样' : '采样不可用';
    if (rates) telemetry.pushSample(rates.down, rates.up);
    if (typeof conn?.count === 'number') telemetry.pushConnectionCount(conn.count, rates);
  }

  async function refreshNetworkDetails(force = false): Promise<void> {
    if (readingNetwork || (!force && Date.now() - lastNetworkRead < 15000)) return;
    readingNetwork = true;
    lastNetworkRead = Date.now();
    try {
      networkDetails = await tauriApi.systemNetworkDetails();
    } catch {
      networkDetails = { addresses: [], dns: [], error: true };
    } finally {
      readingNetwork = false;
      if (shell.getView() === 'settings') renderSettings();
    }
  }

  async function refreshConnectionLogs(clear = false): Promise<void> {
    const seq = ++logSeq;
    try {
      const rows = await tauriApi.connectionLogs(clear);
      if (seq !== logSeq) return;
      liveLogs = rows;
      if (shell.getView() === 'logs') renderLogs();
    } catch (err) {
      if (clear) notify(cleanError(err), true);
    }
  }

  async function refreshProcesses(showToast = false): Promise<void> {
    const btn = document.getElementById('refreshProcsBtn') as HTMLButtonElement | null;
    if (btn) btn.disabled = true;
    try {
      const list = await tauriApi.listRunningProcesses();
      liveProcesses = list;
      liveApps = groupRunningApps(list);
      processStatus = '暂无可显示的运行程序';
      renderConnect();
      if (shell.getView() === 'split') renderSplit();
      if (showToast) notify(`已扫描 ${liveApps.length} 个应用（${liveProcesses.length} 个进程）`);
    } catch (err) {
      processStatus = '读取程序失败，可在分流与程序中重试';
      if (shell.getView() === 'connect') renderConnect();
      if (showToast) notify(cleanError(err), true);
    } finally {
      if (btn) btn.disabled = false;
    }
  }

  async function refreshInstanceLifetimes(): Promise<void> {
    const profile = liveProfile;
    const entries = profile?.ruleInstances?.flatMap((instance, index) => instance ? [{
      instance, line: profile.rules?.[index] || '',
    }] : []) ?? [];
    if (!entries.length) return;
    const alive = await tauriApi.checkProcessInstances(entries.map(entry => entry.instance));
    if (profile !== liveProfile || shell.getView() !== 'split') return;
    const ended = new Set(entries.filter((_, index) => alive[index] === false).map(entry => entry.line));
    if (ended.size === endedInstances.size && [...ended].every(line => endedInstances.has(line))) return;
    endedInstances = ended;
    renderSplit();
  }

  let lastFullSnapshot = 0;

  function refreshLiveState(afterChange = false): Promise<void> {
    if (afterChange) lastFullSnapshot = 0;
    if (refreshPromise) {
      if (afterChange) refreshQueued = true;
      return refreshPromise;
    }
    refreshPromise = (async () => {
      do {
        refreshQueued = false;
        await readLiveState();
      } while (refreshQueued);
    })().finally(() => {
      refreshPromise = null;
    });
    return refreshPromise;
  }

  async function readLiveState(): Promise<void> {
    const previousStatus = liveStatus;
    const previousMode = currentMode();
    const previousError = liveError;
    let full = false;
    let counters: MihomoSnapshot['connections'];
    try {
      liveStatus = await tauriApi.coreStatus();
      liveError = '';

      if (liveStatus.running && sessionStartedAt === null) {
        sessionStartedAt = Date.now();
      } else if (!liveStatus.running) {
        sessionStartedAt = null;
      }

      if (lastRunning !== liveStatus.running) {
        lastRunning = liveStatus.running;
        void reloadProfile();
      }

      if (liveStatus.running) {
        full = !liveCore || Date.now() - lastFullSnapshot >= 15000;
        const requestedAt = Date.now();
        const snapshot = await tauriApi.mihomoSnapshot(!full);
        counters = snapshot.connections;
        if (!snapshot.providers && liveCore?.providers) snapshot.providers = liveCore.providers;
        if (full) {
          if (!refreshQueued) lastFullSnapshot = requestedAt;
          await rememberLiveNodes(snapshot).catch(() => {});
          await restoreGroupSelections(snapshot).catch(() => {});
        } else {
          snapshot.proxies = liveCore?.proxies;
        }
        liveCore = snapshot;
      } else {
        liveCore = null;
        exitIp = '';
        restoredGroupScope = null;
      }

      if (shell.getView() === 'logs') void refreshConnectionLogs();
      if (shell.getView() === 'settings') void refreshNetworkDetails();
      if (shell.getView() === 'split') void refreshInstanceLifetimes().catch(() => {});
    } catch (err) {
      liveError = cleanError(err);
    } finally {
      recordTraffic(counters);
      if (full || previousMode !== currentMode() || previousError !== liveError || JSON.stringify(previousStatus) !== JSON.stringify(liveStatus)) {
        renderAllSafe();
      }
    }
  }

  async function ensureLocalCore(): Promise<boolean> {
    if (networkUpdating) throw new Error('正在更新代理状态，请稍后重试。');
    if (localCoreStart) return localCoreStart;
    if (liveStatus?.running && liveCore) return true;
    localCoreStart = (async () => {
      const status = await tauriApi.coreStatus();
      if (!status.configured) return false;
      if (!status.available) throw new Error('应用内核缺失，请重新安装完整的 Xeylroute 安装包。');
      if (!status.running) await tauriApi.startLocalCore();
      await refreshLiveState(true);
      if (!liveCore) throw new Error(liveError || '暂时无法连接到运行中的代理内核。');
      return true;
    })().finally(() => {
      localCoreStart = null;
      renderAllSafe();
    });
    return localCoreStart;
  }

  async function performNetworkControl(action: NetworkControlAction): Promise<void> {
    if (networkUpdating || changingSubscription) return;
    probeGeneration++;
    networkUpdating = true;
    renderHeaderState();
    syncTray();
    try {
      await localCoreStart?.catch(() => {});
      const current = await tauriApi.coreStatus();
      if (action.enabled && !current.available) {
        throw new Error('应用内核缺失，请重新安装完整的 Xeylroute 安装包。');
      }
      if (action.enabled && !current.configured) {
        throw new Error('请先在「订阅管理」中添加订阅、粘贴节点链接或导入配置文件。');
      }

      if (action.control === 'tun') {
        if (action.enabled === current.tun) return;
        if (action.enabled) {
          if (current.tunScope === 'selected' && !current.selectedTunAvailable) {
            throw new Error('指定软件 TUN 需要 Windows x64 和随安装包提供的签名驱动。');
          }
          const accepted = await confirmSheet({
            title: '开启虚拟网卡 (TUN)',
            message: tunElevationMessage(current.platform, current.tunScope),
            confirmLabel: '继续授权',
            tone: 'cyan',
          });
          if (!accepted) return;
        }
        try {
          if (current.running) await tauriApi.stopLocalCore();
          if (action.enabled) await tauriApi.startGlobalTun();
          else await tauriApi.startLocalCore();
          if (current.systemProxy) await tauriApi.setSystemProxy(true);
          notify(action.enabled ? '虚拟网卡 (TUN) 已开启' : '已切换回普通代理内核');
        } catch (err) {
          if (current.running) {
            try {
              const after = await tauriApi.coreStatus();
              if (after.running && after.tun !== current.tun) await tauriApi.stopLocalCore();
              if (current.tun && (!after.running || !after.tun)) {
                const restoreOk = await confirmSheet({
                  title: '恢复原 TUN 连接',
                  message: '未能切换到普通代理。是否重新开启原来的 TUN？系统可能会再次请求管理员授权。',
                  confirmLabel: '恢复 TUN',
                });
                if (!restoreOk) throw new Error('已取消恢复 TUN。');
                await tauriApi.startGlobalTun();
              } else if (!current.tun && (!after.running || after.tun)) {
                await tauriApi.startLocalCore();
              }
              if (current.systemProxy) await tauriApi.setSystemProxy(true);
            } catch (restoreErr) {
              throw new Error(`${cleanError(err)}\n原代理状态恢复失败：${cleanError(restoreErr)}`);
            }
            throw new Error(`${cleanError(err)}\n已恢复切换前的代理状态。`);
          }
          throw err;
        }
        return;
      }

      if (action.control === 'core') {
        if (action.enabled && !current.running) {
          await tauriApi.startLocalCore();
          notify('代理内核已启动');
        } else if (!action.enabled && current.running) {
          await tauriApi.stopLocalCore();
          notify('已断开并关闭系统代理 / TUN');
        }
        return;
      }

      if (action.enabled && !current.running) {
        await tauriApi.startLocalCore();
      }
      try {
        if (current.systemProxy !== action.enabled) {
          await tauriApi.setSystemProxy(action.enabled);
        }
        notify(action.enabled ? '已连接并开启系统代理' : '系统代理已关闭');
      } catch (err) {
        if (action.enabled && !current.running) {
          try {
            await tauriApi.stopLocalCore();
          } catch (cleanupErr) {
            throw new Error(`${cleanError(err)}\n代理服务停止失败：${cleanError(cleanupErr)}`);
          }
        }
        throw err;
      }
    } catch (err) {
      if (action.fromTray) await tauriApi.showWindow().catch(() => {});
      notify(cleanError(err), true);
    } finally {
      networkUpdating = false;
      await refreshLiveState(true);
      renderHeaderState();
    }
  }

  async function selectLiveNode(name: string, fromTray = false): Promise<void> {
    if (selectingNode || changingMode || changingSubscription || networkUpdating) return;
    if (!liveCore) {
      subscriptionSelections.set(selectedSubscription, name);
      saveMap(KEY_SUB_EXITS, subscriptionSelections);
      localStorage.setItem(KEY_PENDING_NODE, JSON.stringify([selectedSubscription, name]));
      renderAllSafe();
      notify(`已预选默认节点：${name}（启动代理后自动生效）`);
      return;
    }
    const global = liveCore.proxies?.proxies?.GLOBAL;
    if (global?.type !== 'Selector' || !global.all?.includes(name)) {
      notify('当前内核出口列表中不含该节点', true);
      return;
    }
    selectingNode = true;
    renderHeaderState();
    syncTray();
    try {
      await tauriApi.mihomoSelect(name);
      global.now = name;
      subscriptionSelections.set(selectedSubscription, name);
      saveMap(KEY_SUB_EXITS, subscriptionSelections);
      localStorage.removeItem(KEY_PENDING_NODE);
      notify(`默认节点已切换至 ${name}`);
      await refreshLiveState(true);
    } catch (err) {
      if (fromTray) await tauriApi.showWindow().catch(() => {});
      notify(cleanError(err), true);
    } finally {
      selectingNode = false;
      renderAllSafe();
    }
  }

  async function changeLiveMode(mode: RoutingMode, fromTray = false): Promise<void> {
    if (changingMode || selectingNode || changingSubscription || networkUpdating || mode === currentMode()) return;
    changingMode = true;
    syncTray();
    try {
      const profile = await tauriApi.editProfile({ kind: 'mode', mode }, liveProfile?.subscriptionScope ?? '');
      applyProfile(profile);
      notify(`已切换为${{ rule: '规则', global: '全局', direct: '直连' }[mode]}模式`);
      await refreshLiveState(true);
    } catch (err) {
      if (fromTray) await tauriApi.showWindow().catch(() => {});
      notify(cleanError(err), true);
    } finally {
      changingMode = false;
      renderAllSafe();
    }
  }

  function scheduleProbeRender(): void {
    if (probeRenderTimer || document.hidden) return;
    probeRenderTimer = window.setTimeout(() => {
      probeRenderTimer = 0;
      if (!document.hidden && !isSheetOpen() && !$('macMenuPopover').classList.contains('open')) renderView();
    }, 100);
  }

  async function testSingleNode(node: NodeCardItem, download = true): Promise<void> {
    if (networkUpdating || changingSubscription) return;
    if (!(node.name === 'AUTO' || isTestableNode(node))) return;
    const key = delayKey(node.provider, node.name);
    if (liveTesting.has(key)) return;
    const generation = probeGeneration;
    liveTesting.add(key);
    scheduleProbeRender();
    try {
      const ready = await ensureLocalCore();
      if (!ready) throw new Error('请先导入订阅或节点链接。');
      if (generation !== probeGeneration) return;
      const result = await tauriApi.mihomoDelay(node.name, node.policy ? null : node.provider, download, probeTarget.value, Number(probeTimeout.value));
      if (generation !== probeGeneration) return;
      const previous = liveDelays.get(key);
      if (!download && previous && typeof previous !== 'string') result.mbps = previous.mbps;
      liveDelays.set(key, result);
    } catch (err) {
      if (generation === probeGeneration) liveDelays.set(key, cleanError(err));
    } finally {
      liveTesting.delete(key);
      scheduleProbeRender();
    }
  }

  async function runBatch(kind: 'delay' | 'download' | 'sites'): Promise<void> {
    if (batchTesting || networkUpdating || changingSubscription) return;
    const generation = probeGeneration;
    batchTesting = true;
    renderView();
    try {
      if (!await ensureLocalCore()) throw new Error('请先添加订阅或节点链接。');
      const active = () => generation === probeGeneration && Boolean(liveStatus?.running);
      const jobs = kind === 'sites'
        ? sites.flatMap(([, items], ci) => items.map((_, si) => () => probeSite(ci, si)))
        : allSelectableNodes().map(node => () => testSingleNode(node, kind === 'download'));
      if (!jobs.length) { notify('暂无可测速目标'); return; }
      const concurrency = kind === 'download' ? 1 : Number(probeWorkers.value);
      const label = { delay: '节点延迟', download: '节点带宽', sites: '网站连通性' }[kind];
      notify(`正在测量 ${jobs.length} 个目标的${label}`);
      await runProbeQueue(jobs, concurrency, job => job(), active);
      notify(active() ? `${label}测试完成` : '测速已中止');
    } catch (err) {
      notify(cleanError(err), true);
    } finally {
      batchTesting = false;
      scheduleProbeRender();
    }
  }

  async function probeSite(ci: number, si: number): Promise<void> {
    const item = sites[ci]?.[1]?.[si];
    if (!item) return;
    const key = `${ci}-${si}`;
    if (siteProbing.has(key)) return;
    const generation = probeGeneration;
    siteProbing.add(key);
    scheduleProbeRender();
    try {
      if (!await ensureLocalCore()) throw new Error('请先添加订阅或导入配置。');
      if (generation !== probeGeneration) return;
      const res = await tauriApi.mihomoWebsiteProbe(item.h);
      if (generation !== probeGeneration) return;
      item.ms = res.ms;
      item.status = res.status;
    } catch (err) {
      if (generation !== probeGeneration) return;
      item.ms = -1;
      item.status = 0;
      if (!batchTesting) notify(`${item.n} 测速失败：${cleanError(err)}`, true);
    } finally {
      siteProbing.delete(key);
      scheduleProbeRender();
    }
  }

  /* =========================================================================
     Renderers
     ========================================================================= */
  function renderHeaderState(): void {
    const mode = currentMode();
    const cap = captureSummary();
    const modeLabel = { rule: '规则模式', global: '全局模式', direct: '直连模式' }[mode];
    const modeIdx = { rule: 0, global: 1, direct: 2 }[mode] || 0;
    if (liveStatus?.platform) {
      applyPlatformClass(liveStatus.platform);
    }

    $('modePill').dataset.idx = String(modeIdx);
    document.querySelectorAll<HTMLButtonElement>('.mode-pill button').forEach(b => {
      b.classList.toggle('active', b.dataset.mode === mode);
      b.disabled = !liveProfile || changingMode || networkUpdating;
    });

    $('sidebarBrandSub').textContent = `${modeLabel} · ${cap || (liveStatus?.running ? '本地监听' : '未接管')}`;
    const sysInput = $<HTMLInputElement>('sideSysProxy');
    const tunInput = $<HTMLInputElement>('sideTunToggle');
    sysInput.checked = Boolean(liveStatus?.systemProxy);
    tunInput.checked = Boolean(liveStatus?.tun);
    sysInput.disabled = networkUpdating || changingSubscription;
    tunInput.disabled = networkUpdating || changingSubscription;

    const realNodes = allSelectableNodes();
    const storedRules = (liveProfile?.rules || []).filter(r => !r.startsWith('MATCH,'));
    $('navNodeBadge').textContent = String(realNodes.length);
    $('navRuleBadge').textContent = String(storedRules.length);
    $('navSubBadge').textContent = String(liveProfile?.providers.length ?? 0);

    const activeExit = activeGlobalExit();
    const activeCapture = Boolean(liveStatus?.systemProxy || liveStatus?.tun);
    const pill = $('topOnlinePill');
    pill.className = 'online-pill' + (networkUpdating ? ' warn' : !liveStatus?.running ? ' off' : !activeCapture ? ' warn' : '');
    $('topStatusText').textContent = networkUpdating
      ? '正在更新代理…'
      : !liveStatus?.running
        ? '未启动'
        : !activeCapture
          ? '仅本地监听'
          : `${mode === 'direct' ? '直连' : '已连接'} · ${activeExit}`;

    const coreBtn = $<HTMLButtonElement>('coreControlBtn');
    coreBtn.disabled = !liveStatus || networkUpdating || changingSubscription;
    coreBtn.textContent = networkUpdating ? '处理中…' : liveStatus?.running ? '停止内核' : '启动内核';
    coreBtn.title = liveStatus?.running ? '停止监听，并关闭系统代理和虚拟网卡' : '仅启动本地代理监听';
    $('sideCoreLabel').textContent = liveStatus
      ? liveStatus.available ? 'Mihomo Core' : '缺少 Mihomo 内核'
      : liveError ? '内核状态未知' : '正在检查内核…';

    syncTray();
  }

  function renderDesktopBanner(): void {
    const banner = $('desktopStatusBanner');
    if (!liveStatus) {
      banner.hidden = true;
      return;
    }
    if (!liveStatus.available) {
      banner.hidden = false;
      banner.textContent = '应用内核缺失，请重新安装完整的 Xeylroute 安装包。';
      return;
    }
    if (!liveStatus.configured) {
      banner.hidden = false;
      banner.innerHTML = `
        <div class="desktop-banner-text">
          <strong>尚未添加节点或订阅配置</strong>
          <small>粘贴 HTTPS 订阅链接、vless:// / trojan:// / ss:// / hy2:// 节点链接，或导入本地 YAML / JSON 配置即可开始代理。</small>
        </div>
        <button type="button" class="glass-btn-primary compact" id="bannerImportBtn">立即导入</button>
      `;
      return;
    }
    if (liveError) {
      banner.hidden = false;
      banner.innerHTML = `
        <div class="desktop-banner-text">
          <strong style="color:var(--orange)">内核状态提示</strong>
          <small>${esc(liveError)}</small>
        </div>
        <button type="button" class="glass-btn-soft" id="bannerRetryBtn">重试</button>
      `;
      return;
    }
    banner.hidden = true;
  }

  function programRuleKey(path: string): string {
    return liveStatus?.platform === 'windows' ? normalizedProgramPath(path) : path;
  }

  function programPathExits(): Map<string, string> {
    const exits = new Map<string, string>();
    for (const rule of liveProfile?.processRules || []) {
      const path = programRuleKey(rule.target);
      if (rule.kind === 'PROCESS-PATH' && !exits.has(path)) exits.set(path, rule.exit);
    }
    return exits;
  }

  function appExitLabel(paths: string[], rules: Map<string, string>): string {
    const values = paths.map(path => rules.get(programRuleKey(path)));
    const exit = values[0];
    if (!exit) return values.some(Boolean) ? '多项规则' : '按分流规则';
    const isNode = liveProfile?.nodePins?.[exit] || liveProfile?.nodes.some(n => n.name === exit);
    const label = isNode ? `指定节点：${exitDisplayLabel(exit)}` : exitDisplayLabel(exit);
    if (values.every(value => value === exit)) return label;
    if (values.slice(1).every(value => !value)) return `${label}（主程序）`;
    return '多项规则';
  }

  function renderConnect(): void {
    renderDesktopBanner();
    const realNodes = allSelectableNodes();
    const activeExit = activeGlobalExit();
    const activeNodeObj = realNodes.find(n => n.name === activeExit);
    const autoNow = liveCore?.proxies?.proxies?.AUTO?.now;
    const displayName = activeExit === 'AUTO' && autoNow ? `AUTO · ${autoNow}` : activeExit;
    const elapsedSec = sessionStartedAt ? Math.floor((Date.now() - sessionStartedAt) / 1000) : 0;
    const storedRules = (liveProfile?.rules || []).filter(r => !r.startsWith('MATCH,'));
    const activeRuleCount = storedRules.filter(r => !liveProfile?.disabledRules?.includes(r)).length;

    $('kpiTimer').textContent = fmtTime(elapsedSec);
    $('kpiRules').textContent = `${activeRuleCount} 条`;
    $('goAllNodesBtn').textContent = `全部 ${realNodes.length} 个节点 ›`;
    const port = activeListenPort();
    $('homePortFoot').textContent = port ? `127.0.0.1:${port}` : '无 HTTP 监听';

    $('heroFlag').innerHTML = flagSvg(activeExit === 'AUTO' ? autoNow || activeExit : activeExit);
    $('heroProbeBtn').hidden = !activeNodeObj && activeExit !== 'AUTO';
    $('heroNodeName').textContent = displayName || '—';
    $('heroNodeProto').textContent = activeNodeObj?.type || (activeExit === 'AUTO' ? 'URLTest' : activeExit);
    const heroDelayInfo = activeNodeObj
      ? delayForNode(activeNodeObj)
      : activeExit === 'AUTO' && autoNow
        ? delayForNode({ name: autoNow, type: '', provider: selectedSubscription || null })
        : { text: '—', cls: '' };
    $('heroNodeDelay').innerHTML = heroDelayInfo.raw
      ? `<i class="mini-dot"></i> ${heroDelayInfo.raw} ms`
      : heroDelayInfo.text === '测速中'
        ? '测速中…'
        : '';
    const subLabel = selectedSubscription || (activeNodeObj?.standalone ? '独立导入节点' : '默认配置');
    const capture = captureSummary();
    const status = liveStatus?.running ? capture || '仅本地监听' : '未接管';
    const globalHistory = liveCore?.proxies?.proxies?.[activeExit === 'AUTO' ? autoNow || 'AUTO' : activeExit]?.history;
    const globalFailure = currentMode() === 'global' && globalHistory?.at(-1)?.delay === 0;
    $('heroNodeMeta').textContent = [
      subLabel, status, liveStatus?.running && exitIp ? `出口 ${exitIp}` : '',
      globalFailure ? '全局出口探测失败，请重新选择节点' : '',
    ].filter(Boolean).join(' · ');
    $('chartModeBadge').textContent = `${{ rule: '规则', global: '全局', direct: '直连' }[currentMode()]}模式 · ${captureSummary() || (liveStatus?.running ? '本地监听' : '未接管')}`;
    $('homeAutoFoot').parentElement!.hidden = !hasAutoExit();
    $('homeAutoFoot').textContent = activeExit === 'AUTO'
      ? `已启用 AUTO 智能优选${autoNow ? ` · 当前 ${autoNow}` : ''}`
      : `自动优选（AUTO）${autoNow ? `推荐：${autoNow}` : '可用'}`;
    $('pickAutoQuickBtn').hidden = activeExit === 'AUTO';
    $('pickAutoQuickBtn').dataset.pickNode = 'AUTO';

    const q = shell.getSearch().trim().toLowerCase();
    const list = (q ? realNodes.filter(n => [n.name, n.type].join(' ').toLowerCase().includes(q)) : realNodes).slice(0, 6);
    $('homeQuickNodes').innerHTML = list.map(n => {
      const d = delayForNode(n);
      const selected = activeExit === n.name || (activeExit === 'AUTO' && autoNow === n.name);
      return `
        <button type="button" class="cp-node ${selected ? 'selected' : ''}" data-pick-node="${esc(n.name)}">
          <div class="cp-node-left">
            <span class="flag-box">${flagSvg(n.name)}</span>
            <div style="min-width:0">
              <div class="cp-node-title">${esc(n.name)}</div>
              <span class="cp-node-sub">${esc(n.type)}${n.standalone ? ' · 独立节点' : ''}</span>
            </div>
          </div>
          <span class="cp-node-ms ${d.cls}">${esc(d.text)}${d.raw !== undefined ? '<small>ms</small>' : ''}</span>
        </button>
      `;
    }).join('') || `<div style="grid-column:1/-1;text-align:center;padding:24px;color:var(--muted)">${realNodes.length ? '没有匹配的节点' : '暂无可用代理节点'}</div>`;

    // Right App Exits (real top 4 grouped apps)
    const ruleMap = programPathExits();
    const topApps = liveApps.filter(app => !q || [app.name, ...app.paths].some(value => value.toLowerCase().includes(q))).slice(0, 4);
    $('homeAppExits').innerHTML = topApps.length
      ? topApps.map(app => {
          const exits = new Set(app.paths.map(p => ruleMap.get(programRuleKey(p)) || ''));
          const val = exits.size === 1 ? [...exits][0] : null;
          const label = appExitLabel(app.paths, ruleMap);
          return `
            <div class="mac-row">
              <div class="mac-row-left">
                ${renderProgramIcon(app.icon, app.name)}
                <div style="min-width:0">
                  <span class="mac-row-title">${esc(app.name)}</span>
                  <span class="mac-row-sub"><i class="mini-dot"></i> ${esc(app.exe)} · ${app.instances} 进程</span>
                </div>
              </div>
              ${macPopupBtnHtml({
                value: val,
                label,
                width: 128,
                popupKind: 'app-exit',
                popupKey: app.path,
              })}
            </div>
          `;
        }).join('')
      : `<div style="padding:26px 14px;text-align:center;color:var(--muted);font-size:var(--type-label)">${q ? '没有匹配的应用' : processStatus}</div>`;

    // Active subscription summary
    const activeSub = liveProfile?.providers.find(p => p.name === selectedSubscription) || liveProfile?.providers[0];
    if (activeSub) {
      const meta = subscriptionCardData.get(activeSub.name);
      const usage = meta?.usage;
      const used = (usage?.Upload || 0) + (usage?.Download || 0);
      const hasQuota = Boolean(usage?.Total && usage.Total > 0);
      const pct = hasQuota ? Math.min(100, Math.round((used / usage!.Total!) * 100)) : 0;
      const updated = meta?.updatedAt ? new Date(meta.updatedAt).toLocaleDateString() : (activeSub.type === 'http' ? '待刷新' : '本地文件');
      $('homeSubCard').innerHTML = `
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:9px">
          <div style="display:flex;align-items:center;gap:10px;min-width:0">
            <span class="sq md blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/></svg></span>
            <div style="min-width:0">
              <strong class="card-title" style="display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(activeSub.name)}</strong>
              <small style="color:var(--muted);font-size:var(--type-caption)">${esc(activeSub.source || (activeSub.type === 'http' ? '远程订阅' : '本地订阅'))} · ${esc(updated)}</small>
            </div>
          </div>
        </div>
        ${hasQuota ? `
          <div style="display:flex;justify-content:space-between;font-size:var(--type-caption);color:var(--muted);margin-bottom:5px;font-family:var(--font-mono)">
            <span>已用 ${esc(formatBytes(used))} / ${esc(formatBytes(usage!.Total!))}</span>
            <span style="color:var(--ink-2);font-weight:var(--weight-title)">${pct}%</span>
          </div>
          <div class="mac-progress"><span style="width:${pct}%"></span></div>
        ` : `
          <div style="font-size:var(--type-label);color:var(--muted)">当前订阅共 ${activeSubscriptionNodes().length} 个可用节点</div>
        `}
      `;
    } else {
      const staticCount = standaloneNodes().length;
      $('homeSubCard').innerHTML = `
        <div style="display:flex;align-items:center;justify-content:space-between">
          <div style="display:flex;align-items:center;gap:10px">
            <span class="sq md orange"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><polygon points="12 3 3 8 12 13 21 8 12 3"/><polyline points="3 12.5 12 17.5 21 12.5"/></svg></span>
            <div>
              <strong class="card-title" style="display:block">${staticCount ? `独立导入节点 (${staticCount})` : '暂无远程订阅'}</strong>
              <small style="color:var(--muted);font-size:var(--type-caption)">${staticCount ? '已导入节点可直接代理或加入分组' : '支持 HTTPS 订阅与单节点分享链接'}</small>
            </div>
          </div>

        </div>
      `;
    }
  }

  function exitDisplayLabel(name: string): string {
    if (!name || name === 'GLOBAL') return '跟随首页节点';
    if (name === 'DIRECT') return 'DIRECT · 直连';
    if (name === 'REJECT') return 'REJECT · 阻断';
    if (name === 'PASS') return '跟随其余规则';
    if (name === 'AUTO') {
      const now = liveCore?.proxies?.proxies?.AUTO?.now;
      return now ? `AUTO (${now})` : 'AUTO · 自动优选';
    }
    return liveProfile?.nodePins?.[name] || name;
  }

  function renderNodes(): void {
    const needsImport = liveStatus?.configured === false;
    $('nodesEmpty').hidden = nodesSub !== 'groups' || !needsImport;
    $('nodesImportBtn').hidden = $('nodesEmpty').hidden;
    $('nodesGroupsPane').hidden = nodesSub !== 'groups' || needsImport;
    $('nodesSitesPane').hidden = nodesSub !== 'sites';
    const actBtn = $<HTMLButtonElement>('nodesActionBtn');
    actBtn.textContent = batchTesting ? '测速中…' : nodesSub === 'groups' ? '全部测延迟' : '全部站点测速';
    actBtn.hidden = nodesSub === 'groups' && needsImport;
    actBtn.disabled = needsImport || batchTesting || networkUpdating || changingSubscription;
    const bandwidth = $<HTMLButtonElement>('nodesBandwidthBtn');
    bandwidth.hidden = nodesSub !== 'groups' || needsImport;
    bandwidth.disabled = actBtn.disabled;

    $('fixedSocksTab').hidden = false;
    $('fixedSocksPane').hidden = nodesSub !== 'ports';
    $('portSearch').hidden = nodesSub !== 'ports';
    if (nodesSub === 'ports') {
      $('nodesScopePill').hidden = true;
      actBtn.textContent = '添加固定入口';
      actBtn.disabled = !liveProfile || needsImport || profileBusy || changingSubscription;
      renderFixedSocks();
      return;
    }

    const scopePill = $('nodesScopePill');
    if (selectedSubscription) {
      scopePill.hidden = false;
      scopePill.textContent = `当前订阅：${selectedSubscription}`;
    } else {
      scopePill.hidden = true;
    }

    const q = shell.getSearch().trim().toLowerCase();
    if (nodesSub === 'sites') {
      renderSiteTests();
      return;
    }
    if (needsImport) return;
    const shared = sharedDrawerNodes();
    const activeExit = activeGlobalExit();

    const drawers: {
      id: string;
      name: string;
      sub: string;
      selected: string;
      isGroup?: boolean;
      canPick: boolean;
      nodes: NodeCardItem[];
    }[] = [
      {
        id: 'SHARED',
        name: '默认节点',
        sub: `当前使用 ${exitDisplayLabel(activeExit)}`,
        selected: activeExit,
        canPick: true,
        nodes: shared,
      },
      ...(liveProfile?.groups || []).map(g => {
        const live = liveCore?.proxies?.proxies?.[g.name];
        const members = live?.all?.length
          ? live.all.filter(m => !HIDDEN_NODES.has(m))
          : [...(g.proxies || [])];
        const items: NodeCardItem[] = members
          .map(m => ({
            name: m,
            type: liveCore?.proxies?.proxies?.[m]?.type || (['DIRECT', 'REJECT', 'AUTO'].includes(m) ? '策略' : '节点'),
            provider: selectedSubscription || null,
            policy: ['DIRECT', 'REJECT', 'AUTO'].includes(m),
          }));
        return {
          id: `grp:${g.name}`,
          name: g.name,
          sub: `${g.type} · 当前 ${live?.now || members[0] || '—'}${g.enabled ? '' : ' · 已停用'}`,
          selected: live?.now || '',
          isGroup: true,
          canPick: live?.type === 'Selector',
          nodes: items,
        };
      }),
    ];

    const matching = drawers.map(d => d.name.toLowerCase().includes(q) ? d : {
      ...d, nodes: d.nodes.filter(n => [n.name, n.type, exitDisplayLabel(n.name)].join(' ').toLowerCase().includes(q)),
    }).filter(d => !q || d.nodes.length || d.name.toLowerCase().includes(q));
    $('nodesGroupsPane').innerHTML = matching.map(d => {
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
                ${d.nodes.map(n => {
                  const key = delayKey(n.provider, n.name);
                  const dInfo = delayForNode(n);
                  const cached = liveDelays.get(key);
                  const speedText = cached && typeof cached !== 'string' && typeof cached.mbps === 'number'
                    ? ` · ${cached.mbps.toFixed(1)} Mbps`
                    : '';
                  const policyTone = n.name === 'DIRECT' ? 'green' : n.name === 'REJECT' ? 'red' : 'blue';
                  const testable = !d.isGroup && (n.name === 'AUTO' || isTestableNode(n));
                  const pickAttr = d.isGroup
                    ? `data-group-pick="${esc(d.name)}::${esc(n.name)}"`
                    : `data-pick-node="${esc(n.name)}"`;
                  const btnHtml = `
                    <button type="button" class="cp-node ${d.selected === n.name ? 'selected' : ''}" ${d.canPick ? pickAttr : 'disabled'}>
                      <div class="cp-node-left">
                        ${n.policy ? `<span class="pill ${policyTone}">${esc(n.type)}</span>` : `<span class="flag-box">${flagSvg(n.name)}</span>`}
                        <div style="min-width:0">
                          <div class="cp-node-title">${esc(n.name)}</div>
                          <span class="cp-node-sub">${esc(n.now ? `当前 ${n.now}` : n.type)}${esc(speedText)}</span>
                        </div>
                      </div>
                      <span class="cp-node-ms ${dInfo.cls}">${esc(dInfo.text)}${dInfo.raw !== undefined ? '<small>ms</small>' : ''}</span>
                    </button>
                  `;
                  if (!testable) return btnHtml;
                  return `
                    <div class="cp-node-wrap">
                      ${btnHtml}
                      <div class="cp-node-tools">
                        <button type="button" class="sf-icon-btn" data-test-node="${esc(n.name)}" data-test-provider="${esc(n.provider || '')}" data-tip="测量延迟和 1 MB 下载速度">${SF_TEST}</button>
                      </div>
                    </div>
                  `;
                }).join('') || `<div style="grid-column:1/-1;text-align:center;padding:24px;color:var(--muted)">暂无节点</div>`}
              </div>
            </div>
          ` : ''}
        </div>
      `;
    }).join('') || '<div class="rule-empty">没有匹配的节点或分组</div>';

  }

  let fixedSocksMarkup = '';
  function renderFixedSocks(): void {
    const bindings = liveProfile?.fixedSocks || [];
    const pane = $('fixedSocksPane');
    const query = shell.getSearch().trim().toLowerCase();
    const rows = bindings.filter(b => [b.node, b.provider, b.port].join(' ').toLowerCase().includes(query));
    const markup = `
      <p class="section-label">本机 SOCKS5 · ${liveStatus?.running ? '内核运行中' : '内核已停止'}</p>
      <div class="mac-card flush">${rows.map(b => `
        <div class="mac-row"><div class="mac-row-left"><div><span class="mac-row-title">${esc(b.node)}</span>
          <div class="mac-row-sub selectable"><code>127.0.0.1:${b.port}</code><span>· ${esc(b.provider || '本地节点')}</span></div></div></div>
          <div class="port-actions">
            <button type="button" class="glass-btn-soft compact" data-clash="${b.port}">Clash 配置…</button>
            <button type="button" class="sf-icon-btn" data-remove-port="${b.port}" aria-label="移除端口 ${b.port}">${SF_TRASH}</button></div></div>`).join('') ||
        `<div class="rule-empty">${bindings.length ? '没有匹配的入口' : '添加固定入口，让 Clash 将选定应用转到指定节点。'}</div>`}</div>
      ${bindings.length && !liveStatus?.running ? '<button type="button" class="glass-btn-soft" id="startSocksCore">启动本地监听</button>' : ''}`;
    // Preserve focus and pending clicks when a status poll returns the same rows.
    if (markup !== fixedSocksMarkup) {
      pane.innerHTML = markup;
      fixedSocksMarkup = markup;
    }
    const start = pane.querySelector<HTMLButtonElement>('#startSocksCore');
    if (start) start.onclick = () => void performNetworkControl({ control: 'core', enabled: true });
    pane.onclick = async event => {
      const button = (event.target as HTMLElement).closest<HTMLButtonElement>('[data-clash], [data-remove-port]');
      if (!button) return;
      const binding = bindings.find(b => b.port === Number(button.dataset.clash || button.dataset.removePort));
      if (!binding) return;
      if (button.dataset.removePort) {
        if (await confirmSheet({ title: '移除固定入口', message: `使用 127.0.0.1:${binding.port} 的客户端将无法再通过该端口连接。`, confirmLabel: '移除' })) {
          await commitProfileEdit({ kind: 'fixedSocks', binding, remove: true }, '入口已移除');
        }
        return;
      }
      const alias = 'Xeylroute-' + binding.port;
      const proxy = `proxies:
  - { name: ${alias}, type: socks5, server: 127.0.0.1, port: ${binding.port}, udp: true }`;
      const seen = new Set<string>();
      const programs = liveProcesses.filter(process => {
        const key = programRuleKey(process.path);
        if (!key || seen.has(key)) return false;
        seen.add(key);
        return true;
      });
      openSheet({ title: '接入 Clash', subtitle: binding.node,
        bodyHtml: `<div class="sheet-field"><label for="clashSocksMode">接入方式</label>
            <select class="sheet-input" id="clashSocksMode"><option value="process">按程序规则</option><option value="listener">专用 SOCKS5 端口</option></select></div>
          <div class="sheet-field" id="clashProgramField"><label for="clashSocksProgram">实际联网程序</label>
            <select class="sheet-input" id="clashSocksProgram"><option value="">ChatGPT（按程序名）</option>
              ${programs.map(program => `<option value="${esc(program.path)}">${esc(program.name)} · ${esc(program.path)}</option>`).join('')}
            </select></div>
          <div class="sheet-field" id="clashPortField" hidden><label for="clashSocksPort">Clash 专用端口</label>
            <input type="number" class="sheet-input" id="clashSocksPort" min="1" max="65535" placeholder="填写一个未使用的端口"></div>
          <p class="sheet-hint" id="clashSocksHelp"></p>
          <textarea id="clashSocksYaml" class="sheet-textarea selectable" rows="7" aria-label="Clash YAML 配置片段" readonly></textarea>`,
        actionsHtml: '<button class="glass-btn-soft" id="closeSocksYaml">完成</button><button class="glass-btn-primary" id="copySocksYaml">复制片段</button>' });
      const yaml = $<HTMLTextAreaElement>('clashSocksYaml');
      const mode = $<HTMLSelectElement>('clashSocksMode');
      const program = $<HTMLSelectElement>('clashSocksProgram');
      const listen = $<HTMLInputElement>('clashSocksPort');
      const copy = $<HTMLButtonElement>('copySocksYaml');
      const used = new Set([liveProfile?.http, liveProfile?.socks, liveProfile?.mixed, ...bindings.map(b => b.port)]);
      function updateSnippet(): void {
        const dedicated = mode.value === 'listener';
        $('clashProgramField').hidden = dedicated;
        $('clashPortField').hidden = !dedicated;
        if (dedicated) {
          const port = listen.valueAsNumber;
          const valid = Number.isInteger(port) && port > 0 && port <= 65535 && !used.has(port);
          $('clashSocksHelp').textContent = listen.value && !valid
            ? '请选择 1 至 65535 之间的空闲端口，避开 Xeylroute 的监听端口。'
            : '将节点和监听分别并入 Clash 的 proxies 和 listeners，再把目标程序的 SOCKS5 代理设为这个专用端口。';
          yaml.value = valid ? `${proxy}

listeners:
  - { name: ${alias}-in, type: socks, listen: 127.0.0.1, port: ${port}, udp: true, proxy: ${alias} }` : '';
        } else {
          const path = program.value;
          const name = liveStatus?.platform === 'windows' ? 'ChatGPT.exe' : 'ChatGPT';
          const regex = path.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
          const match = path ? (path.includes(',') ? `PROCESS-PATH-REGEX,^${regex}$` : `PROCESS-PATH,${path}`) : `PROCESS-NAME,${name}`;
          $('clashSocksHelp').textContent = '在 Clash 更新同名顶层设置，将程序规则放在通用规则前。用 Clash 的连接记录核对程序和出口。macOS 若显示未识别进程，请通过 Clash 客户端授权内核后重新连接。';
          yaml.value = `mode: rule
find-process-mode: always

${proxy}

rules:
  - ${JSON.stringify(`${match},${alias}`)}`;
        }
        copy.disabled = !yaml.value;
      }
      mode.onchange = program.onchange = listen.oninput = updateSnippet;
      updateSnippet();
      $('closeSocksYaml').onclick = closeSheet;
      copy.onclick = async () => {
        try { await navigator.clipboard.writeText(yaml.value); notify('已复制 Clash 配置片段'); }
        catch { yaml.focus(); yaml.select(); notify('已选中片段，请复制'); }
      };
    };
  }

  async function openFixedSocksEditor(): Promise<void> {
    const scope = liveProfile?.subscriptionScope ?? '';
    await loadEditorNodes(scope);
    if (scope !== (liveProfile?.subscriptionScope ?? '') || nodesSub !== 'ports' || shell.getView() !== 'nodes') return;
    const nodes = [...activeSubscriptionNodes(), ...standaloneNodes()];
    const used = new Set([liveProfile?.http, liveProfile?.mixed, liveProfile?.socks,
      ...(liveProfile?.fixedSocks || []).map(b => b.port)]);
    let port = 19081;
    while (used.has(port)) port++;
    openSheet({ title: '添加固定 SOCKS5 入口',
      bodyHtml: `<div class="sheet-field"><label for="fixedNode">固定节点</label>
        <select class="sheet-input" id="fixedNode">${nodes.map((n,i) => `<option value="${i}">${esc(n.name)} · ${esc(n.provider || '本地节点')}</option>`).join('') || '<option>当前没有可用节点</option>'}</select></div>
        <div class="sheet-field"><label for="fixedPort">本机端口</label><input class="sheet-input" type="number" id="fixedPort" min="1" max="65535" value="${port}">
          <small>仅监听 127.0.0.1，切换首页节点时仍使用此出口。</small></div>`,
      actionsHtml: '<button class="glass-btn-soft" id="fixedCancel">取消</button><button class="glass-btn-primary" id="fixedSave">添加</button>' });
    $('fixedCancel').onclick = closeSheet;
    const save = $<HTMLButtonElement>('fixedSave');
    save.disabled = !nodes.length;
    save.onclick = async () => {
      const input = $<HTMLInputElement>('fixedPort');
      if (!input.value || !input.reportValidity()) { input.focus(); return; }
      const node = nodes[Number($<HTMLSelectElement>('fixedNode').value)];
      save.disabled = true;
      const result = await commitProfileEdit({ kind: 'fixedSocks', remove: false,
        binding: { node: node.name, provider: node.provider, port: input.valueAsNumber } }, '固定入口已保存', scope);
      if (result && save.isConnected) closeSheet();
      save.disabled = false;
    };
  }

  function renderSiteTests(): void {
    const q = shell.getSearch().trim().toLowerCase();
    const categories = sites.map(([cat, items], ci) => ({
      cat, ci, rows: items.map((s, si) => ({ s, si })).filter(({ s }) => [cat, s.n, s.h].join(' ').toLowerCase().includes(q)),
    })).filter(category => category.rows.length);
    $('nodesSitesPane').innerHTML = `
      <div class="grid-2col">
        ${categories.map(({cat, ci, rows}) => `
          <div>
            <p class="section-label">${esc(cat)}</p>
            <div class="mac-card flush">
              ${rows.map(({s, si}) => {
                const key = `${ci}-${si}`;
                const busy = siteProbing.has(key);
                let badge = `<span class="pill">未测速</span>`;
                if (busy) badge = `<span class="pill blue">测速中…</span>`;
                else if (s.ms === -1) badge = `<span class="pill red">请求失败</span>`;
                else if (typeof s.ms === 'number') {
                  const tone = (s.status && s.status >= 400) || s.ms >= 400 ? 'orange' : 'green';
                  badge = `<span class="pill ${tone}">${s.ms} ms${s.status ? ` · HTTP ${s.status}` : ''}</span>`;
                }
                return `
                  <div class="mac-row">
                    <div class="mac-row-left">
                      ${renderSiteIcon(s.h, s.n, s.c)}
                      <div>
                        <span class="mac-row-title">${esc(s.n)}</span>
                        <span class="mac-row-sub" style="font-family:var(--font-mono)">${esc(s.h)}</span>
                      </div>
                    </div>
                    <div style="display:flex;align-items:center;gap:8px">
                      ${badge}
                      <button type="button" class="sf-icon-btn" data-probe-site="${key}" ${busy ? 'disabled' : ''} data-tip="实测连通">${SF_REFRESH}</button>
                    </div>
                  </div>
                `;
              }).join('')}
            </div>
          </div>
        `).join('') || '<div class="rule-empty">没有匹配的测速网站</div>'}
      </div>
    `;
  }


  function renderSplit(): void {
    const search = $<HTMLInputElement>('ruleSearch');
    search.placeholder = { rules: '搜索规则', groups: '搜索分组', procs: '搜索运行中的程序' }[splitSub];
    search.setAttribute('aria-label', { rules: '搜索分流规则', groups: '搜索策略分组', procs: '搜索运行中的程序' }[splitSub]);
    $('splitRulesPane').hidden = splitSub !== 'rules';
    $('ruleOrderBtn').hidden = splitSub !== 'rules' || !liveProfile;
    $('bulkRulesBtn').hidden = splitSub !== 'rules';
    $('splitGroupsPane').hidden = splitSub !== 'groups';
    $('splitProcsPane').hidden = splitSub !== 'procs';
    $('splitPrimaryAddBtn').hidden = splitSub === 'procs';
    $<HTMLButtonElement>('splitPrimaryAddBtn').disabled = !liveProfile;
    $('refreshProcsBtn').hidden = splitSub !== 'procs';
    $('splitDefaultWrap').style.display = splitSub === 'procs' ? 'none' : 'flex';
    $('procToolsWrap').style.display = splitSub === 'procs' ? 'flex' : 'none';
    $('splitPrimaryAddBtn').textContent = splitSub === 'groups' ? '+ 创建分组' : '+ 添加规则';

    const scopePill = $('splitScopePill');
    scopePill.hidden = false;
    scopePill.textContent = liveProfile?.subscriptionScope
      ? `订阅范围：${liveProfile.subscriptionScope}`
      : '默认配置';

    const matchLine = liveProfile?.rules?.find(line => line.startsWith('MATCH,'));
    const defaultExit = matchLine?.split(',')[1] || 'DIRECT';
    $('defaultExitSelectHost').innerHTML = macPopupBtnHtml({
      id: 'defaultExitBtn',
      value: defaultExit,
      label: exitDisplayLabel(defaultExit),
      width: 148,
      popupKind: 'default-exit',
      disabled: !liveProfile,
    });

    const q = shell.getSearch().trim().toLowerCase();
    if (splitSub === 'groups') renderGroups(q);
    else if (splitSub === 'procs') renderProcesses(q);
    else renderRules(q);
  }

  function showRuleOrder(): void {
    const profile = liveProfile;
    if (!profile) return;
    const expected = profile.effectiveRules || [];
    const rows = expected.slice();
    let manual = Boolean(profile.manualOrder);
    openSheet({ title: '规则生效顺序', size: 'wide',
      bodyHtml: `<div class="sheet-field"><label for="ruleOrderMode">匹配顺序</label>
        <select class="sheet-input" id="ruleOrderMode" ${profile.managedOrder ? '' : 'disabled'}>
        ${profile.managedOrder ? '<option value="auto">自动优先级</option><option value="manual">手动 · 由上至下</option>' : '<option>完整配置 · 文件顺序</option>'}</select>
        <small id="orderHint"></small></div><div class="sheet-picker" id="orderRows"></div><p class="sheet-error" id="orderError"></p>`,
      actionsHtml: `<button class="glass-btn-soft" id="orderCancel">关闭</button>${profile.managedOrder ? '<button class="glass-btn-primary" id="orderSave">保存</button>' : ''}`,
    });
    const list = $('orderRows');
    const mode = $<HTMLSelectElement>('ruleOrderMode');
    if (profile.managedOrder) mode.value = manual ? 'manual' : 'auto';
    const userLines = new Set(profile.rules);
    const render = () => {
      if (!manual && profile.manualOrder) {
        $('orderHint').textContent = '保存后将重新计算自动优先级。';
        list.replaceChildren();
        return;
      }
      $('orderHint').textContent = manual ? '首条匹配生效，默认出口位于末尾。' : profile.managedOrder ? '阻断和直连优先，系统会补充局域网直连。' : '按导入文件中的顺序匹配。';
      list.innerHTML = (manual ? rows : expected).map((line,i) => {
        const fallback = line.startsWith('MATCH,');
        const source = fallback ? '默认出口' : profile.sharedRules?.some(r => r.line === line) ? '个人共享' : userLines.has(line) ? (profile.subscriptionScope ? '当前订阅' : '当前配置') : '系统补充';
        return `<div class="sheet-picker-row"><small>${i+1}</small><span class="picker-meta"><strong>${esc(line)}</strong><small>${source}</small></span>
          ${manual && !fallback ? `<button class="glass-btn-soft" data-move="-1" data-row="${i}" aria-label="上移" ${i === 0 ? 'disabled' : ''}>↑</button><button class="glass-btn-soft" data-move="1" data-row="${i}" aria-label="下移" ${!rows[i+1] || rows[i+1].startsWith('MATCH,') ? 'disabled' : ''}>↓</button>` : ''}</div>`;
      }).join('');
    };
    mode.onchange = () => { manual = mode.value === 'manual'; render(); };
    list.onclick = event => {
      const b = (event.target as HTMLElement).closest<HTMLButtonElement>('[data-move]');
      if (!b || b.disabled) return;
      const i = Number(b.dataset.row), j = i + Number(b.dataset.move);
      [rows[i], rows[j]] = [rows[j], rows[i]]; render();
    };
    $('orderCancel').onclick = closeSheet;
    if (profile.managedOrder) {
      const save = $<HTMLButtonElement>('orderSave');
      save.onclick = async () => {
        save.disabled = true;
        try {
          const result = await tauriApi.editProfile({kind:'ruleOrder',expected,order:manual ? rows : null},profile.subscriptionScope ?? '');
          applyProfile(result); if (save.isConnected) closeSheet(); renderAllSafe();
        } catch(e) { if (save.isConnected) $('orderError').textContent = cleanError(e); }
        finally { save.disabled = false; }
      };
    }
    render();
  }

  function conditionLabel(conditions: RuleConditions): string {
    const app = conditions.program.split(/[\\/]/).at(-1);
    const target = conditions.suffix ? `${conditions.target} 及子域名` : conditions.target;
    return [app, target, conditions.port && `端口 ${conditions.port}`].filter(Boolean).join(' · ');
  }

  function renderRules(q: string): void {
    const disabledRules = new Set(liveProfile?.disabledRules || []);
    const disabledGroups = new Set(liveProfile?.disabledGroups || []);

    // Sub-tab 1: Rules
    const lines = liveProfile?.rules || [];
    const processes = new Map(liveProcesses.map(proc => [programRuleKey(proc.path), proc]));
    const programPaths = new Set(lines.filter(line => line.startsWith('PROCESS-PATH,')).map(line => line.split(',')[1]));
    const savedApps = groupRunningApps(Array.from(programPaths, path => {
      const exe = path.split(/[\\/]/).at(-1) || path;
      const bundle = path.match(/(?:^|\/)([^/]+)\.app\//i)?.[1];
      return { path, exe, name: processes.get(programRuleKey(path))?.name || bundle || exe };
    }));
    const appByPath = new Map(savedApps.flatMap(app => app.paths.map(path => [path, app] as const)));
    function matches(line: string, type: string, exit: string, active: boolean, app = ''): boolean {
      const kind = type.startsWith('PROCESS') ? '软件 应用 进程' : type.startsWith('DOMAIN') ? '网站 域名'
        : type.startsWith('IP-') ? 'IP 网段' : type === 'AND' ? '组合条件' : '';
      return !q || [line, app, kind, exitDisplayLabel(exit), active ? '启用' : '停用'].join(' ').toLowerCase().includes(q);
    }
    const rules = lines
      .map((line, index) => {
        const [type, ...rest] = line.split(',');
        const payload = type === 'MATCH' ? '' : (rest.slice(0,-1).join(',') || '');
        const exit = liveProfile?.ruleExits?.[index] || rest[rest.length - 1] || '';
        const enabled = !disabledRules.has(line);
        const instance = liveProfile?.ruleInstances?.[index];
        return { line, index, type, payload, exit, enabled, instance, active: enabled && !disabledGroups.has(exit) };
      })
      .filter(r => r.type !== 'MATCH')
      .filter(r => matches(r.line, r.type, r.exit, r.active, r.instance?.path || appByPath.get(r.payload)?.name));
    const buckets = new Map<string, typeof rules>();
    for (const rule of rules) {
      const app = rule.type === 'PROCESS-PATH' && appByPath.get(rule.payload);
      const key = app ? app.path : String(rule.index);
      const members = buckets.get(key);
      if (members) members.push(rule);
      else buckets.set(key, [rule]);
    }
    const groups = [...buckets.values()];

    const bulk = $<HTMLButtonElement>('bulkRulesBtn');
    bulk.disabled = !rules.length;
    bulk.onclick = () => {
      const scope = liveProfile?.subscriptionScope ?? '';
      openRuleBatch(groups.map(group => {
        const r = group[0];
        return { title: group.length > 1 ? appByPath.get(r.payload)!.name : r.instance?.path || r.payload || r.type,
          detail: group.length > 1 ? `${group.length} 条程序路径规则` : r.instance ? `PID ${r.instance.pid} · 本次运行` : r.line,
          count: group.length, enabled: group.every(row => row.enabled === r.enabled) ? r.enabled : null };
      }), (action, selected) => {
        const targets = selected.flatMap(i => groups[i].map(r => ({ index: r.index, expected: r.line })));
        void commitProfileEdit({ kind: 'batchRules', action, rules: targets },
          `已${{ enable: '启用', disable: '停用', delete: '删除' }[action]}${targets.length} 条规则`, scope);
      });
    };


    const shared = (liveProfile?.sharedRules || []).filter(r => matches(
      r.line + ' 个人共享', r.line.split(',')[0], r.line.split(',').at(-1) || '', !disabledGroups.has(r.line.split(',').at(-1) || '')));
    function renderRule(r: (typeof rules)[number]): string {
      const isProc = r.type.startsWith('PROCESS');
      const isDomain = r.type.startsWith('DOMAIN');
      const tone = r.exit === 'DIRECT' ? 'green' : r.exit === 'REJECT' ? 'red' : r.exit === 'PASS' ? 'purple' : 'blue';
      const conditions = liveProfile?.ruleConditions?.[r.index];
      const target = r.instance?.path || r.payload;
      const ended = r.instance && endedInstances.has(r.line);
      const kind = r.instance ? (ended ? '本次运行已结束' : `本次运行 · PID ${r.instance.pid}`) : r.type;
      const shortName = conditions ? conditionLabel(conditions) : isProc ? (target.split(/[\\/]/).at(-1) || target) : target;
      const iconHtml = isProc
        ? renderProgramIcon(processes.get(programRuleKey(target))?.icon, shortName)
        : isDomain
          ? renderSiteIcon(r.payload, shortName, 'blue')
          : `<span class="sq md gray"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><circle cx="12" cy="12" r="9"/></svg></span>`;
      const editable = Boolean(conditions || r.instance);
      return `
        <div class="mac-row">
          <div class="mac-row-left">
            ${iconHtml}
            <div style="min-width:0">
              <span class="mac-row-title">${esc(shortName)}</span>
              <span class="mac-row-sub">${esc(kind)} · <span style="font-family:var(--font-mono)" title="${esc(target)}">${esc(target)}</span></span>
            </div>
          </div>
          <div class="rule-right-cols live-cols">
            <span class="pill ${r.active && !ended ? tone : 'orange'}">${esc(exitDisplayLabel(r.exit))}${r.active || ended ? '' : ' · 停用'}</span>
            <label class="mac-switch">
              <input type="checkbox" data-toggle-rule-idx="${r.index}" data-rule-expected="${esc(r.line)}" ${r.enabled ? 'checked' : ''}>
              <i></i>
            </label>
            <button type="button" class="sf-icon-btn" data-inspect-rule="${r.index}" aria-label="查看命中连接" data-tip="查看命中连接">${SF_DETAIL}</button>
            <button type="button" class="sf-icon-btn" data-edit-rule-idx="${r.index}" data-tip="${editable ? '编辑规则' : '编辑完整配置'}" ${ended ? 'disabled' : ''}>${SF_EDIT}</button>
            <button type="button" class="sf-icon-btn danger" data-del-rule-idx="${r.index}" data-rule-expected="${esc(r.line)}" data-tip="删除规则">${SF_TRASH}</button>
          </div>
        </div>
      `;
    }
    const openApps = new Set(Array.from($('splitRulesPane').querySelectorAll<HTMLDetailsElement>('details[open]'), el => el.dataset.app));
    $('splitRulesPane').innerHTML = `
      ${shared.map(r => `
        <div class="mac-card flush"><div class="mac-row"><div class="mac-row-left"><div>
        <span class="mac-row-title">${esc(r.conditions ? conditionLabel(r.conditions) : r.source)}</span>
        <span class="mac-row-sub">个人共享 · ${esc(r.line)}</span></div></div>
        <div class="rule-right-cols live-cols"><button class="sf-icon-btn" data-shared-inspect="${esc(r.line)}" aria-label="查看命中连接">${SF_DETAIL}</button>
        <button class="sf-icon-btn" data-shared-edit="${esc(r.source)}" aria-label="编辑共享规则">${SF_EDIT}</button>
        <button class="sf-icon-btn danger" data-shared-delete="${esc(r.source)}" aria-label="删除共享规则">${SF_TRASH}</button></div></div></div>`).join('')}
      <div class="mac-card flush">
        ${groups.map(group => {
          if (group.length === 1) return renderRule(group[0]);
          const app = appByPath.get(group[0].payload)!;
          const exits = new Set(group.map(r => exitDisplayLabel(r.exit)));
          return `<details class="rule-app-group" data-app="${esc(app.path)}" ${openApps.has(app.path) ? 'open' : ''}>
            <summary>${esc(app.name)} <small>${group.length} 条程序规则 · ${esc(exits.size === 1 ? [...exits][0] : '多个出口')}</small></summary>
            ${group.map(renderRule).join('')}</details>`;
        }).join('') || (shared.length ? '' : `<div class="rule-empty">${q ? '没有匹配的规则，试试应用名、域名或出口' : '暂无分流规则，点击右上角「+ 添加规则」创建'}</div>`)}
      </div>
    `;

  }

  function renderGroups(q: string): void {
    const groups = (liveProfile?.groups || []).filter(g => !q || [g.name, g.type, ...(g.proxies || []).map(exitDisplayLabel), ...(g.use || [])].join(' ').toLowerCase().includes(q));
    $('splitGroupsPane').innerHTML = groups.length
      ? `
        <div class="grid-2col">
          ${groups.map(g => {
            const live = liveCore?.proxies?.proxies?.[g.name];
            const members = (liveProfile?.rules || [])
              .map((line, index) => ({ line, index }))
              .filter(item => liveProfile?.ruleExits?.[item.index] === g.name && !item.line.startsWith('MATCH,'));
            const editable = ['select', 'url-test', 'fallback'].includes(g.type);
            const curExit = live?.now || g.proxies?.[0] || g.use?.[0] || '—';
            return `
              <div class="mac-card" style="display:flex;flex-direction:column;gap:12px;${g.enabled ? '' : 'opacity:0.58'}">
                <div style="display:flex;justify-content:space-between;align-items:center">
                  <div class="group-heading">
                    <span class="sq md blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg></span>
                    <div>
                      <strong class="card-title" title="${esc(g.name)}">${esc(g.name)}</strong>
                      <small style="color:var(--muted);font-size:var(--type-caption)">${members.length} 个目标 · ${esc(g.type)}${g.enabled ? '' : ' · 已停用'}</small>
                    </div>
                  </div>
                  <div style="display:flex;align-items:center;gap:6px">
                    <label class="mac-switch"><input type="checkbox" data-toggle-group="${esc(g.name)}" ${g.enabled ? 'checked' : ''}><i></i></label>
                    <button type="button" class="sf-icon-btn" data-edit-group="${esc(g.name)}" ${editable ? '' : 'disabled'} data-tip="编辑分组">${SF_EDIT}</button>
                    <button type="button" class="sf-icon-btn danger" data-del-group="${esc(g.name)}" data-tip="删除分组">${SF_TRASH}</button>
                  </div>
                </div>
                <div style="display:flex;align-items:center;justify-content:space-between;gap:10px">
                  ${live?.type === 'Selector' && live.all?.length
                    ? macPopupBtnHtml({ value: curExit, label: exitDisplayLabel(curExit), width: 162, popupKind: 'group-exit', popupKey: g.name })
                    : `<span class="pill blue">${esc(exitDisplayLabel(curExit))}</span>`}
                  ${liveStatus?.selectedTunAvailable && liveProfile?.tunScope === 'selected'
                    ? `<label class="mac-row-sub">TUN <span class="mac-switch"><input type="checkbox" data-group-tun="${esc(g.name)}" ${liveProfile.tunGroups.includes(g.name) ? 'checked' : ''}><i></i></span></label>` : ''}
                </div>
                <details style="border-top:0.5px solid var(--inset-divider);padding-top:9px;font-size:var(--type-label)">
                  <summary style="cursor:pointer;color:var(--accent);font-weight:var(--weight-control)">管理组成员 (${members.length})</summary>
                  <div style="margin-top:8px;display:grid;gap:6px">
                    ${members.map(({ line, index }) => {
                      const instance = liveProfile?.ruleInstances?.[index];
                      const target = instance?.path || line.split(',')[1];
                      const short = target.split(/[\\/]/).at(-1) || target;
                      return `
                        <div style="display:flex;justify-content:space-between;align-items:center;gap:8px">
                          <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(target)}">${esc(short)}${instance ? (endedInstances.has(line) ? ' · 本次运行已结束' : ` · PID ${instance.pid}`) : ''}</span>
                          <button type="button" class="glass-btn-soft" style="height:24px;padding:0 9px;flex:none" data-detach-rule-idx="${index}" data-rule-expected="${esc(line)}">移出</button>
                        </div>
                      `;
                    }).join('') || '<span style="color:var(--muted)">暂无成员</span>'}
                  </div>
                </details>
              </div>
            `;
          }).join('')}
        </div>
      `
      : `<div class="mac-card" style="padding:36px;text-align:center;color:var(--muted)">${q ? '没有匹配的策略分组' : '暂无策略分组，点击右上角「+ 创建分组」创建'}</div>`;

  }

  function renderProcesses(q: string): void {
    document.querySelectorAll<HTMLElement>('#procScanSeg button').forEach(b =>
      b.classList.toggle('active', b.dataset.scanType === procScanType)
    );
    const groupNamesSet = new Set((liveProfile?.groups || []).map(g => g.name));
    const canEditInstance = liveStatus?.platform === 'windows';
    const canEditTun = liveStatus?.selectedTunAvailable && liveProfile?.tunScope === 'selected';
    const pathRules = programPathExits();
    const matchQuery = (item: RunningProcess) =>
      !q || [item.name, item.exe, item.path, String(item.pid)].some(v => v.toLowerCase().includes(q));

    const rows = procScanType === 'app'
      ? liveApps.filter(app => matchQuery(app) || app.members.some(matchQuery))
      : liveProcesses.filter(matchQuery);

    $('splitProcsPane').innerHTML = `
      <div class="mac-card flush">
        ${rows.map(item => {
          const isApp = procScanType === 'app';
          const appItem = isApp ? (item as GroupedRunningApp) : null;
          const paths = appItem ? appItem.paths : [item.path];
          const assignedExits = new Set(paths.map(p => pathRules.get(programRuleKey(p)) || ''));
          const assigned = assignedExits.size === 1 ? [...assignedExits][0] : null;
          const groupTag = assigned && groupNamesSet.has(assigned) ? assigned : '未分组';
          const metric = appItem ? `${appItem.instances} 个进程` : `PID ${item.pid} · ${item.threadCount} 线程`;
          const instanceIndex = canEditInstance && !isApp ? findInstanceRule(item) : -1;
          const instanceExit = liveProfile?.ruleExits?.[instanceIndex] || '';
          return `
            <div class="mac-row">
              <div class="mac-row-left">
                ${renderProgramIcon(item.icon, item.name)}
                <div style="min-width:0">
                  <span class="mac-row-title" title="${esc(item.name)}">${esc(item.name)}</span>
                  <span class="mac-row-sub" style="font-family:var(--font-mono)" title="${esc(item.path)}">${esc(item.exe)} · ${esc(metric)}</span>
                </div>
              </div>
              <div class="process-actions">
                <span class="pill" title="${esc(groupTag)}">${esc(groupTag)}</span>
                ${macPopupBtnHtml({
                  value: assigned,
                  label: appExitLabel(paths, pathRules),
                  width: 132,
                  popupKind: isApp ? 'app-exit' : 'process-exit',
                  popupKey: item.path,
                })}
                ${canEditInstance && !isApp ? macPopupBtnHtml({
                  value: instanceExit,
                  label: instanceExit ? `本次 · ${exitDisplayLabel(instanceExit)}` : '本次运行',
                  popupKind: 'process-instance-exit',
                  popupKey: `${item.pid}:${item.startedAt}`,
                }) : ''}
                ${canEditTun && isApp ? macPopupBtnHtml({
                  value: programTunPreference(item.path),
                  label: `TUN ${TUN_PREFERENCES[programTunPreference(item.path)]}`,
                  popupKind: 'program-tun',
                  popupKey: item.path,
                }) : ''}
                <button type="button" class="sf-icon-btn" data-proc-detail-pid="${item.pid}" data-proc-detail-mode="${procScanType}" data-tip="${isApp ? '查看所属进程' : '查看线程详情'}">${SF_DETAIL}</button>
              </div>
            </div>
          `;
        }).join('') || `<div style="padding:36px;text-align:center;color:var(--muted)">没有匹配的运行程序</div>`}
      </div>
    `;
  }

  function inspectRoutes(line?: string): void {
    const names: Record<string,string> = { DOMAIN:'Domain','DOMAIN-SUFFIX':'DomainSuffix',
      'PROCESS-PATH':'ProcessPath', 'PROCESS-INSTANCE':'ProcessInstance',
      'IP-CIDR':'IPCIDR', 'IP-CIDR6':'IPCIDR', 'DST-PORT':'DstPort', AND:'AND', MATCH:'Match' };
    const signature = (rule: string): string => {
      const parts = rule.split(',');
      if (['no-resolve','src'].includes(parts.at(-1) || '')) parts.pop();
      parts.pop();
      const kind = parts.shift() || '';
      let payload = parts.join(',');
      if (kind === 'AND') {
        payload = payload.replace(/\),\(/g, ') && (').replace(/\(([A-Z-]+),/g, (_, k: string) => '(' + (names[k] || k) + ',');
      }
      return (names[kind] || kind) + '/' + payload;
    };
    const key = line ? signature(line) : null;
    const ambiguous = key && (liveProfile?.effectiveRules || []).filter(r => signature(r) === key).length !== 1;
    openSheet({ title: line ? '查看命中连接' : '活动连接', size:'wide',
      bodyHtml: `${line ? '<p class="mac-row-sub">' + esc(line) + '</p>' : ''}<div class="sheet-picker" id="activeRouteRows" aria-live="polite"></div>`,
      actionsHtml:'<button class="glass-btn-soft" id="routesRefresh">刷新</button><button class="glass-btn-primary" id="routesClose">完成</button>' });
    const list = $('activeRouteRows');
    const refresh = $<HTMLButtonElement>('routesRefresh');
    let shown: ActiveRoute[] = [];
    const load = async () => {
      refresh.disabled = true; list.textContent = '正在读取活动连接…';
      try {
        const rows = await tauriApi.activeRoutes();
        if (!list.isConnected) return;
        shown = key ? rows.filter(row => row.rule + '/' + row.payload === key) : rows;
        list.innerHTML = shown.map((r,i) => {
          const destination = r.host || r.ip || '未知目标';
          const details = [r.program || r.process || '未识别进程', r.host ? '域名 ' + r.host : '未识别域名', r.ip && '目标 IP ' + r.ip,
            r.inbound, r.network, r.rule + ' ' + r.payload, ambiguous && '同条件规则无法唯一归属',
            r.chains?.length && '实际出口 ' + r.chains.slice().reverse().join(' → ')].filter(Boolean).map(esc).join(' · ');
          return `<div class="sheet-picker-row"><div class="picker-meta"><strong>${esc(destination)} · ${esc(String(r.port))}</strong><small>${details}</small></div>
            <button class="glass-btn-soft" data-create-route="${i}">据此建规则</button></div>`;
        }).join('') || '当前没有符合条件的活动连接。可在目标软件中新建连接后刷新。';
      } catch(e) { if (list.isConnected) list.textContent = cleanError(e); }
      finally { refresh.disabled = false; }
    };
    list.onclick = e => {
      const btn = (e.target as HTMLElement).closest<HTMLElement>('[data-create-route]');
      if (!btn) return;
      const row = shown[Number(btn.dataset.createRoute)];
      openRuleEditor(undefined, {program:row.program, target:row.host || row.ip, port:String(row.port || '')});
    };
    refresh.onclick = () => void load();
    $('routesClose').onclick = closeSheet;
    void load();
  }

  function renderLogs(): void {
    $<HTMLButtonElement>('clearLogsBtn').disabled = !liveLogs.length;
    const q = shell.getSearch().trim().toLowerCase();
    const rows = liveLogs.map((row, i) => ({ row, i })).filter(({ row }) =>
      !q || [row.app, row.target, row.decision, row.protocol, row.exit, row.time].join(' ').toLowerCase().includes(q));
    $('logsListCard').innerHTML = rows.length
      ? rows.map(({ row, i }) => {
          const tone = row.failed ? 'red' : row.exit === 'DIRECT' ? 'green' : row.exit === 'REJECT' ? 'red' : 'blue';
          return `
            <div class="mac-row">
              <div class="mac-row-left">
                <span style="font-family:var(--font-mono);font-size:var(--type-caption);color:var(--muted);width:66px;flex:none">${esc(row.time.slice(-8))}</span>
                <div style="min-width:0">
                  <span class="mac-row-title">${esc(row.app || '未识别进程')} <span style="color:var(--muted);font-weight:400">→</span> <span style="font-family:var(--font-mono)">${esc(row.target)}</span></span>
                  <span class="mac-row-sub">${esc(row.decision || '—')}</span>
                </div>
              </div>
              <div style="display:flex;gap:7px;flex:none">
                <span class="pill">${esc(row.protocol)}</span>
                <span class="pill ${tone}">${esc(row.exit)}</span><button class="section-link" data-log-rule="${i}">据此建规则</button>
              </div>
            </div>
          `;
        }).join('')
      : `<div style="padding:36px;text-align:center;color:var(--muted)">${q ? '没有匹配的连接记录' : liveStatus?.running ? '暂无连接记录，可直接在上方输入域名实测连通' : '代理服务未启动，启动后将实时记录连接'}</div>`;
  }

  function editDocument(mode: DocumentMode, name = ''): void {
    const previous = new Set(liveProfile?.providers.map(p => p.name));
    void openProfileEditor(mode, name, async () => {
      await reloadProfile();
      for (const provider of liveProfile?.providers || []) {
        if (mode === 'config' || provider.name === name || !previous.has(provider.name)) {
          subscriptionNodes.delete(provider.name);
          await loadSubscriptionMeta(provider.name, true);
        }
      }
      await refreshLiveState(true);
      renderAllSafe();
    });
  }

  async function refreshSubscriptions(single?: string): Promise<void> {
    if (providerRefresh || changingSubscription || networkUpdating) return;
    const names = single ? [single] : (liveProfile?.providers || []).filter(p => p.type === 'http').map(p => p.name);
    if (!names.length) return;
    const progress = { total: names.length, done: 0, batch: !single };
    providerRefresh = progress;
    for (const name of names) refreshResults.set(name, { message: '等待刷新' });
    renderView();
    let failed = 0;
    try {
      if (!await ensureLocalCore()) throw new Error('没有可刷新的代理配置');
      for (const name of names) {
        refreshResults.set(name, { message: '正在刷新…' });
        renderView();
        try {
          await tauriApi.mihomoRefreshProvider(name);
          const detail = await loadSubscriptionMeta(name, true);
          refreshResults.set(name, { message: detail ? `节点已更新，订阅信息读取失败：${detail}` : '已刷新', failed: !!detail });
          if (detail) failed++;
        } catch (err) {
          refreshResults.set(name, { message: cleanError(err), failed: true });
          failed++;
        }
        progress.done++;
      }
      await refreshLiveState(true);
      if (single) notify(refreshResults.get(single)?.message || '已刷新', failed > 0);
      else notify(failed ? `已处理 ${names.length} 个订阅，${failed} 个有异常` : `已刷新 ${names.length} 个订阅`, failed > 0);
    } catch (err) {
      const message = cleanError(err);
      for (const name of names.slice(progress.done)) refreshResults.set(name, { message, failed: true });
      notify(message, true);
    } finally {
      providerRefresh = null;
      renderView();
    }
  }

  function renderSubs(): void {
    $('newYamlBtn').hidden = false;
    $('editConfigBtn').hidden = !liveStatus?.configured;
    const providers = liveProfile?.providers || [];
    const refreshAll = $<HTMLButtonElement>('refreshAllSubsBtn');
    refreshAll.hidden = !providers.some(p => p.type === 'http');
    refreshAll.disabled = !!providerRefresh || changingSubscription || networkUpdating;
    refreshAll.textContent = providerRefresh?.batch ? `刷新中 ${providerRefresh.done}/${providerRefresh.total}` : '全部刷新';
    const q = shell.getSearch().trim().toLowerCase();
    const matches = providers.filter(p => [p.name, p.source, p.type === 'file' ? '本地文件' : '远程订阅'].join(' ').toLowerCase().includes(q));
    const cards = matches.length
      ? matches.map(saved => {
          const selected = selectedSubscription === saved.name;
          const remote = saved.type === 'http';
          const meta = subscriptionCardData.get(saved.name);
          const usage = meta?.usage;
          const used = (usage?.Upload || 0) + (usage?.Download || 0);
          const hasQuota = Boolean(remote && usage?.Total && usage.Total > 0);
          const pct = hasQuota ? Math.min(100, Math.round((used / usage!.Total!) * 100)) : 0;
          const nodeCount = (liveCore?.providers?.providers?.[saved.name]?.proxies ?? subscriptionNodes.get(saved.name) ?? []).filter(isTestableNode).length;
          const expiry = remote && usage?.Expire ? new Date(usage.Expire * 1000).toLocaleDateString() : (remote ? '—' : '本地文件');
          const updated = meta?.updatedAt ? new Date(meta.updatedAt).toLocaleDateString() : '待刷新';
          const result = refreshResults.get(saved.name);
          return `
            <div class="mac-card sub-card-clickable ${selected ? 'active-sub' : ''}" data-select-sub="${esc(saved.name)}" style="display:flex;flex-direction:column;gap:12px">
              <div style="display:flex;justify-content:space-between;align-items:center">
                <div style="display:flex;align-items:center;gap:10px;min-width:0">
                  <span class="sq md ${selected ? 'blue' : 'orange'}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/></svg></span>
                  <div style="min-width:0">
                    <strong class="card-title" style="display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(saved.name)}</strong>
                    <small style="color:var(--muted);font-size:var(--type-caption)">${remote ? '远程订阅' : '本地订阅文件'} · ${nodeCount} 个节点${selected ? ' · 当前生效' : ''}</small>
                  </div>
                </div>
                <div style="display:flex;align-items:center;gap:4px;flex:none">
                  ${remote || saved.type === 'file' ? `<button type="button" class="sf-icon-btn" data-edit-sub="${esc(saved.name)}" aria-label="编辑订阅" data-tip="编辑订阅">${SF_EDIT}</button>` : ''}
                  <button type="button" class="glass-btn-soft" data-ref-sub="${esc(saved.name)}" ${providerRefresh || changingSubscription || networkUpdating ? 'disabled' : ''}>刷新</button>
                  <button type="button" class="sf-icon-btn danger" data-del-sub="${esc(saved.name)}" data-tip="移除订阅">${SF_TRASH}</button>
                </div>
              </div>
              <div style="display:flex;justify-content:space-between;font-family:var(--font-mono);font-size:var(--type-caption);color:var(--muted)">
                <span>${esc(saved.source || (remote ? '远程来源' : '本地存储'))}</span>
                <span>更新 ${esc(updated)}</span>
              </div>
              ${saved.ruleExitDisabled ? `<button type="button" class="glass-btn-soft" data-restore-sub-exit="${esc(saved.name)}">恢复规则出口</button>` : ''}
              ${pendingSubscription === saved.name ? `<span style="font-size:var(--type-label);color:var(--accent)">正在切换订阅配置…</span>` : ''}
              ${result ? `<span class="sub-refresh-result${result.failed ? ' failed' : ''}">${esc(result.message)}</span>` : ''}
              ${hasQuota ? `
                <div>
                  <div style="display:flex;justify-content:space-between;font-size:var(--type-caption);color:var(--muted);margin-bottom:5px;font-family:var(--font-mono)">
                    <span>已用 ${esc(formatBytes(used))} / ${esc(formatBytes(usage!.Total!))} (${pct}%)</span>
                    <span>到期 ${esc(expiry)}</span>
                  </div>
                  <div class="mac-progress"><span style="width:${pct}%"></span></div>
                </div>
              ` : ''}
            </div>
          `;
        }).join('')
      : `<div class="mac-card" style="grid-column:1/-1;padding:32px;text-align:center;color:var(--muted)">${q ? '没有匹配的订阅' : '还没有订阅。导入后可以在这里切换订阅、刷新节点和查看用量。'}</div>`;
    if (cards !== subscriptionCardsHtml) {
      $('subsGridPane').innerHTML = cards;
      subscriptionCardsHtml = cards;
    }

    const statics = standaloneNodes().filter(node => [node.name, node.type].join(' ').toLowerCase().includes(q));
    const sec = $('standaloneNodesSection');
    if (statics.length) {
      sec.hidden = false;
      $('standaloneNodesCount').textContent = `共 ${statics.length} 个独立节点`;
      $('standaloneNodesList').innerHTML = statics.map(n => `
        <div class="mac-row">
          <div class="mac-row-left">
            <span class="flag-box">${flagSvg(n.name)}</span>
            <div style="min-width:0">
              <span class="mac-row-title">${esc(n.name)}</span>
              <span class="mac-row-sub">${esc(n.type)} · 直接导入</span>
            </div>
          </div>
          <div style="display:flex;align-items:center;gap:6px">
            <button type="button" class="sf-icon-btn danger" data-remove-node="${esc(n.name)}" data-tip="删除节点">${SF_TRASH}</button>
          </div>
        </div>
      `).join('');
    } else {
      sec.hidden = true;
    }
  }

  const coreFields = $<HTMLFieldSetElement>('coreSettingsFields');
  const providerPeriod = $<HTMLSelectElement>('providerPeriod');
  const probeTarget = $<HTMLSelectElement>('probeTarget');
  const probeTimeout = $<HTMLSelectElement>('probeTimeout');
  const probeWorkers = $<HTMLSelectElement>('probeWorkers');
  $('desktopNetworkSettings').hidden = false;
  for (const control of [probeTarget, probeTimeout, probeWorkers]) {
    const key = `xeylroute-${control.id}`;
    const saved = localStorage.getItem(key);
    if (Array.from(control.options).some(option => option.value === saved)) control.value = saved!;
    control.addEventListener('change', () => localStorage.setItem(key, control.value));
  }

  $('showCoreLog').addEventListener('click', () => {
    openSheet({
      title: '内核日志', subtitle: '最近 200 行，最多 64 KB', size: 'wide',
      bodyHtml: '<pre id="coreLogText" class="core-log-text selectable" tabindex="0"></pre>',
      actionsHtml: '<button type="button" class="glass-btn-soft" id="refreshCoreLog">刷新</button><button type="button" class="glass-btn-primary compact" id="closeCoreLog">完成</button>',
    });
    const log = $('coreLogText');
    const refresh = $<HTMLButtonElement>('refreshCoreLog');
    const read = async () => {
      refresh.disabled = true;
      try {
        log.textContent = (await tauriApi.coreLogTail()) || '暂无内核日志';
        log.scrollTop = log.scrollHeight;
      } catch (err) {
        log.textContent = cleanError(err);
      } finally {
        refresh.disabled = false;
      }
    };
    refresh.onclick = read;
    $('closeCoreLog').onclick = closeSheet;
    void read();
  });

  let savingCoreSetting = false;
  coreFields.addEventListener('change', async event => {
    const control = event.target;
    if (!(control instanceof HTMLInputElement || control instanceof HTMLSelectElement) || !liveProfile) return;
    const key = control.dataset.coreOption as keyof CoreSettings | undefined;
    const edit: ProfileEdit = key
      ? { kind: 'coreSetting', key, value: control instanceof HTMLInputElement ? control.checked : control.value }
      : { kind: 'providerInterval', name: selectedSubscription, seconds: Number(providerPeriod.value) };
    savingCoreSetting = true;
    coreFields.disabled = true;
    try {
      if (profileBusy) notify('正在保存其他配置，请稍后重试', true);
      else await commitProfileEdit(edit, '设置已保存');
    } finally {
      savingCoreSetting = false;
      renderSettings();
    }
  });

  const fallbackSwitch = $<HTMLInputElement>('setFallbackToggle');
  let savingFallback = false;
  fallbackSwitch.addEventListener('change', async () => {
    savingFallback = true;
    const value = fallbackSwitch.checked;
    renderSettings();
    try {
      await commitProfileEdit({ kind: 'coreSetting', key: 'routepilot-fallback-direct', value }, '故障回退设置已保存');
    } finally {
      savingFallback = false;
      renderSettings();
    }
  });

  function renderSettings(): void {
    const settings = liveProfile?.coreSettings;
    $('setFallbackRow').hidden = liveStatus?.platform !== 'windows';
    fallbackSwitch.disabled = !settings || savingFallback || changingSubscription || networkUpdating;
    if (!savingFallback) fallbackSwitch.checked = settings?.['routepilot-fallback-direct'] ?? false;
    coreFields.disabled = savingCoreSetting || !settings || changingSubscription || networkUpdating || batchTesting;
    if (!savingCoreSetting && settings) {
      $<HTMLInputElement>('coreIpv6').checked = settings.ipv6;
      $<HTMLInputElement>('coreConcurrent').checked = settings['tcp-concurrent'];
      $<HTMLInputElement>('coreUnified').checked = settings['unified-delay'];
      $<HTMLSelectElement>('coreLogLevel').value = settings['log-level'];
      const provider = liveProfile?.providers.find(p => p.name === selectedSubscription && p.type === 'http');
      $('providerPeriodRow').hidden = !provider;
      if (provider) {
        const seconds = String(provider.interval ?? 0);
        const previous = providerPeriod.querySelector('option[data-imported]');
        if (previous && previous.getAttribute('value') !== seconds) previous.remove();
        if (!Array.from(providerPeriod.options).some(o => o.value === seconds)) {
          const option = new Option(`${seconds} 秒`, seconds);
          option.dataset.imported = '';
          providerPeriod.add(option);
        }
        providerPeriod.value = seconds;
        $('providerPeriodHint').textContent = `内核运行时自动更新 · ${provider.name}`;
      }
    }
    $<HTMLFieldSetElement>('probeSettingsFields').disabled = batchTesting || liveTesting.size > 0;
    const scope = liveProfile?.tunScope || liveStatus?.tunScope || 'all';
    const scopeHost = $('setTunScopeHost');
    const canSelect = Boolean(liveStatus?.selectedTunAvailable);
    const scopeKey = `${scope}:${canSelect}`;
    if (scopeHost.dataset.scope !== scopeKey) {
      scopeHost.dataset.scope = scopeKey;
      scopeHost.innerHTML = canSelect
        ? macPopupBtnHtml({ value: scope, label: scope === 'selected' ? '仅指定分组和程序' : '全部受支持流量',
          popupKind: 'tun-scope' })
        : scope === 'selected'
        ? '<button type="button" class="glass-btn-soft" data-popup-kind="tun-scope">改用全局范围</button>'
        : '<span class="scope-value">全部受支持流量</span>';
    }
    $('tunScopeHelp').textContent = scope === 'selected' && canSelect
      ? '规则模式下接管所选软件的 TCP 和 UDP。可在「分流与程序」设置。'
      : '全局 TUN 接管系统流量，可用程序规则指定出口。';
    $('tunWorkHelp').textContent = scope === 'selected' && canSelect
      ? '签名驱动按可执行文件路径接管，系统默认路由保持原设置。'
      : '开启后自动设置路由、选择出口接口，并接管进入网卡的 53 端口 DNS 请求。';
    $('tunStackLabel').textContent = scope === 'selected' && canSelect ? 'gVisor 协议栈' : 'Mixed 协议栈';

    const isRunning = Boolean(liveStatus?.running);
    const mixIn = $<HTMLInputElement>('portMixedInput');
    const httpIn = $<HTMLInputElement>('portHttpInput');
    const socksIn = $<HTMLInputElement>('portSocksInput');
    const portsFocused = [mixIn, httpIn, socksIn].includes(document.activeElement as HTMLInputElement);
    const configuredPorts = liveProfile && [liveProfile.mixed, liveProfile.http, liveProfile.socks].join(',');
    if (!portsFocused && liveProfile && mixIn.dataset.configured !== configuredPorts) {
      mixIn.dataset.configured = configuredPorts!;
      mixIn.value = String(liveProfile.mixed ?? 0);
      httpIn.value = String(liveProfile.http ?? 0);
      socksIn.value = String(liveProfile.socks ?? 0);
    }
    const portsBusy = savingPorts || networkUpdating || changingSubscription || profileBusy;
    mixIn.disabled = httpIn.disabled = socksIn.disabled = portsBusy;
    $<HTMLButtonElement>('savePortsBtn').disabled = portsBusy;
    $('portHintSub').textContent = isRunning
      ? '保存后立即生效并同步系统代理 · 端口切换可能影响当前连接'
      : '绑定 127.0.0.1 · 设为 0 表示关闭该端口，保存前自动校验冲突';

    const localIps = networkDetails?.error ? '读取失败' : (networkDetails?.addresses?.slice(0, 3).join(', ') || '—');
    const sysDns = networkDetails?.error ? '读取失败' : (networkDetails?.dns?.slice(0, 3).join(', ') || '—');
    $('setExitIpSub').textContent = `出口 ${exitIp || '未检测'} · 本机 ${localIps}`;
    $('systemDnsDetails').textContent = `系统 DNS · ${sysDns}`;
    const dnsMode = liveStatus?.dnsMode;
    const modeLabel = dnsMode === 'off' ? '关闭' : dnsMode === 'enabled' ? '开启' : dnsMode || '未知';
    $('coreDnsDetails').textContent = liveStatus?.running
      ? `内核 DNS · ${modeLabel}${liveStatus.tunDnsHijack ? ' · TUN 接管 DNS' : ''}`
      : '内核未运行';
    $<HTMLButtonElement>('probeIpBtn').disabled = !liveCore;

    if (liveStatus) {
      $('setCoreTitle').textContent = liveStatus.available
        ? `Mihomo 内核已就绪 (${platformLabel(liveStatus.platform)})`
        : `未安装 Mihomo 内核 (${platformLabel(liveStatus.platform)})`;
      $('setCoreSub').textContent = liveStatus.running
        ? '停止内核会关闭本地监听、系统代理和虚拟网卡。'
        : '开启系统代理或虚拟网卡会自动启动内核。也可在此单独启动本地监听。';
      $('setCoreSub').title = liveStatus.appData;
    }
    const q = shell.getSearch().trim().toLowerCase();
    const page = $('view-settings');
    const cards = page.querySelectorAll<HTMLElement>('.mac-card');
    let any = false;
    for (const card of cards) {
      card.classList.remove('search-miss');
      const heading = card.previousElementSibling?.matches('.section-label') ? card.previousElementSibling : null;
      const rows = [...card.querySelectorAll<HTMLElement>('.mac-row')];
      for (const row of rows) {
        const matches = !q || [heading?.textContent, row.textContent].join(' ').toLowerCase().includes(q);
        row.classList.toggle('search-miss', !matches);
      }
      const visible = !q || rows.some(row => row.getClientRects().length);
      card.classList.toggle('search-miss', !visible);
      heading?.classList.toggle('search-miss', !visible);
      any ||= visible;
    }
    $('settingsSearchEmpty').hidden = !q || any;
  }

  function renderView(): void {
    const view = shell.getView();
    if (view === 'connect') renderConnect();
    else if (view === 'nodes') renderNodes();
    else if (view === 'split') renderSplit();
    else if (view === 'logs') renderLogs();
    else if (view === 'subs') renderSubs();
    else if (view === 'settings') renderSettings();
  }

  function renderAllSafe(): void {
    renderHeaderState();
    if ($('macMenuPopover').classList.contains('open') || isSheetOpen()) return;
    renderView();
  }

  /* =========================================================================
     Modals & Sheets (Import, Rules, Groups, Process Inspector, App Picker)
     ========================================================================= */
  async function handleTextImport(raw: string): Promise<boolean> {
    const trimmed = raw.trim();
    if (!trimmed) return false;
    try {
      let profile: ProfileSummary;
      if (looksLikeShareLinks(trimmed)) {
        profile = await tauriApi.importNodeLinks(trimmed);
        notify('节点链接已导入并写入配置');
      } else {
        profile = await tauriApi.importSubscriptionLink(trimmed);
        notify('订阅链接已保存');
      }
      applyProfile(profile);
      await reloadProfile();
      await refreshLiveState(true);
      return true;
    } catch (err) {
      notify(cleanError(err), true);
      return false;
    }
  }

  async function handleFileImport(file: File): Promise<void> {
    if (file.size > 4 * 1024 * 1024) {
      notify('配置文件不得超过 4 MiB', true);
      return;
    }
    try {
      const content = await file.text();
      if (looksLikeFullConfig(file.name, content)) {
        openSheet({
          title: '检测到完整 Mihomo 配置',
          subtitle: file.name,
          iconHtml: `<span class="sq md orange"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><polygon points="12 3 3 8 12 13 21 8 12 3"/><polyline points="3 12.5 12 17.5 21 12.5"/></svg></span>`,
          bodyHtml: `
            <p class="sheet-hint" style="margin:0;color:var(--ink-2);font-size:var(--type-body);line-height:1.6">
              该文件包含规则或代理组定义。选择「替换完整配置」时会自动剥离外部控制口、锁定 127.0.0.1 并保留有效 DNS 配置；也可仅将其作为本地订阅导入。
            </p>
          `,
          actionsSplit: true,
          actionsHtml: `
            <button type="button" class="glass-btn-soft" id="fileImportCancel">取消</button>
            <div class="sheet-actions-group">
              <button type="button" class="glass-btn-soft" id="fileImportAsSub">作为本地订阅</button>
              <button type="button" class="glass-btn-primary compact" id="fileImportAsFull">替换完整配置</button>
            </div>
          `,
        });
        $('fileImportCancel').onclick = closeSheet;
        $('fileImportAsSub').onclick = async () => {
          closeSheet();
          try {
            const profile = await tauriApi.importSubscriptionFile(file.name, content);
            applyProfile(profile);
            notify(`本地订阅「${file.name}」已添加`);
            await reloadProfile();
            await refreshLiveState(true);
          } catch (err) {
            notify(cleanError(err), true);
          }
        };
        $('fileImportAsFull').onclick = async () => {
          closeSheet();
          try {
            const st = await tauriApi.coreStatus();
            if (st.running) {
              notify('请先断开代理连接，再替换完整配置。', true);
              return;
            }
            await tauriApi.importCoreConfig(content);
            notify('完整配置已导入并完成本地安全校验');
            await reloadProfile();
            await refreshLiveState(true);
          } catch (err) {
            notify(cleanError(err), true);
          }
        };
        return;
      }

      if (looksLikeShareLinks(content)) {
        const profile = await tauriApi.importNodeLinks(content);
        applyProfile(profile);
        notify(`已从 ${file.name} 导入节点链接`);
      } else {
        const profile = await tauriApi.importSubscriptionFile(file.name, content);
        applyProfile(profile);
        notify(`本地订阅「${file.name}」已添加`);
      }
      await reloadProfile();
      await refreshLiveState(true);
    } catch (err) {
      notify(cleanError(err), true);
    }
  }

  function openImportSheet(): void {
    openSheet({
      title: '导入订阅或节点',
      bodyHtml: `
        <div class="sheet-field">
          <label for="sheetImportVal">订阅地址或节点列表</label>
          <textarea class="sheet-textarea" id="sheetImportVal" placeholder="粘贴 HTTPS 订阅地址、Base64 内容，或每行一个节点链接"></textarea>
        </div>
      `,
      actionsSplit: true,
      actionsHtml: `
        <div class="sheet-actions-group"><button type="button" class="glass-btn-soft" id="sheetImportFileBtn">从文件导入…</button>
        <button type="button" class="glass-btn-soft" id="sheetNewYaml">新建 YAML…</button></div>
        <div class="sheet-actions-group">
          <button type="button" class="glass-btn-soft" id="sheetCancel">取消</button>
          <button type="button" class="glass-btn-primary compact" id="sheetConfirmImport">导入</button>
        </div>
      `,
    });
    $('sheetCancel').onclick = closeSheet;
    $('sheetNewYaml').onclick = () => editDocument('new');
    $('sheetImportFileBtn').onclick = () => {
      closeSheet();
      $('subFileInput').click();
    };
    const input = $<HTMLTextAreaElement>('sheetImportVal');
    const submit = $<HTMLButtonElement>('sheetConfirmImport');
    submit.disabled = true;
    input.oninput = () => { submit.disabled = !input.value.trim(); };
    submit.onclick = async () => {
      input.readOnly = true;
      submit.disabled = true;
      submit.textContent = '导入中…';
      const ok = await handleTextImport(input.value.trim());
      if (!submit.isConnected || !isSheetOpen()) return;
      input.readOnly = false;
      submit.disabled = !input.value.trim();
      submit.textContent = '导入';
      if (ok) { closeSheet(); renderAllSafe(); }
    };
    input.focus();
  }

  async function loadEditorNodes(scope: string): Promise<void> {
    if (!scope || activeSubscriptionNodes().length) return;
    await readOfflineNodes(scope);
    if (selectedSubscription === scope && !activeSubscriptionNodes().length &&
        liveProfile?.providers.some(p => p.name === scope && p.type === 'http')) {
      await loadSubscriptionMeta(scope, true);
    }
  }

  function editorNodePins(): Map<string, string> {
    const pins = new Map(Object.entries(liveProfile?.nodePins || {}));
    const savedNodes = new Set(pins.values());
    const used = new Set(liveProfile?.exits);
    for (const node of activeSubscriptionNodes()) {
      if (savedNodes.has(node.name)) continue;
      const base = '节点 · ' + node.name.trim().replaceAll('%', '%25').replaceAll(',', '%2C');
      let alias = base;
      for (let n = 2; used.has(alias); n++) alias = base + ' (' + n + ')';
      pins.set(alias, node.name);
      used.add(alias);
      savedNodes.add(node.name);
    }
    return pins;
  }

  function openRuleEditor(index?: number, seed?: Partial<RuleConditions>, shared?: SharedRule): void {
    const profile = liveProfile;
    if (!profile) return;
    const original = index === undefined ? undefined : profile.rules?.[index];
    const existing = index === undefined ? shared?.conditions || seed : profile.ruleConditions?.[index];
    if (original && !existing) { editDocument('config'); return; }
    const scope = profile.subscriptionScope ?? '';
    const initial = { program: '', target: '', port: '', suffix: false, ...existing };
    type RuleTab = 'website' | 'app' | 'ip' | 'compound';
    const isIp = (v: string) => /^[\d.]+(?:\/\d+)?$/.test(v) || (!v.includes('://') && v.includes(':'));
    let tab: RuleTab = initial.port || (initial.program && initial.target) ? 'compound'
      : initial.program ? 'app' : isIp(initial.target) ? 'ip' : 'website';
    const targetDraft = { website: '', ip: '', compound: initial.target, app: '' };
    targetDraft[tab] = initial.target;
    let exit = index === undefined ? shared?.exit || 'DIRECT' : profile.ruleExits?.[index] || 'DIRECT';
    openSheet({
      title: original || shared ? '编辑分流规则' : '添加分流规则',
      size: 'wide',
      bodyHtml: `
        <div class="sheet-field"><span class="sheet-field-label">匹配类型</span>
          <div class="sub-seg full" id="ruleTabs" role="group" aria-label="匹配类型">
            <button type="button" data-kind="website">网站</button><button type="button" data-kind="app">软件</button>
            <button type="button" data-kind="ip">IP / 网段</button><button type="button" data-kind="compound">组合条件</button>
          </div></div>
        <div class="sheet-field" id="programFields"><label for="ruleProgram">软件</label>
          <div class="rule-input-row"><input id="ruleProgram" class="sheet-input" placeholder="任意软件" value="${esc(initial.program)}" autocomplete="off" spellcheck="false">
          <button class="glass-btn-soft" id="ruleBrowse" type="button">浏览…</button></div>
          <details id="rulePrograms" class="rule-programs"><summary>从运行中的软件选择
            <small id="ruleAppCount"></small><span class="rule-disclosure" aria-hidden="true">›</span></summary>
            <input class="sheet-input" id="ruleAppSearch" type="search" aria-label="搜索软件或路径" placeholder="搜索软件名称或路径">
            <div class="rule-program-list" id="ruleAppList"></div>
            <p id="ruleAppEmpty" class="sheet-hint" hidden></p>
          </details>
        </div>
        <div class="sheet-field" id="targetFields"><label for="ruleTarget" id="ruleTargetLabel">目标网站或 IP</label>
          <input class="sheet-input" id="ruleTarget" placeholder="任意目标，支持域名、网址、IP 或网段" value="${esc(initial.target)}">
          <label id="suffixField"><input type="checkbox" id="ruleSuffix" ${initial.suffix ? 'checked' : ''}> 包含子域名</label>
          <small id="ruleHostPreview"></small></div>
        <div class="sheet-field" id="portFields"><label for="rulePort">目标端口</label>
          <input class="sheet-input" id="rulePort" placeholder="任意端口，例如 443 或 8000-8080" value="${esc(initial.port)}"></div>
        <div class="rule-exit-fields">
        ${scope && !original && !shared ? '<div class="sheet-field"><label for="ruleCoverage">应用范围</label><select class="sheet-input" id="ruleCoverage"><option value="local">仅当前订阅</option><option value="shared">所有订阅</option></select></div>' : ''}
        <div class="sheet-field"><span class="sheet-field-label">匹配时使用</span><div class="sheet-popup-full" id="ruleExit"></div></div>
        </div>
        <p class="sheet-error" id="ruleError" role="alert"></p>`,
      actionsHtml: '<button class="glass-btn-soft" id="ruleCancel">取消</button><button class="glass-btn-primary" id="ruleSave">保存规则</button>',
    });
    const program = $<HTMLInputElement>('ruleProgram');
    const target = $<HTMLInputElement>('ruleTarget');
    const suffix = $<HTMLInputElement>('ruleSuffix');
    const picker = bindRuleProgramPicker(program, index === undefined && !shared);
    const { selectedPaths } = picker;
    const error = $('ruleError');
    const fillPrograms = () => picker.refresh(liveApps, processStatus);
    fillPrograms();
    if (!liveProcesses.length) void refreshProcesses(false).then(fillPrograms);
    $('ruleBrowse').onclick = async () => {
      try {
        const path = await tauriApi.chooseProgramPath();
        if (path && program.isConnected) { program.value = path; picker.syncSelection(); }
      }
      catch (e) { error.textContent = cleanError(e); }
    };
    const describe = () => {
      let host = target.value.trim();
      let url = false;
      if (/^https?:\/\//i.test(host)) {
        try { host = new URL(host).hostname; url = true; } catch { host = ''; }
      }
      suffix.disabled = !host || host.includes(':') || host.includes('/') || /^[0-9.]+$/.test(host);
      $('ruleHostPreview').textContent = url ? `匹配 ${host}${suffix.checked && !suffix.disabled ? ' 及其子域名' : ''} 的所有路径，端口以端口栏为准` : '';
    };
    function renderTab(): void {
      $('programFields').hidden = tab !== 'app' && tab !== 'compound';
      program.placeholder = tab === 'app' ? '输入或浏览可执行文件路径' : '可选，输入可执行文件路径';
      $<HTMLDetailsElement>('rulePrograms').open = tab === 'app';
      $('targetFields').hidden = tab === 'app';
      $('portFields').hidden = tab !== 'compound';
      $('suffixField').hidden = tab === 'ip';
      $('ruleTargetLabel').textContent = tab === 'website' ? '域名或网址' : tab === 'ip' ? 'IP 地址或网段' : '目标网站或 IP';
      target.placeholder = tab === 'website' ? '例如 github.com 或 *.github.com' : tab === 'ip' ? '例如 192.0.2.1 或 2001:db8::/32' : '任意目标';
      $('ruleTabs').querySelectorAll<HTMLButtonElement>('button').forEach(b => {
        b.classList.toggle('active', b.dataset.kind === tab);
        b.setAttribute('aria-pressed', String(b.dataset.kind === tab));
      });
      describe();
    }
    $('ruleTabs').onclick = e => {
      const next = (e.target as HTMLElement).closest('button')?.dataset.kind as RuleTab | undefined;
      if (!next || next === tab) return;
      targetDraft[tab] = target.value;
      tab = next;
      target.value = targetDraft[tab];
      error.textContent = '';
      renderTab();
    };
    target.oninput = describe; suffix.onchange = describe; renderTab();
    const loadingNodes = loadEditorNodes(scope);
    let pins = editorNodePins();
    const renderExit = () => {
      $('ruleExit').innerHTML = macPopupBtnHtml({ id: 'ruleExitButton', value: exit, label: pins.get(exit) || exitDisplayLabel(exit), popupKind: 'sheet-custom' });
      $('ruleExitButton').onclick = async e => {
        e.stopPropagation();
        const trigger = e.currentTarget as HTMLButtonElement;
        trigger.disabled = true;
        try { await loadingNodes; }
        finally { trigger.disabled = false; }
        if (!trigger.isConnected || !isSheetOpen()) return;
        pins = editorNodePins();
        openMacMenu($('ruleExitButton'), buildExitPopupItems(pins), exit, value => { exit = value; renderExit(); });
      };
    };
    renderExit();
    $('ruleCancel').onclick = closeSheet;
    const save = $<HTMLButtonElement>('ruleSave');
    save.onclick = async () => {
      if (save.disabled) return;
      save.disabled = true;
      try {
        const withProgram = tab === 'app' || tab === 'compound';
        const paths = withProgram ? [...selectedPaths] : [];
        const raw = tab === 'app' ? '' : target.value.trim();
        const wildcard = raw.startsWith('*.');
        const host = wildcard ? raw.slice(2) : raw;
        let hostname = host;
        if (/^https?:\/\//i.test(host)) hostname = new URL(host).hostname;
        if (tab === 'website' && (!host || isIp(hostname))) throw new Error('请输入域名或网址');
        if (tab === 'ip' && (!isIp(raw) || wildcard)) throw new Error('请输入 IPv4、IPv6 地址或网段');
        if (tab === 'app' && !program.value.trim() && !paths.length) throw new Error('请选择软件或输入可执行文件路径');
        const conditions = { program: withProgram ? program.value.trim() : '', target: host,
          suffix: tab !== 'ip' && (wildcard || (!suffix.disabled && suffix.checked)), port: tab === 'compound' ? $<HTMLInputElement>('rulePort').value.trim() : '' };
        const global = shared || (document.getElementById('ruleCoverage') as HTMLSelectElement | null)?.value === 'shared';
        const targets = [...new Set([...paths, conditions.program].filter(Boolean))];
        const mutation: ProfileEdit = paths.length ? {kind:'addProgramMatches',targets,conditions,exit,shared:Boolean(global)} :
          global ? {kind:'sharedRule',expected:shared?.source,conditions,exit} :
          {kind:'matchRule', conditions,exit,index,expected:original};
        const updated = await tauriApi.editProfile(mutation, scope, pins.has(exit) ? { [exit]: pins.get(exit)! } : undefined);
        if (save.isConnected) closeSheet();
        applyProfile(updated); renderAllSafe(); void refreshLiveState(true);
      } catch (e) { error.textContent = cleanError(e); }
      finally { save.disabled = false; }
    };
  }

  function openGroupSheet(existing?: ProfileGroup): void {
    let pins = editorNodePins();
    const exits = () => [...new Set([...(liveProfile?.exits || []), ...pins.keys()])].filter(item => item !== existing?.name);
    const scope = liveProfile?.subscriptionScope;
    const providers = (liveProfile?.providers || []).filter(p => !scope || p.name === scope);
    let selectedPolicy = existing?.type && ['select', 'url-test', 'fallback'].includes(existing.type) ? existing.type : 'select';
    const chosenMembers = new Set<string>(existing?.proxies || []);
    const chosenProviders = new Set<string>(existing?.use || []);

    openSheet({
      title: existing ? '编辑策略分组' : '创建策略分组',
      subtitle: '配置分组策略、成员出口与订阅源',
      iconHtml: `<span class="sq md blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg></span>`,
      size: 'wide',
      bodyHtml: `
        <div class="sheet-field">
          <label for="gsName">分组名称</label>
          <input type="text" class="sheet-input" id="gsName" value="${esc(existing?.name || '')}" ${existing ? 'readonly' : ''} placeholder="例如：AI 服务或开发工具">
        </div>
        <div class="sheet-field">
          <span class="sheet-field-label">策略类型</span>
          <div class="sub-seg full" id="gsPolicySeg">
            <button type="button" class="${selectedPolicy === 'select' ? 'active' : ''}" data-gs-policy="select">手动选择</button>
            <button type="button" class="${selectedPolicy === 'url-test' ? 'active' : ''}" data-gs-policy="url-test">自动测速优选</button>
            <button type="button" class="${selectedPolicy === 'fallback' ? 'active' : ''}" data-gs-policy="fallback">故障切换</button>
          </div>
        </div>
        <div class="sheet-field">
          <span class="sheet-field-label">成员节点 / 策略（勾选至少一项成员或订阅源）</span>
          <div class="sheet-picker" id="gsMembers" style="max-height:150px"></div>
        </div>
        ${providers.length ? `
          <div class="sheet-field">
            <span class="sheet-field-label">引入订阅源</span>
            <div class="sheet-picker" style="max-height:110px">
              ${providers.map(p => `
                <label class="sheet-picker-row">
                  <span class="mac-check"><input type="checkbox" class="gs-prov-chk" value="${esc(p.name)}" ${chosenProviders.has(p.name) ? 'checked' : ''}></span>
                  <span class="picker-meta"><strong>${esc(p.name)}</strong></span>
                </label>
              `).join('')}
            </div>
          </div>
        ` : ''}
        <p class="sheet-error" id="gsError"></p>
      `,
      actionsHtml: `
        <button type="button" class="glass-btn-soft" id="sheetCancel">取消</button>
        <button type="button" class="glass-btn-primary compact" id="gsSubmit">${existing ? '保存修改' : '创建分组'}</button>
      `,
    });
    $('sheetCancel').onclick = closeSheet;
    const picker = $('gsMembers');
    function addMembers(): void {
      const listed = new Set([...picker.querySelectorAll<HTMLInputElement>('input')].map(c => c.value));
      pins = editorNodePins();
      picker.insertAdjacentHTML('beforeend', exits().filter(v => !listed.has(v)).map(v => `
        <label class="sheet-picker-row"><span class="mac-check"><input type="checkbox" class="gs-member-chk"
          value="${esc(v)}" ${chosenMembers.has(v) ? 'checked' : ''}></span>
          <span class="picker-meta"><strong>${esc(pins.get(v) || exitDisplayLabel(v))}</strong></span></label>`).join(''));
    }
    addMembers();
    void loadEditorNodes(scope || '').then(() => { if (picker.isConnected && liveProfile?.subscriptionScope === scope) addMembers(); });
    $('gsPolicySeg').onclick = ev => {
      const b = (ev.target as HTMLElement).closest<HTMLElement>('[data-gs-policy]');
      if (!b?.dataset.gsPolicy) return;
      selectedPolicy = b.dataset.gsPolicy;
      $('gsPolicySeg').querySelectorAll('button').forEach(x => x.classList.toggle('active', x === b));
    };

    $('gsSubmit').onclick = async () => {
      const errEl = $('gsError');
      errEl.textContent = '';
      const members = [...document.querySelectorAll<HTMLInputElement>('.gs-member-chk')]
        .filter(c => c.checked).map(c => c.value);
      const provs = [...document.querySelectorAll<HTMLInputElement>('.gs-prov-chk')]
        .filter(c => c.checked).map(c => c.value);
      try {
        const profile = await tauriApi.editProfile({
          kind: 'group',
          name: $<HTMLInputElement>('gsName').value.trim(),
          policy: selectedPolicy,
          members,
          providers: provs,
        }, scope ?? '', Object.fromEntries(members.filter(m => pins.has(m)).map(m => [m, pins.get(m)!])));
        applyProfile(profile);
        closeSheet();
        renderAllSafe();
        notify(existing ? '分组已更新' : '分组已创建');
        void refreshLiveState(true);
      } catch (err) {
        errEl.textContent = cleanError(err);
      }
    };
    if (!existing) $<HTMLInputElement>('gsName').focus();
  }

  const TUN_PREFERENCES = { inherit: '继承', on: '开启', off: '关闭' } as const;

  function programTunPreference(path: string): keyof typeof TUN_PREFERENCES {
    const key = programRuleKey(path);
    return Object.entries(liveProfile?.tunTargets || {}).find(([target]) => programRuleKey(target) === key)?.[1] ?? 'inherit';
  }

  function findInstanceRule(instance: ProcessInstance): number {
    return liveProfile?.ruleInstances?.findIndex(rule => rule?.pid === instance.pid
      && rule.startedAt === instance.startedAt && rule.path === instance.path) ?? -1;
  }

  function openInstanceExit(trigger: HTMLElement, instance: ProcessInstance): void {
    const scope = liveProfile?.subscriptionScope ?? '';
    const index = findInstanceRule(instance);
    const selected = liveProfile?.ruleExits?.[index] || '';
    const items = buildExitPopupItems();
    if (index >= 0) items.unshift({ value: '', label: '清除本次规则' }, { sep: true });
    const { pid, startedAt, path } = instance;
    openMacMenu(trigger, items, selected, exit => {
      void commitProfileEdit({ kind: 'processInstanceRule', instance: { pid, startedAt, path }, exit: exit || null },
        exit ? `PID ${pid} 本次运行出口已设为 ${exitDisplayLabel(exit)}` : '已清除本次运行的规则', scope);
    });
  }

  async function assignAppExit(pathKey: string, exit: string, wholeApp: boolean): Promise<void> {
    const scope = liveProfile?.subscriptionScope ?? '';
    const app = wholeApp ? liveApps.find(a => a.path === pathKey) : undefined;
    let paths = app?.paths ?? [pathKey];
    if (!exit) {
      const savedPaths = new Set<string>();
      for (const rule of liveProfile?.rules || []) {
        const [kind, path] = rule.split(',', 2);
        if (kind === 'PROCESS-PATH' && path) savedPaths.add(path.trim());
      }
      // Include saved helpers even when they have exited since the assignment was made.
      if (app) {
        const candidates = [...new Set([...paths, ...savedPaths])].map(path => ({ path, name: '', exe: '' }));
        paths = groupRunningApps(candidates).find(group => group.paths.includes(pathKey))?.paths ?? paths;
      }
      const members = new Set(paths.map(programRuleKey));
      paths = [...savedPaths].filter(path => members.has(programRuleKey(path)));
      if (!paths.length) return;
    }
    const save = (targets: string[]) => commitProfileEdit(
      exit ? { kind: 'programRules', targets, exit } : { kind: 'clearProgramRules', targets },
      exit ? `程序出口已设为 ${exitDisplayLabel(exit)}` : '已清除单独出口，恢复按分流规则',
      scope,
    );
    if (paths.length === 1 || !app) {
      await save(paths);
      return;
    }
    const pathRow = (path: string, idx: number) => `
      <label class="sheet-picker-row">
        <span class="mac-check"><input type="checkbox" class="ap-path-chk" data-path-idx="${idx}" ${!exit || path === app.path ? 'checked' : ''}></span>
        <span class="picker-meta"><strong>${esc(path.split(/[\\/]/).at(-1) || path)}</strong>
          <small title="${esc(path)}">${esc(path)}</small></span>
      </label>`;
    const primary = paths.indexOf(app.path);
    const helpers = paths.map((path, idx) => idx !== primary ? pathRow(path, idx) : '').join('');
    openSheet({
      title: `${exit ? '设置软件出口' : '恢复按分流规则'} · ${app.name}`,
      subtitle: exit ? `默认只选择主程序，可另外勾选辅助程序 · 出口：${exitDisplayLabel(exit)}` : `将清除已勾选的程序规则（共 ${paths.length} 条可选），恢复后按其余规则处理。`,
      iconHtml: renderProgramIcon(app.icon, app.name),
      size: 'wide',
      bodyHtml: `<div class="sheet-picker" style="max-height:240px">
        ${primary >= 0 ? pathRow(paths[primary], primary) : ''}
        <details class="rule-app-group" ${primary < 0 ? 'open' : ''}>
          <summary>辅助程序（${paths.length - Number(primary >= 0)}）</summary>${helpers}</details>
      </div>`,
      actionsHtml: `
        <button type="button" class="glass-btn-soft" id="sheetCancel">取消</button>
        <button type="button" class="glass-btn-primary compact" id="apSave">${exit ? '应用规则' : '恢复默认'}</button>
      `,
    });
    $('sheetCancel').onclick = closeSheet;
    $('sheetContent').querySelector('.sheet-picker')!.addEventListener('change', () => {
      $<HTMLButtonElement>('apSave').disabled = !$('sheetContent').querySelector('.ap-path-chk:checked');
    });
    $('apSave').onclick = async () => {
      const chosen = [...document.querySelectorAll<HTMLInputElement>('.ap-path-chk')]
        .filter(c => c.checked)
        .map(c => paths[Number(c.dataset.pathIdx)]);
      if (!chosen.length) return;
      closeSheet();
      await save(chosen);
    };
  }

  async function openProcessInspector(proc: RunningProcess): Promise<void> {
    openSheet({
      title: proc.name,
      subtitle: `PID ${proc.pid} · ${proc.exe}`,
      iconHtml: renderProgramIcon(proc.icon, proc.name),
      size: 'wide',
      bodyHtml: `
        <dl class="detail-dl">
          <dt>进程标识</dt><dd>PID ${proc.pid}</dd>
          <dt>启动时间</dt><dd>${esc(formatProcessStartedAt(proc.startedAt))}</dd>
          <dt>可执行文件</dt><dd>${esc(proc.path)}</dd>
        </dl>
        <div class="thread-table-wrap" id="procThreadView">
          <p style="padding:14px;margin:0;color:var(--muted);font-size:var(--type-label)">正在读取线程列表…</p>
        </div>
      `,
      actionsHtml: `<button type="button" class="glass-btn-primary compact" id="sheetCloseProc">关闭</button>`,
    });
    $('sheetCloseProc').onclick = closeSheet;
    try {
      const threads = await tauriApi.listProcessThreads(proc.pid, proc.startedAt);
      const view = document.getElementById('procThreadView');
      if (!view) return;
      view.innerHTML = threads.length
        ? `<table class="thread-table"><thead><tr><th>线程 ID</th><th>基础优先级</th></tr></thead><tbody>${threads.map(t => `<tr><td style="font-family:var(--font-mono)">${Number(t.tid)}</td><td>${Number(t.basePriority)}</td></tr>`).join('')}</tbody></table>`
        : `<p style="padding:14px;margin:0;color:var(--muted);font-size:var(--type-label)">没有可读取的线程</p>`;
    } catch (err) {
      const view = document.getElementById('procThreadView');
      if (view) view.innerHTML = `<p style="padding:14px;margin:0;color:var(--red);font-size:var(--type-label)">${esc(cleanError(err))}</p>`;
    }
  }

  function openAppProcessesSheet(app: GroupedRunningApp): void {
    openSheet({
      title: app.name,
      subtitle: `共 ${app.instances} 个关联进程 · ${app.paths.length} 个可执行文件`,
      iconHtml: renderProgramIcon(app.icon, app.name),
      size: 'wide',
      bodyHtml: `
        <div class="thread-table-wrap">
          <table class="thread-table">
            <thead><tr><th>可执行文件</th><th>PID</th><th>线程</th><th></th></tr></thead>
            <tbody>
              ${app.members.map(m => `
                <tr>
                  <td title="${esc(m.path)}">${esc(m.exe)}</td>
                  <td style="font-family:var(--font-mono)">${m.pid}</td>
                  <td>${m.threadCount}</td>
                  <td style="text-align:right"><button type="button" class="glass-btn-soft" style="height:24px;padding:0 9px" data-inspect-member-pid="${m.pid}">线程详情</button></td>
                </tr>
              `).join('')}
            </tbody>
          </table>
        </div>
      `,
      actionsHtml: `<button type="button" class="glass-btn-primary compact" id="sheetCloseApp">关闭</button>`,
    });
    $('sheetCloseApp').onclick = closeSheet;
    $('sheetContent').querySelectorAll<HTMLElement>('[data-inspect-member-pid]').forEach(btn => {
      btn.onclick = () => {
        const member = app.members.find(m => m.pid === Number(btn.dataset.inspectMemberPid));
        if (member) void openProcessInspector(member);
      };
    });
  }

  /* =========================================================================
     Pop-Up Menu Builders & Event Wiring
     ========================================================================= */
  function buildExitPopupItems(pins = editorNodePins()): PopupMenuItem[] {
    const groupNames = new Set((liveProfile?.groups || []).map(g => g.name));
    const exits = [...new Set(['GLOBAL', ...(liveProfile?.exits || ['DIRECT', 'REJECT']), ...pins.keys()])];
    const builtins = exits.filter(x => ['GLOBAL', 'AUTO', 'DIRECT', 'REJECT', 'PASS'].includes(x));
    const groups = exits.filter(x => groupNames.has(x) && !builtins.includes(x));
    const nodes = exits.filter(x => !builtins.includes(x) && !groups.includes(x));

    const items: PopupMenuItem[] = builtins.map(v => ({
      value: v,
      label: v === 'GLOBAL' ? `${exitDisplayLabel(v)}（当前：${exitDisplayLabel(activeGlobalExit())}）` : exitDisplayLabel(v),
    }));
    if (groups.length) {
      items.push({ sep: true });
      items.push(...groups.map(g => ({ value: g, label: g, meta: '分组' })));
    }
    if (nodes.length) {
      items.push({ sep: true });
      items.push(...nodes.map(n => ({ value: n, label: pins.get(n) || n })));
    }
    return items;
  }

  shell.onViewChange(view => {
    renderView();
    if (view === 'subs') {
      for (const p of liveProfile?.providers || []) void loadSubscriptionMeta(p.name);
    } else if (view === 'nodes' && selectedSubscription) {
      if (liveProfile?.providers.some(p => p.name === selectedSubscription && p.type === 'http')) {
        void loadSubscriptionMeta(selectedSubscription);
      }
    } else if (view === 'logs') {
      void refreshConnectionLogs();
    } else if (view === 'settings') {
      void refreshNetworkDetails();
    } else if (view === 'split' && splitSub === 'procs' && !liveProcesses.length) {
      void refreshProcesses(false);
    }
  });

  shell.onSearchChange(() => renderView());

  document.querySelectorAll<HTMLElement>('.mode-pill button').forEach(b => {
    b.addEventListener('click', () => {
      const m = b.dataset.mode as RoutingMode | undefined;
      if (m) void changeLiveMode(m);
    });
  });

  $('sideSysProxy').addEventListener('change', e => {
    const input = e.target as HTMLInputElement;
    const enabled = input.checked;
    input.checked = Boolean(liveStatus?.systemProxy);
    void performNetworkControl({ control: 'system', enabled });
  });
  $('sideTunToggle').addEventListener('change', e => {
    const input = e.target as HTMLInputElement;
    const enabled = input.checked;
    input.checked = Boolean(liveStatus?.tun);
    void performNetworkControl({ control: 'tun', enabled });
  });
  $('coreControlBtn').addEventListener('click', () => {
    void performNetworkControl({ control: 'core', enabled: !liveStatus?.running });
  });

  $('nodesImportBtn').addEventListener('click', openImportSheet);
  $('subImportBtn').addEventListener('click', openImportSheet);
  $('newYamlBtn').onclick = () => editDocument('new');
  $('refreshAllSubsBtn').onclick = () => void refreshSubscriptions();
  $('editConfigBtn').onclick = () => editDocument('config');
  $('heroProbeBtn').addEventListener('click', () => {
    const active = activeGlobalExit();
    const target = allSelectableNodes().find(n => n.name === active)
      || (active === 'AUTO' ? { name: 'AUTO', type: 'URLTest', provider: selectedSubscription || null, policy: true } : null);
    if (!target) {
      notify('当前出口无需测速');
      return;
    }
    void testSingleNode(target);
  });

  $('nodesSubSeg').addEventListener('click', e => {
    const b = (e.target as HTMLElement).closest<HTMLElement>('[data-nodes-sub]');
    if (!b?.dataset.nodesSub) return;
    nodesSub = b.dataset.nodesSub as typeof nodesSub;
    $('nodesSubSeg').querySelectorAll('button').forEach(x => x.classList.toggle('active', x === b));
    renderNodes();
  });
  $('nodesActionBtn').addEventListener('click', () => nodesSub === 'ports' ? void openFixedSocksEditor() : void runBatch(nodesSub === 'groups' ? 'delay' : 'sites'));
  $('nodesBandwidthBtn').addEventListener('click', () => void runBatch('download'));

  $('splitSubSeg').addEventListener('click', e => {
    const b = (e.target as HTMLElement).closest<HTMLElement>('[data-split-sub]');
    if (!b?.dataset.splitSub) return;
    splitSub = b.dataset.splitSub as 'rules' | 'groups' | 'procs';
    $('splitSubSeg').querySelectorAll('button').forEach(x => x.classList.toggle('active', x === b));
    renderSplit();
    if (splitSub === 'procs' && !liveProcesses.length) void refreshProcesses(false);
  });

  $('procScanSeg').addEventListener('click', e => {
    const b = (e.target as HTMLElement).closest<HTMLElement>('[data-scan-type]');
    if (!b?.dataset.scanType) return;
    procScanType = b.dataset.scanType as 'app' | 'process';
    renderSplit();
  });
  $('ruleOrderBtn').onclick = showRuleOrder;
  $('refreshProcsBtn').addEventListener('click', () => void refreshProcesses(true));

  $('splitPrimaryAddBtn').addEventListener('click', () => {
    if (!liveProfile) return;
    if (splitSub === 'groups') openGroupSheet();
    else openRuleEditor();
  });

  $('simForm').addEventListener('submit', async e => {
    e.preventDefault();
    const host = $<HTMLInputElement>('simHostInput').value
      .trim().replace(/^https?:\/\//i, '').replace(/\/.*$/, '');
    if (!host) return;
    try {
      if (!await ensureLocalCore()) throw new Error('请先添加订阅或导入配置。');
      const result = await tauriApi.mihomoWebsiteProbe(host);
      notify(`${host}：HTTP ${result.status} · ${result.ms} ms`, result.status >= 400);
      await refreshConnectionLogs();
    } catch (err) {
      notify(cleanError(err), true);
    }
  });
  $('activeRoutesBtn').hidden = false;
  $('activeRoutesBtn').onclick = () => inspectRoutes();
  $('clearLogsBtn').addEventListener('click', () => void refreshConnectionLogs(true));

  $('subFileInput').addEventListener('change', e => {
    const input = e.target as HTMLInputElement;
    const file = input.files?.[0];
    input.value = '';
    if (file) void handleFileImport(file);
  });

  $('savePortsBtn').addEventListener('click', async () => {
    if (savingPorts || networkUpdating || changingSubscription || profileBusy) return;
    const mixed = Number($<HTMLInputElement>('portMixedInput').value || 0);
    const http = Number($<HTMLInputElement>('portHttpInput').value || 0);
    const socks = Number($<HTMLInputElement>('portSocksInput').value || 0);
    if (![mixed, http, socks].every(port => Number.isInteger(port) && port >= 0 && port <= 65535)) {
      notify('端口必须是 0 到 65535 的整数', true);
      return;
    }
    savingPorts = true;
    renderSettings();
    try {
      await commitProfileEdit({ kind: 'ports', http, socks, mixed },
        liveStatus?.running ? '监听端口已更新并立即生效' : '监听端口已保存，启动内核后生效');
    } finally {
      savingPorts = false;
      renderSettings();
    }
  });

  $('copyEnvBtn').addEventListener('click', () => {
    const port = activeListenPort();
    if (!port) { notify('请先配置 HTTP 或混合监听端口。'); return; }
    const text = buildProxyEnvText(port, liveStatus?.platform);
    navigator.clipboard?.writeText(text).then(
      () => notify(`已复制终端代理环境变量 (127.0.0.1:${port})`),
      () => notify('无法访问剪贴板', true),
    );
  });

  $('probeIpBtn').addEventListener('click', async () => {
    const btn = $<HTMLButtonElement>('probeIpBtn');
    btn.disabled = true;
    try {
      exitIp = await tauriApi.mihomoExitIp();
      renderConnect();
      renderSettings();
      notify(`出口 IP：${exitIp}`);
    } catch (err) {
      exitIp = '';
      notify(cleanError(err), true);
    } finally {
      btn.disabled = !liveCore;
    }
  });

  $('exportBackupBtn').addEventListener('click', async () => {
    try {
      await tauriApi.coreProfileBackup(false);
      notify('代理配置备份已保存');
    } catch (err) {
      notify(cleanError(err), true);
    }
  });

  $('resetStateBtn').addEventListener('click', async () => {
    if (liveStatus?.running) {
      notify('请先停止内核，再恢复备份。');
      $('coreControlBtn').focus();
      return;
    }
    const ok = await confirmSheet({
      title: '恢复配置备份',
      message: '恢复备份会替换当前的代理配置，是否继续？',
      confirmLabel: '恢复',
      danger: true,
    });
    if (!ok) return;
    try {
      await tauriApi.coreProfileBackup(true);
      notify('已恢复代理配置备份');
      await reloadProfile();
      await refreshLiveState(true);
    } catch (err) {
      notify(cleanError(err), true);
    }
  });

  // Delegated clicks
  document.addEventListener('click', async e => {
    const target = e.target as HTMLElement;

    const popTrigger = target.closest<HTMLElement>('[data-popup-kind]');
    if (popTrigger) {
      e.stopPropagation();
      const kind = popTrigger.dataset.popupKind || '';
      const key = popTrigger.dataset.popupKey || '';
      const val = popTrigger.dataset.popupVal || '';

      if (kind === 'default-exit') {
        openMacMenu(popTrigger, buildExitPopupItems(), val, nextVal => {
          const idx = liveProfile?.rules?.findIndex(r => r.startsWith('MATCH,')) ?? -1;
          void commitProfileEdit({
            kind: 'rule',
            index: idx < 0 ? undefined : idx,
            expected: idx < 0 ? undefined : liveProfile?.rules?.[idx],
            category: 'MATCH',
            target: '',
            exit: nextVal,
          }, `未命中规则时：${exitDisplayLabel(nextVal)}`);
        });
        return;
      }

      if (kind === 'process-instance-exit') {
        const instance = liveProcesses.find(process => `${process.pid}:${process.startedAt}` === key);
        if (instance) openInstanceExit(popTrigger, instance);
        return;
      }

      if (kind === 'app-exit' || kind === 'process-exit') {
        const items: PopupMenuItem[] = [{ value: '', label: '按分流规则（无单独设置）' }, { sep: true }, ...buildExitPopupItems()];
        openMacMenu(popTrigger, items, popTrigger.dataset.popupVal ?? null, nextVal => {
          void assignAppExit(key, nextVal, kind === 'app-exit');
        });
        return;
      }

      if (kind === 'group-exit') {
        const live = liveCore?.proxies?.proxies?.[key];
        if (!live?.all?.length) return;
        const items: PopupMenuItem[] = live.all.map(m => ({ value: m, label: exitDisplayLabel(m) }));
        openMacMenu(popTrigger, items, val, async nextVal => {
          try {
            await tauriApi.mihomoSelectGroup(key, nextVal);
            groupSelections.set(JSON.stringify([liveProfile?.subscriptionScope || '', key]), nextVal);
            saveMap(KEY_GROUP_EXITS, groupSelections);
            notify(`「${key}」出口已切换至 ${nextVal}`);
            await refreshLiveState(true);
          } catch (err) {
            notify(cleanError(err), true);
          }
        });
        return;
      }

      if (kind === 'tun-scope') {
        if (!liveStatus?.selectedTunAvailable) {
          await commitProfileEdit({ kind: 'tunScope', scope: 'all' }, '已选择全局 TUN 范围');
          return;
        }
        openMacMenu(popTrigger, [
          { value: 'all', label: '全部受支持流量' },
          { value: 'selected', label: '仅指定分组和程序' },
        ], val, scope => {
          if (scope !== 'all' && scope !== 'selected') return;
          void commitProfileEdit({ kind: 'tunScope', scope }, 'TUN 接管范围已保存');
        });
        return;
      }

      if (kind === 'program-tun') {
        const scope = liveProfile?.subscriptionScope ?? '';
        openMacMenu(popTrigger, Object.entries(TUN_PREFERENCES).map(([value, label]) => ({ value, label })),
          val, mode => {
            if (mode !== 'inherit' && mode !== 'on' && mode !== 'off') return;
            void commitProfileEdit({ kind: 'setRuleTun', target: key, mode }, '程序 TUN 设置已保存', scope);
          });
        return;
      }

    }

    if (!target.closest('#macMenuPopover')) closeMacMenu();

    if (target.id === 'bannerImportBtn') {
      openImportSheet();
      return;
    }
    if (target.id === 'bannerRetryBtn') {
      void refreshLiveState(true);
      return;
    }

    const drawerHead = target.closest<HTMLElement>('[data-toggle-drawer]');
    if (drawerHead?.dataset.toggleDrawer) {
      const id = drawerHead.dataset.toggleDrawer;
      if (expandedGroups.has(id)) expandedGroups.delete(id); else expandedGroups.add(id);
      renderNodes();
      document.querySelector<HTMLElement>(`[data-toggle-drawer="${CSS.escape(id)}"]`)?.focus({ preventScroll: true });
      return;
    }

    const testNodeBtn = target.closest<HTMLElement>('[data-test-node]');
    if (testNodeBtn?.dataset.testNode) {
      e.stopPropagation();
      const name = testNodeBtn.dataset.testNode;
      const provider = testNodeBtn.dataset.testProvider || null;
      void testSingleNode({ name, type: '', provider, policy: name === 'AUTO' });
      return;
    }

    const removeNodeBtn = target.closest<HTMLElement>('[data-remove-node]');
    if (removeNodeBtn?.dataset.removeNode) {
      e.stopPropagation();
      const name = removeNodeBtn.dataset.removeNode;
      const ok = await confirmSheet({
        title: '删除节点',
        message: `确定删除独立导入的节点「${name}」吗？`,
        confirmLabel: '删除',
        danger: true,
      });
      if (ok) void commitProfileEdit({ kind: 'removeNode', name }, `已删除节点 ${name}`);
      return;
    }

    const pickNode = target.closest<HTMLElement>('[data-pick-node]');
    if (pickNode?.dataset.pickNode) {
      void selectLiveNode(pickNode.dataset.pickNode);
      return;
    }

    const grpPick = target.closest<HTMLElement>('[data-group-pick]');
    if (grpPick?.dataset.groupPick) {
      const sepIdx = grpPick.dataset.groupPick.indexOf('::');
      if (sepIdx > 0) {
        const group = grpPick.dataset.groupPick.slice(0, sepIdx);
        const name = grpPick.dataset.groupPick.slice(sepIdx + 2);
        try {
          await tauriApi.mihomoSelectGroup(group, name);
          groupSelections.set(JSON.stringify([liveProfile?.subscriptionScope || '', group]), name);
          saveMap(KEY_GROUP_EXITS, groupSelections);
          notify(`「${group}」已切换至 ${name}`);
          await refreshLiveState(true);
        } catch (err) {
          notify(cleanError(err), true);
        }
      }
      return;
    }

    const probeSiteBtn = target.closest<HTMLElement>('[data-probe-site]');
    if (probeSiteBtn?.dataset.probeSite) {
      const [ci, si] = probeSiteBtn.dataset.probeSite.split('-').map(Number);
      void probeSite(ci, si);
      return;
    }

    const sharedInspect = target.closest<HTMLElement>('[data-shared-inspect]');
    if (sharedInspect) {inspectRoutes(sharedInspect.dataset.sharedInspect); return;}
    const sharedEdit = target.closest<HTMLElement>('[data-shared-edit]');
    if (sharedEdit) {
      const rule = liveProfile?.sharedRules?.find(r => r.source === sharedEdit.dataset.sharedEdit);
      if (rule) openRuleEditor(undefined,undefined,rule);
      return;
    }
    const sharedDelete = target.closest<HTMLElement>('[data-shared-delete]');
    if (sharedDelete) {
      const scope = liveProfile?.subscriptionScope ?? '';
      const expected = sharedDelete.dataset.sharedDelete;
      if (await confirmSheet({title:'删除共享规则',message:'所有订阅都会移除这条个人规则。',confirmLabel:'删除',danger:true})) {
        await commitProfileEdit({kind:'sharedRule',expected},'共享规则已移除',scope);
      }
      return;
    }
    const inspect = target.closest<HTMLElement>('[data-inspect-rule]');
    if (inspect) { inspectRoutes(liveProfile?.rules?.[Number(inspect.dataset.inspectRule)]); return; }
    const fromLog = target.closest<HTMLElement>('[data-log-rule]');
    if (fromLog) {
      const row = liveLogs[Number(fromLog.dataset.logRule)];
      if (!row) return;
      const address = row.target.match(/^(.*):(\d+)$/);
      const paths = new Set(liveProcesses.filter(p => p.exe === row.app || p.path === row.app).map(p => p.path));
      openRuleEditor(undefined,{target:address?.[1] || row.target,port:address?.[2] || '',program:paths.size === 1 ? [...paths][0] : ''});
      return;
    }
    const editRuleBtn = target.closest<HTMLElement>('[data-edit-rule-idx]');
    if (editRuleBtn?.dataset.editRuleIdx) {
      const index = Number(editRuleBtn.dataset.editRuleIdx);
      const instance = liveProfile?.ruleInstances?.[index];
      if (instance) openInstanceExit(editRuleBtn, instance);
      else openRuleEditor(index);
      return;
    }

    const delRuleBtn = target.closest<HTMLElement>('[data-del-rule-idx]');
    if (delRuleBtn?.dataset.delRuleIdx) {
      const ok = await confirmSheet({ title: '删除规则', message: '确定删除这条分流规则吗？', confirmLabel: '删除', danger: true });
      if (ok) {
        void commitProfileEdit({
          kind: 'removeRule',
          index: Number(delRuleBtn.dataset.delRuleIdx),
          expected: delRuleBtn.dataset.ruleExpected || '',
        }, '规则已删除');
      }
      return;
    }

    const detachBtn = target.closest<HTMLElement>('[data-detach-rule-idx]');
    if (detachBtn?.dataset.detachRuleIdx) {
      void commitProfileEdit({
        kind: 'detachRule',
        index: Number(detachBtn.dataset.detachRuleIdx),
        expected: detachBtn.dataset.ruleExpected || '',
      }, '已移出分组');
      return;
    }

    const editGrpBtn = target.closest<HTMLElement>('[data-edit-group]');
    if (editGrpBtn?.dataset.editGroup) {
      const g = liveProfile?.groups.find(x => x.name === editGrpBtn.dataset.editGroup);
      if (g) openGroupSheet(g);
      return;
    }

    const delGrpBtn = target.closest<HTMLElement>('[data-del-group]');
    if (delGrpBtn?.dataset.delGroup) {
      const name = delGrpBtn.dataset.delGroup;
      const ok = await confirmSheet({ title: '删除分组', message: `确定删除策略分组「${name}」吗？`, confirmLabel: '删除', danger: true });
      if (ok) void commitProfileEdit({ kind: 'removeGroup', name }, `已删除分组「${name}」`);
      return;
    }

    const procDetailBtn = target.closest<HTMLElement>('[data-proc-detail-pid]');
    if (procDetailBtn?.dataset.procDetailPid) {
      const pid = Number(procDetailBtn.dataset.procDetailPid);
      if (procDetailBtn.dataset.procDetailMode === 'app') {
        const app = liveApps.find(a => a.pid === pid);
        if (app) openAppProcessesSheet(app);
      } else {
        const proc = liveProcesses.find(p => p.pid === pid);
        if (proc) void openProcessInspector(proc);
      }
      return;
    }

    const editSub = target.closest<HTMLElement>('[data-edit-sub]')?.dataset.editSub;
    if (editSub) {
      editDocument(liveProfile?.providers.find(p => p.name === editSub)?.type === 'http' ? 'remote' : 'file', editSub);
      return;
    }

    const refSubBtn = target.closest<HTMLElement>('[data-ref-sub]');
    if (refSubBtn?.dataset.refSub) {
      e.stopPropagation();
      void refreshSubscriptions(refSubBtn.dataset.refSub);
      return;
    }

    const delSubBtn = target.closest<HTMLElement>('[data-del-sub]');
    if (delSubBtn?.dataset.delSub) {
      e.stopPropagation();
      const name = delSubBtn.dataset.delSub;
      const ok = await confirmSheet({ title: '移除订阅', message: `确定移除订阅「${name}」吗？`, confirmLabel: '移除', danger: true });
      if (ok) void commitProfileEdit({ kind: 'removeProvider', name }, `已移除订阅「${name}」`);
      return;
    }

    const restoreExitBtn = target.closest<HTMLElement>('[data-restore-sub-exit]');
    if (restoreExitBtn?.dataset.restoreSubExit) {
      e.stopPropagation();
      void commitProfileEdit({ kind: 'toggleGroup', name: restoreExitBtn.dataset.restoreSubExit, enabled: true }, '已恢复规则出口');
      return;
    }

    const selectSubCard = target.closest<HTMLElement>('[data-select-sub]');
    if (selectSubCard?.dataset.selectSub) {
      const name = selectSubCard.dataset.selectSub;
      if (name !== selectedSubscription) void switchSubscription(name);
    }
  });

  // Delegated switches
  document.addEventListener('change', e => {
    const input = e.target as HTMLInputElement;
    if (input.dataset.groupTun !== undefined) {
      const enabled = input.checked;
      input.checked = !enabled;
      void commitProfileEdit({ kind: 'toggleGroupTun', name: input.dataset.groupTun, enabled }, '分组 TUN 设置已保存');
      return;
    }
    if (input.dataset.toggleRuleIdx !== undefined) {
      const enabled = input.checked;
      input.checked = !enabled;
      void commitProfileEdit({
        kind: 'toggleRule',
        index: Number(input.dataset.toggleRuleIdx),
        expected: input.dataset.ruleExpected || '',
        enabled,
      });
      return;
    }
    if (input.dataset.toggleGroup) {
      const enabled = input.checked;
      input.checked = !enabled;
      void commitProfileEdit({ kind: 'toggleGroup', name: input.dataset.toggleGroup, enabled });
      return;
    }

  });

  // Tray actions from Rust backend
  void listenTrayAction(payload => {
    const sep = payload.indexOf(':');
    if (sep <= 0) return;
    const control = payload.slice(0, sep);
    const value = payload.slice(sep + 1);
    if (networkUpdating || selectingNode || changingMode || changingSubscription) return;
    if (control === 'node') {
      void selectLiveNode(value, true);
    } else if (control === 'mode' && ['rule', 'global', 'direct'].includes(value)) {
      void changeLiveMode(value as RoutingMode, true);
    } else if (['power', 'system', 'tun'].includes(control) && ['on', 'off'].includes(value)) {
      void performNetworkControl({
        control: (control === 'power' ? 'core' : control) as NetworkControlAction['control'],
        enabled: value === 'on',
        fromTray: true,
      });
    }
  });

  // Bootstrap & Polling
  telemetry.renderConnections();
  telemetry.paintChart();
  void reloadProfile();
  void refreshProcesses(false);

  let nativeVisible = true;
  let pollTimer = 0;
  let clockTimer = 0;
  function updateTimers(): void {
    clearInterval(pollTimer);
    clearInterval(clockTimer);
    lastTraffic = null;
    if (document.hidden || !nativeVisible) return;
    void refreshLiveState(true);
    pollTimer = window.setInterval(() => void refreshLiveState(), 2000);
    clockTimer = window.setInterval(() => {
      if (sessionStartedAt && shell.getView() === 'connect') {
        $('kpiTimer').textContent = fmtTime(Math.floor((Date.now() - sessionStartedAt) / 1000));
      }
    }, 1000);
  }

  document.addEventListener('visibilitychange', updateTimers);
  void listenWindowVisibility(visible => {
    if (nativeVisible === visible) return;
    nativeVisible = visible;
    updateTimers();
  });
  updateTimers();
}
