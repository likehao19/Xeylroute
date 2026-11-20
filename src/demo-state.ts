export type DemoProcess = {
  pid: number;
  name: string;
  exe: string;
  path: string;
  tone: string;
  glyph: string;
  app: boolean;
  threads: number;
};

export type DemoSiteCategory = [string, { n: string; h: string; ms: number | null; status?: number; c: string }[]];

export const DEMO_RUNNING: DemoProcess[] = [
  { pid: 9432, name: 'Codex', exe: 'Codex.exe', path: 'C:\\Apps\\Codex\\Codex.exe', tone: 'indigo', glyph: '<path d="M12 3 20 7.5v9L12 21 4 16.5v-9L12 3Z"/><path d="M12 12 20 7.5M12 12v9M12 12 4 7.5"/>', app: true, threads: 28 },
  { pid: 9640, name: 'Claude', exe: 'Claude.exe', path: 'C:\\Apps\\Claude\\Claude.exe', tone: 'orange', glyph: '<path d="M12 3v18M3 12h18M5.6 5.6l12.8 12.8M18.4 5.6 5.6 18.4"/>', app: true, threads: 34 },
  { pid: 6124, name: 'Chrome', exe: 'chrome.exe', path: 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', tone: 'blue', glyph: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3.5"/><path d="M12 8.5h8.2M8.8 13.8 4.8 6.8M15 14l-4 7"/>', app: true, threads: 64 },
  { pid: 7380, name: 'VS Code', exe: 'Code.exe', path: 'C:\\Users\\User\\AppData\\Local\\Programs\\VS Code\\Code.exe', tone: 'cyan', glyph: '<path d="m16 18 6-6-6-6M8 6l-6 6 6 6"/>', app: true, threads: 42 },
  { pid: 8512, name: '微信', exe: 'WeChat.exe', path: 'C:\\Program Files\\Tencent\\WeChat\\WeChat.exe', tone: 'green', glyph: '<path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"/>', app: true, threads: 51 },
  { pid: 13280, name: 'Node.js', exe: 'node.exe', path: 'C:\\Program Files\\nodejs\\node.exe', tone: 'gray', glyph: '<path d="m4 17 6-6-6-6M12 19h8"/>', app: false, threads: 12 },
  { pid: 14308, name: 'Python', exe: 'python.exe', path: 'C:\\Python313\\python.exe', tone: 'purple', glyph: '<path d="m4 17 6-6-6-6M12 19h8"/>', app: false, threads: 8 },
];

export function createSiteCatalog(isLive: boolean): DemoSiteCategory[] {
  const ms = (v: number) => (isLive ? null : v);
  return [
    ['搜索与资讯', [
      { n: 'Google', h: 'google.com', ms: ms(34), c: 'blue' },
      { n: '维基百科', h: 'wikipedia.org', ms: ms(48), c: 'gray' },
      { n: '知乎', h: 'zhihu.com', ms: ms(22), c: 'cyan' },
    ]],
    ['开发与 AI', [
      { n: 'GitHub', h: 'github.com', ms: ms(41), c: 'indigo' },
      { n: 'Claude', h: 'claude.ai', ms: ms(56), c: 'orange' },
      { n: 'ChatGPT', h: 'chatgpt.com', ms: ms(63), c: 'green' },
    ]],
    ['影音娱乐', [
      { n: 'YouTube', h: 'youtube.com', ms: ms(44), c: 'red' },
      { n: 'Spotify', h: 'spotify.com', ms: ms(49), c: 'green' },
      { n: '哔哩哔哩', h: 'bilibili.com', ms: ms(19), c: 'cyan' },
    ]],
    ['办公社区', [
      { n: 'Notion', h: 'notion.so', ms: ms(67), c: 'gray' },
      { n: 'Slack', h: 'slack.com', ms: ms(58), c: 'purple' },
      { n: '飞书', h: 'feishu.cn', ms: ms(21), c: 'blue' },
    ]],
  ];
}

