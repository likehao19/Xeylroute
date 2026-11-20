import { $, closeMacMenu, closeSheet, openSheet } from './ui-kit';

import { invoke, isTauri } from './tauri-bridge';

export type ViewId = 'connect' | 'nodes' | 'split' | 'logs' | 'subs' | 'settings';

const VIEW_TITLES: Record<ViewId, string> = {
  connect: '连接',
  nodes: '代理组与节点',
  split: '分流与程序',
  logs: '连接记录',
  subs: '订阅管理',
  settings: '网络与设置',
};

export type ThemeChoice = 'light' | 'dark' | 'auto';
const THEME_KEY = 'xeylroute-theme';

export type ShellController = {
  getView(): ViewId;
  getSearch(): string;
  getTheme(): ThemeChoice;
  setTheme(theme: ThemeChoice): void;
  switchView(view: ViewId): void;
  onViewChange(cb: (view: ViewId) => void): void;
  onSearchChange(cb: (query: string) => void): void;
};

export function initShell(): ShellController {
  let currentView: ViewId = 'connect';
  let globalSearch = '';
  const savedTheme = localStorage.getItem(THEME_KEY);
  let theme: ThemeChoice = savedTheme === 'light' || savedTheme === 'dark' ? savedTheme : 'auto';
  const systemDark = matchMedia('(prefers-color-scheme: dark)');

  const viewListeners: ((view: ViewId) => void)[] = [];
  const searchListeners: ((query: string) => void)[] = [];

  function renderTheme(): void {
    document.documentElement.dataset.theme = theme === 'auto' ? (systemDark.matches ? 'dark' : 'light') : theme;
    document.querySelectorAll<HTMLButtonElement>('#settingsThemeSeg button').forEach(button => {
      const selected = button.dataset.setTheme === theme;
      button.classList.toggle('active', selected);
      button.setAttribute('aria-pressed', String(selected));
    });
  }
  function applyTheme(next: ThemeChoice): void {
    theme = next;
    localStorage.setItem(THEME_KEY, theme);
    if (isTauri()) void invoke('window_set_theme', { theme: theme === 'auto' ? null : theme }).catch(() => {});
    renderTheme();
  }
  systemDark.addEventListener('change', () => { if (theme === 'auto') renderTheme(); });

  function switchView(viewId: ViewId): void {
    closeMacMenu();
    currentView = viewId;
    document.querySelectorAll<HTMLElement>('#sidebarNav .nav-item').forEach(b =>
      b.classList.toggle('active', b.dataset.view === viewId)
    );
    document.querySelectorAll<HTMLElement>('.view').forEach(v =>
      v.classList.toggle('active', v.id === `view-${viewId}`)
    );
    $('stageTitle').textContent = VIEW_TITLES[viewId] || '连接';
    for (const cb of viewListeners) cb(viewId);
  }

  function toggleSidebar(): void {
    $('macWindow').classList.toggle('sidebar-collapsed');
  }

  $('sidebarCollapseBtn').addEventListener('click', toggleSidebar);
  $('sidebarExpandBtn').addEventListener('click', toggleSidebar);

  document.addEventListener('keydown', e => {
    if ($('macWindow').inert && e.key !== 'Escape') return;
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
      e.preventDefault();
      $('macWindow').classList.remove('sidebar-collapsed');
      const input = $<HTMLInputElement>('globalSearchInput');
      input.focus();
      input.select();
    } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') {
      e.preventDefault();
      toggleSidebar();
    } else if (e.key === 'Escape') {
      closeMacMenu();
      closeSheet();
    }
  });

  $('sidebarNav').addEventListener('click', e => {
    const b = (e.target as HTMLElement).closest<HTMLElement>('[data-view]');
    if (b?.dataset.view) switchView(b.dataset.view as ViewId);
  });
  $('goAllNodesBtn').addEventListener('click', () => switchView('nodes'));
  $('goSplitBtn').addEventListener('click', () => switchView('split'));

  $('globalSearchInput').addEventListener('input', e => {
    globalSearch = (e.target as HTMLInputElement).value;
    $('searchWrap').classList.toggle('has-value', globalSearch.length > 0);
    for (const cb of searchListeners) cb(globalSearch);
  });
  $('searchClearBtn').addEventListener('click', () => {
    globalSearch = '';
    $<HTMLInputElement>('globalSearchInput').value = '';
    $('searchWrap').classList.remove('has-value');
    for (const cb of searchListeners) cb(globalSearch);
  });

  $('settingsThemeSeg').addEventListener('click', e => {
    const b = (e.target as HTMLElement).closest<HTMLElement>('[data-set-theme]');
    if (b?.dataset.setTheme === 'dark' || b?.dataset.setTheme === 'light' || b?.dataset.setTheme === 'auto') {
      applyTheme(b.dataset.setTheme);
    }
  });

  const isMac = /mac/i.test(`${navigator.platform || ''} ${navigator.userAgent || ''}`);
  const modKey = isMac ? '⌘' : 'Ctrl+';
  const kbdSearch = document.querySelector<HTMLElement>('#searchWrap .kbd-hint');
  if (kbdSearch) kbdSearch.textContent = isMac ? '⌘K' : 'Ctrl K';
  $('sidebarCollapseBtn').dataset.tip = `隐藏边栏 (${modKey}S)`;
  $('sidebarExpandBtn').dataset.tip = `显示边栏 (${modKey}S)`;

  $('helpInfoBtn').addEventListener('click', () => {
    openSheet({
      title: '路由优先级与快捷键',
      subtitle: 'Xeylroute 跨平台分流策略说明',
      iconHtml: `<span class="sq md blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><circle cx="12" cy="12" r="9"/><path d="M12 16v-4"/><path d="M12 8h.01"/></svg></span>`,
      bodyHtml: `
        <div style="font-size:12.5px;color:var(--ink-2);line-height:1.68;display:grid;gap:10px">
          <div><strong style="color:var(--ink)">规则优先级：</strong>显式 REJECT &gt; 显式 DIRECT &gt; 进程 &gt; 软件 &gt; 精确域名 &gt; 通配域名 &gt; 默认出口</div>
          <div><strong style="color:var(--ink)">Scoped TUN：</strong>${isTauri() ? '桌面端支持全局 TUN。按软件指定出口请使用分流规则。' : '规则模式下仅接管勾选 TUN 的分组或程序。'}</div>
          <div><strong style="color:var(--ink)">导入支持：</strong>HTTPS 订阅链接、单/多条分享链接（vless / trojan / ss / vmess / hy2 / tuic / Base64），以及第三方 YAML / JSON 完整配置。</div>
          <div><strong style="color:var(--ink)">快捷键：</strong><kbd class="kbd-hint">${modKey}K</kbd> 全局搜索 · <kbd class="kbd-hint">${modKey}S</kbd> 收起/展开边栏 · <kbd class="kbd-hint">Esc</kbd> 关闭浮层</div>
        </div>
      `,
      actionsHtml: `<button type="button" class="glass-btn-primary compact lg-track" id="sheetCloseHelp">完成</button>`,
    });
    $('sheetCloseHelp').onclick = closeSheet;
  });

  applyTheme(theme);

  return {
    getView: () => currentView,
    getSearch: () => globalSearch,
    getTheme: () => theme,
    setTheme: applyTheme,
    switchView,
    onViewChange: cb => { viewListeners.push(cb); },
    onSearchChange: cb => { searchListeners.push(cb); },
  };
}
