export type Platform = 'windows' | 'macos' | 'linux';
export type RoutingMode = 'rule' | 'global' | 'direct';
export type TunScope = 'all' | 'selected';
export type RuleTunMode = 'inherit' | 'on' | 'off';

export type CoreStatus = {
  appData: string;
  platform: Platform;
  available: boolean;
  configured: boolean;
  running: boolean;
  systemProxy: boolean;
  tun: boolean;
  tunScope: TunScope;
  selectedTunAvailable: boolean;
  httpPort?: number | null;
  dnsMode?: 'off' | 'fake-ip' | 'redir-host' | 'enabled' | null;
  tunDnsHijack?: boolean;
};

export type ProfileGroup = {
  name: string;
  type: string;
  proxies?: string[];
  use?: string[];
  enabled: boolean;
};

export type ProfileProvider = {
  name: string;
  type?: string;
  interval?: number;
  source?: string | null;
  ruleExitDisabled?: boolean;
};

export type ProfileProcessRule = {
  kind: 'PROCESS-PATH' | 'PROCESS-NAME';
  target: string;
  exit: string;
};

export type ProfileNode = {
  name: string;
  type?: string;
};

export type CoreSettings = {
  ipv6: boolean;
  'tcp-concurrent': boolean;
  'unified-delay': boolean;
  'routepilot-fallback-direct': boolean;
  'log-level': string;
};

export type RuleConditions = { program: string; target: string; suffix: boolean; port: string };

export type SharedRule = { source: string; line: string; exit: string; conditions: RuleConditions };
export type ScopeMapping = { missing: string[]; available: string[] };

export type FixedSocksBinding = { port: number; node: string; provider: string | null };

export type ProfileSummary = {
  fixedSocks?: FixedSocksBinding[] | null;
  sharedRules?: SharedRule[];
  managedOrder?: boolean;
  manualOrder?: boolean;
  effectiveRules?: string[];
  ruleConditions?: (RuleConditions | null)[];
  ruleInstances?: (ProcessInstance | null)[];
  coreSettings: CoreSettings;
  subscriptionScope?: string | null;
  subscriptionScopeInitialized?: boolean;
  http?: number | null;
  socks?: number | null;
  mixed?: number | null;
  mode?: RoutingMode;
  rules?: string[];
  ruleExits?: (string | null)[];
  disabledRules?: string[];
  disabledGroups?: string[];
  groups: ProfileGroup[];
  providers: ProfileProvider[];
  exits: string[];
  nodePins?: Record<string, string>;
  nodes: ProfileNode[];
  processRules?: ProfileProcessRule[];
  tunScope: TunScope;
  tunGroups: string[];
  tunTargets: Record<string, 'on' | 'off'>;
};

export type ProfileSummaryResponse = {
  profile: ProfileSummary;
  running: boolean;
};

export type SubscriptionUsage = {
  Upload?: number;
  Download?: number;
  Total?: number;
  Expire?: number;
};

export type SubscriptionCardMetadata = {
  updatedAt?: number | null;
  usage?: SubscriptionUsage | null;
  nodes?: ProfileNode[] | null;
  error?: string | null;
};

export type MihomoProxyEntry = {
  name: string;
  type: string;
  now?: string;
  all?: string[];
  history?: { delay?: number }[];
  provider?: string;
};

export type MihomoProviderEntry = {
  name?: string;
  vehicleType?: string;
  updatedAt?: string;
  subscriptionInfo?: SubscriptionUsage;
  proxies?: MihomoProxyEntry[];
};

export type MihomoSnapshot = {
  config?: {
    port?: number;
    'socks-port'?: number;
    'mixed-port'?: number;
    mode?: RoutingMode;
    tun?: { enable?: boolean };
  };
  proxies?: {
    proxies?: Record<string, MihomoProxyEntry>;
  };
  providers?: {
    providers?: Record<string, MihomoProviderEntry>;
  };
  rules?: {
    rules?: { type: string; payload: string; proxy: string }[];
  };
  connections?: {
    downloadTotal?: number;
    uploadTotal?: number;
    count?: number;
    memory?: number;
  };
};

export type DelayResult = {
  delay?: number | null;
  mbps?: number | null;
};

export type WebsiteProbeResult = {
  ms: number;
  status: number;
};

export type ActiveRoute = {
  program: string; process: string; host: string; ip: string; port: string | number; network: string;
  inbound: string; rule: string; payload: string; chains: string[];
};