export type DemoState = {
  theme: 'dark' | 'light';
  connected: boolean;
  elapsed: number;
  mode: 'rule' | 'global' | 'direct';
  systemProxy: boolean;
  tun: boolean;
  tunScope: 'all' | 'selected';
  fallback: boolean;
  selectedNodeId: string;
  defaultRuleExit: string;
  ports: { mixed: number | null; http: number; socks: number };
  nodes: {
    id: string;
    name: string;
    tag: string;
    flag: string;
    proto: string;
    delay: number;
    speed: number;
    source: string;
    ip: string;
    retired?: boolean;
  }[];
  groups: {
    id: string;
    name: string;
    type: string;
    exit: string;
    tun: boolean;
    on: boolean;
  }[];
  rules: {
    id: string;
    kind: 'app' | 'website' | 'process';
    label: string;
    value: string;
    path?: string;
    group: string;
    exit: string;
    tun: 'inherit' | 'on' | 'off';
    on: boolean;
  }[];
  subscriptions: {
    id: string;
    name: string;
    kind: string;
    url: string;
    used: number;
    quota: number;
    expires: string;
    updated: string;
    active: boolean;
  }[];
  logs: {
    time: string;
    app: string;
    host: string;
    capture: string;
    action: string;
    match: string;
    reason: string;
    tone: string;
  }[];
};

export const DEMO_STORAGE_KEY = 'xeylroute-macos27-v2';