export type ConnectionLogRow = {
  time: string;
  app: string;
  target: string;
  protocol: string;
  exit: string;
  decision: string;
  failed: boolean;
};

export type RunningProcess = {
  pid: number;
  name: string;
  exe: string;
  path: string;
  startedAt: string;
  threadCount: number;
  icon?: string | null;
};
export type ProcessInstance = Pick<RunningProcess, 'pid' | 'startedAt' | 'path'>;

export type GroupedRunningApp = RunningProcess & {
  members: RunningProcess[];
  paths: string[];
  instances: number;
};

export type ProcessThread = {
  tid: number;
  basePriority: number;
};

export type NetworkDetails = {
  addresses: string[];
  dns: string[];
  error?: boolean;
};

export type TrayState = {
  english: boolean;
  configured: boolean;
  running: boolean;
  systemProxy: boolean;
  tun: boolean;
  busy: boolean;
  mode: string;
  nodes: string[];
  selected: string;
};

export type ProfileEdit =
  | { kind: 'mode'; mode: RoutingMode }
  | { kind: 'coreSetting'; key: keyof CoreSettings; value: string | boolean }
  | { kind: 'providerInterval'; name: string; seconds: number }
  | { kind: 'fixedSocks'; binding: FixedSocksBinding; remove: boolean }
  | { kind: 'ports'; http: number; socks: number; mixed: number }
  | { kind: 'rule'; index?: number; expected?: string; category: string; target: string; exit: string }
  | { kind: 'ruleOrder'; expected: string[]; order: string[] | null }
  | { kind: 'sharedRule'; expected?: string; conditions?: RuleConditions; exit?: string }
  | { kind: 'matchRule'; index?: number; expected?: string; conditions: RuleConditions; exit: string }
  | { kind: 'addProgramMatches'; targets: string[]; conditions: RuleConditions; exit: string; shared: boolean }
  | { kind: 'programRules'; targets: string[]; exit: string }
  | { kind: 'processInstanceRule'; instance: ProcessInstance; exit: string | null }
  | { kind: 'clearProgramRules'; targets: string[] }
  | { kind: 'batchRules'; action: 'enable' | 'disable' | 'delete'; rules: { index: number; expected: string }[] }
  | { kind: 'removeRule'; index: number; expected: string }
  | { kind: 'detachRule'; index: number; expected: string }
  | { kind: 'toggleRule'; index: number; expected: string; enabled: boolean }
  | { kind: 'toggleGroup'; name: string; enabled: boolean }
  | { kind: 'group'; name: string; policy: string; members: string[]; providers: string[] }
  | { kind: 'removeGroup'; name: string }
  | { kind: 'provider'; name: string; url: string; interval: number }
  | { kind: 'removeProvider'; name: string }
  | { kind: 'removeNode'; name: string }
  | { kind: 'tunScope'; scope: TunScope }
  | { kind: 'toggleGroupTun'; name: string; enabled: boolean }
  | { kind: 'setRuleTun'; target: string; mode: RuleTunMode };

type TauriGlobal = {
  core: {
    invoke<T>(command: string, args?: Record<string, unknown>): Promise<T>;
  };
  event?: {
    listen<T>(event: string, handler: (event: { payload: T }) => void): Promise<() => void>;
  };
};

const win = window as Window & { __TAURI__?: TauriGlobal };

export function isTauri(): boolean {
  return Boolean(win.__TAURI__?.core?.invoke);
}

export function invoke<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  if (!win.__TAURI__?.core?.invoke) {
    return Promise.reject(new Error('Tauri runtime unavailable'));
  }
  return win.__TAURI__.core.invoke<T>(command, args);
}

export function listenTrayAction(handler: (payload: string) => void): Promise<() => void> | undefined {
  return win.__TAURI__?.event?.listen<string>('routepilot-tray-action', ({ payload }) => handler(payload));
}

export function listenWindowVisibility(handler: (visible: boolean) => void): Promise<() => void> | undefined {
  return win.__TAURI__?.event?.listen<boolean>('routepilot-window-visible', ({ payload }) => handler(payload));
}

export const tauriApi = {
  activeRoutes: () => invoke<ActiveRoute[]>('active_routes'),
  chooseProgramPath: () => invoke<string | null>('choose_program_path'),
  coreLogTail: () => invoke<string>('core_log_tail'),
  coreStatus: () => invoke<CoreStatus>('core_status'),
  startLocalCore: () => invoke<CoreStatus>('start_local_core'),
  startGlobalTun: () => invoke<CoreStatus>('start_global_tun'),
  stopLocalCore: () => invoke<CoreStatus>('stop_local_core'),
  setSystemProxy: (enabled: boolean) => invoke<CoreStatus>('set_system_proxy', { enabled }),
  importCoreConfig: (content: string, expected?: string) => invoke<CoreStatus>('import_core_config', { content, expected }),
  profileSummary: () => invoke<ProfileSummaryResponse>('configured_profile_summary'),
  editProfile: (edit: ProfileEdit, expectedScope?: string, nodePins?: Record<string, string>) =>
    invoke<ProfileSummary>('edit_core_profile', { edit, expectedScope: expectedScope ?? '', nodePins }),
  subscriptionMapping: (name: string) => invoke<ScopeMapping>('subscription_mapping', { name }),
  setSubscriptionScope: (name: string | null, mapping?: Record<string,string>) =>
    invoke<ProfileSummary>('set_subscription_scope', { name, mapping }),
  subscriptionNodes: (name: string) => invoke<ProfileNode[]>('subscription_nodes', { name }),
  subscriptionCardMetadata: (name: string) =>
    invoke<SubscriptionCardMetadata>('subscription_card_metadata', { name }),
  importSubscriptionLink: (url: string) => invoke<ProfileSummary>('import_subscription_link', { url }),
  importNodeLinks: (content: string) => invoke<ProfileSummary>('import_node_links', { content }),
  importSubscriptionFile: (name: string, content: string, options?: { expected?: string; authored?: boolean }) =>
    invoke<ProfileSummary>('import_subscription_file', { name, content, ...options }),
  readProfileDocument: (name: string | null, payload = false) =>
    invoke<string>('read_profile_document', { name, payload }),
  editSubscriptionUrl: (name: string, expected: string, url: string) =>
    invoke<ProfileSummary>('edit_subscription_url', { name, expected, url }),
  coreProfileBackup: (restore: boolean) => invoke<void>('core_profile_backup', { restore }),
  mihomoSnapshot: (light: boolean) => invoke<MihomoSnapshot>('mihomo_snapshot', { light }),
  mihomoDelay: (name: string, provider: string | null, download: boolean, target: string, timeoutMs: number) =>
    invoke<DelayResult>('mihomo_delay', { name, provider, download, target, timeoutMs }),
  mihomoSelect: (name: string) => invoke<void>('mihomo_select', { name }),
  mihomoSelectGroup: (group: string, name: string) =>
    invoke<void>('mihomo_select_group', { group, name }),
  mihomoRefreshProvider: (name: string) => invoke<void>('mihomo_refresh_provider', { name }),
  mihomoWebsiteProbe: (host: string) => invoke<WebsiteProbeResult>('mihomo_website_probe', { host }),
  mihomoExitIp: () => invoke<string>('mihomo_exit_ip'),
  connectionLogs: (clear = false) => invoke<ConnectionLogRow[]>('connection_log_rows', { clear }),
  listRunningProcesses: () => invoke<RunningProcess[]>('list_running_processes'),
  checkProcessInstances: (instances: ProcessInstance[]) =>
    invoke<boolean[]>('check_process_instances', { instances }),
  listProcessThreads: (pid: number, startedAt: string) =>
    invoke<ProcessThread[]>('list_process_threads', { pid, startedAt }),
  systemNetworkDetails: () =>
    invoke<NetworkDetails>('system_network_details').catch(() =>
      invoke<NetworkDetails>('windows_network_details')
    ),
  updateTrayMenu: (state: TrayState) => invoke<void>('update_tray_menu', { state }),
  showWindow: () => invoke<void>('show_routepilot'),
  windowMinimize: () => invoke<void>('window_minimize'),
  windowToggleMaximize: () => invoke<boolean>('window_toggle_maximize'),
  windowClose: () => invoke<void>('window_close'),
};

export function platformLabel(platform?: Platform): string {
  if (platform === 'macos') return 'macOS';
  if (platform === 'windows') return 'Windows';
  if (platform === 'linux') return 'Linux';
  return 'Desktop';
}