export const DEFAULT_DEMO_STATE: DemoState = {
  theme: 'dark',
  connected: true,
  elapsed: 2 * 3600 + 46 * 60 + 18,
  mode: 'rule',
  systemProxy: true,
  tun: false,
  tunScope: 'all',
  fallback: true,
  selectedNodeId: 'sg-01',
  defaultRuleExit: 'global-follow',
  ports: { mixed: 7890, http: 9870, socks: 7891 },
  nodes: [
    { id: 'sg-01', name: '新加坡 01', tag: 'IEPL 专线', flag: 'sg', proto: 'Hysteria2', delay: 38, speed: 148.5, source: '个人订阅', ip: '103.214.168.42' },
    { id: 'hk-02', name: '香港 02', tag: 'BGP 极速', flag: 'hk', proto: 'Trojan', delay: 26, speed: 186.2, source: '个人订阅', ip: '45.11.57.90' },
    { id: 'jp-01', name: '日本 01', tag: 'AI 解锁', flag: 'jp', proto: 'Hysteria2', delay: 62, speed: 132.0, source: '个人订阅', ip: '139.162.88.14' },
    { id: 'us-01', name: '美国 01', tag: '流媒体', flag: 'us', proto: 'VLESS', delay: 153, speed: 84.6, source: '个人订阅', ip: '104.28.14.79' },
    { id: 'de-01', name: '德国 01', tag: '欧洲骨干', flag: 'de', proto: 'Trojan', delay: 188, speed: 64.1, source: '个人订阅', ip: '185.220.101.8' },
    { id: 'hk-01', name: '香港 01', tag: 'IEPL 专线', flag: 'hk', proto: 'Hysteria2', delay: 29, speed: 179.4, source: '个人订阅', ip: '45.11.57.12' },
    { id: 'sg-02', name: '新加坡 02', tag: 'BGP 高速', flag: 'sg', proto: 'VLESS', delay: 44, speed: 136.8, source: '个人订阅', ip: '103.214.168.88' },
    { id: 'jp-02', name: '日本 02', tag: '东京直连', flag: 'jp', proto: 'Trojan', delay: 68, speed: 118.5, source: '个人订阅', ip: '139.162.89.21' },
    { id: 'kr-01', name: '韩国 01', tag: '首尔低延', flag: 'kr', proto: 'Hysteria2', delay: 54, speed: 129.0, source: '个人订阅', ip: '211.45.60.19' },
    { id: 'us-02', name: '美国 02', tag: '西海岸', flag: 'us', proto: 'Hysteria2', delay: 142, speed: 92.3, source: '备用订阅', ip: '104.28.19.102' },
    { id: 'gb-01', name: '英国 01', tag: '伦敦节点', flag: 'gb', proto: 'VLESS', delay: 176, speed: 71.8, source: '备用订阅', ip: '51.140.22.9' },
    { id: 'de-02', name: '德国 02', tag: '法兰克福', flag: 'de', proto: 'VLESS', delay: 192, speed: 58.9, source: '备用订阅', ip: '185.220.102.4' },
  ],
  groups: [
    { id: 'g-dev', name: '开发工具', type: 'Selector', exit: 'global-follow', tun: false, on: true },
    { id: 'g-ai', name: 'AI 服务', type: 'Selector', exit: 'jp-01', tun: true, on: true },
    { id: 'g-web', name: '常用网站', type: 'URLTest', exit: 'hk-02', tun: false, on: true },
  ],
  rules: [
    { id: 'r-codex', kind: 'app', label: 'Codex', value: 'Codex.exe', path: 'C:\\Apps\\Codex\\Codex.exe', group: 'g-dev', exit: 'global-follow', tun: 'inherit', on: true },
    { id: 'r-claude', kind: 'app', label: 'Claude', value: 'Claude.exe', path: 'C:\\Apps\\Claude\\Claude.exe', group: 'g-ai', exit: 'jp-01', tun: 'on', on: true },
    { id: 'r-chrome', kind: 'app', label: 'Chrome', value: 'chrome.exe', path: 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', group: 'g-web', exit: 'domain-rules', tun: 'inherit', on: true },
    { id: 'r-vscode', kind: 'app', label: 'VS Code', value: 'Code.exe', path: 'C:\\Users\\User\\AppData\\Local\\Programs\\VS Code\\Code.exe', group: 'g-dev', exit: 'global-follow', tun: 'inherit', on: true },
    { id: 'r-gh', kind: 'website', label: 'GitHub', value: '*.github.com', group: 'g-dev', exit: '', tun: 'inherit', on: true },
    { id: 'r-cn', kind: 'website', label: '国内直连', value: '*.cn', group: '', exit: 'direct', tun: 'off', on: true },
    { id: 'r-ads', kind: 'website', label: '广告追踪', value: '*.doubleclick.net', group: '', exit: 'reject', tun: 'off', on: true },
  ],
  subscriptions: [
    { id: 's-1', name: '个人订阅', kind: 'HTTPS 远程订阅', url: 'https://sub.example.net/v2/clash?token=demo', used: 184.2, quota: 500, expires: '2026-12-31', updated: '10 分钟前', active: true },
    { id: 's-2', name: '备用订阅', kind: '本地 YAML', url: 'backup-nodes-2026.yaml', used: 22.8, quota: 200, expires: '长期有效', updated: '昨天 21:40', active: false },
  ],
  logs: [
    { time: '22:18:41', app: 'Codex.exe', host: 'api.openai.com', capture: '系统代理', action: '新加坡 01', match: 'Codex · 开发工具', reason: '按软件长期规则命中共享出口', tone: 'blue' },
    { time: '22:18:22', app: 'Claude.exe', host: 'api.anthropic.com', capture: '指定目标 TUN', action: '日本 01', match: 'Claude · AI 服务', reason: '软件独立出口覆盖组设置', tone: 'blue' },
    { time: '22:17:58', app: 'chrome.exe', host: 'github.com', capture: '系统代理', action: '新加坡 01', match: 'GitHub · 开发工具', reason: '按域名规则匹配 *.github.com', tone: 'blue' },
    { time: '22:17:19', app: 'WeChat.exe', host: 'weixin.qq.com', capture: '系统代理', action: 'DIRECT', match: '国内直连', reason: '显式 DIRECT 规则优先直连', tone: 'green' },
    { time: '22:16:45', app: 'chrome.exe', host: 'ad.doubleclick.net', capture: '系统代理', action: 'REJECT', match: '广告追踪', reason: '显式 REJECT 策略最高优先阻断', tone: 'red' },
  ],
};