export function tunElevationMessage(platform?: Platform, scope?: TunScope): string {
  if (platform === 'windows' && scope === 'selected') {
    return '规则模式下使用签名网络驱动接管所选程序。首次使用会从 WinDivert 官方发布页下载并校验驱动，请保持网络连接。准备完成后 Windows 会请求 UAC 授权启动后台，主窗口继续以普通权限运行。';
  }
  const scopeDesc = scope === 'selected'
    ? '当前已设为「仅指定分组和程序」，规则模式下仅对勾选 TUN 的分组/程序生效。'
    : '当前将接管系统全部受支持流量。';
  if (platform === 'macos') {
    return `虚拟网卡 (TUN) 需要系统管理员权限。${scopeDesc}确认后，macOS 会弹出授权窗口启动 TUN 后台，主窗口继续以普通权限运行。`;
  }
  if (platform === 'linux') {
    return `虚拟网卡 (TUN) 需要管理员权限。${scopeDesc}确认后，系统将通过 pkexec 请求授权启动 TUN 后台。`;
  }
  return `虚拟网卡 (TUN) 会接管系统网络流量。${scopeDesc}确认后，Windows 会请求 UAC 授权启动 TUN 后台，主窗口继续以普通权限运行。`;
}

export function buildProxyEnvText(port: number, platform?: Platform): string {
  const httpUrl = `http://127.0.0.1:${port}`;
  if (platform === 'windows') {
    return `$env:HTTP_PROXY = '${httpUrl}'\n$env:HTTPS_PROXY = '${httpUrl}'\n$env:ALL_PROXY = '${httpUrl}'`;
  }
  return `export http_proxy='${httpUrl}' https_proxy='${httpUrl}' all_proxy='${httpUrl}'`;
}

export function formatProcessStartedAt(raw: string): string {
  const value = String(raw || '').trim();
  if (!value) return '—';
  // Windows FILETIME (100-ns ticks since 1601-01-01)
  if (/^\d{16,}$/.test(value)) {
    try {
      const ms = Number(BigInt(value) / 10000n - 11644473600000n);
      if (Number.isFinite(ms) && ms > 0) return new Date(ms).toLocaleString();
    } catch {
      return value;
    }
  }
  // macOS `ps -o lstart=` date string
  const parsed = Date.parse(value);
  if (!Number.isNaN(parsed)) {
    return new Date(parsed).toLocaleString();
  }
  // Linux /proc/<pid>/stat boot jiffies
  if (/^\d+$/.test(value)) {
    return `启动节拍 #${value}`;
  }
  return value;
}

const SHARE_SCHEMES = /^(?:vless|vmess|trojan|ss|ssr|hysteria2|hy2|tuic):\/\//i;

export function looksLikeShareLinks(raw: string): boolean {
  const trimmed = raw.trim();
  if (!trimmed) return false;
  const lines = trimmed.split(/\r?\n/).map(l => l.trim()).filter(Boolean);
  if (lines.some(line => SHARE_SCHEMES.test(line))) return true;
  if (lines.length === 1 && !/^https?:\/\//i.test(trimmed) && /^[A-Za-z0-9+/=_-]{24,}$/.test(trimmed)) {
    try {
      const decoded = atob(trimmed.replace(/-/g, '+').replace(/_/g, '/'));
      return SHARE_SCHEMES.test(decoded.trim());
    } catch {
      return false;
    }
  }
  return false;
}

export function looksLikeFullConfig(filename: string, content: string): boolean {
  const clean = content.replace(/^\uFEFF/, '').trim();
  if (filename.toLowerCase().endsWith('.json')) {
    try {
      const parsed = JSON.parse(clean);
      if (parsed && typeof parsed === 'object') {
        return ['port', 'mixed-port', 'socks-port', 'rules', 'proxy-groups', 'proxy-providers', 'dns']
          .some(key => key in parsed);
      }
    } catch {
      return false;
    }
  }
  if (/\.(ya?ml)$/i.test(filename)) {
    const hasSection = /^(?:mixed-port|port|socks-port|rules|proxy-groups|dns)\s*:/m.test(clean);
    const hasRulesOrGroups = /^(?:rules|proxy-groups)\s*:/m.test(clean);
    return hasSection && hasRulesOrGroups;
  }
  return false;
}

export function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return '0 B';
  const unit = Math.min(4, Math.floor(Math.log(value) / Math.log(1024)));
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  return `${(value / 1024 ** unit).toLocaleString(undefined, { maximumFractionDigits: 2 })} ${units[unit]}`;
}
