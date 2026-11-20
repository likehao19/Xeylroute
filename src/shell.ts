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

const THEME_KEY = 'xeylroute-theme';

export type ShellController = {
  getView(): ViewId;
  getSearch(): string;
  getTheme(): 'dark' | 'light';
  setTheme(theme: 'dark' | 'light'): void;
  switchView(view: ViewId, pushHistory?: boolean): void;
  onViewChange(cb: (view: ViewId) => void): void;
  onSearchChange(cb: (query: string) => void): void;
};

export function initShell(): ShellController {
  let currentView: ViewId = 'connect';
  let globalSearch = '';
  let theme: 'dark' | 'light' = localStorage.getItem(THEME_KEY) === 'light' ? 'light' : 'dark';
  const navHistory: ViewId[] = ['connect'];
  let navIndex = 0;

  const viewListeners: ((view: ViewId) => void)[] = [];
  const searchListeners: ((query: string) => void)[] = [];

  function applyTheme(next: 'dark' | 'light'): void {
    theme = next;
    document.documentElement.dataset.theme = theme;
    localStorage.setItem(THEME_KEY, theme);
    if (isTauri()) void invoke('window_set_theme', { theme }).catch(() => {});
    $('themeSvg').innerHTML = theme === 'dark'
      ? '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41"/>'
      : '<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>';
    document.querySelectorAll<HTMLElement>('#settingsThemeSeg button').forEach(b =>
      b.classList.toggle('active', b.dataset.setTheme === theme)
    );
  }

  function switchView(viewId: ViewId, pushHistory = true): void {
    closeMacMenu();
    currentView = viewId;
    if (pushHistory && navHistory[navIndex] !== viewId) {
      navHistory.splice(navIndex + 1);
      navHistory.push(viewId);
      navIndex = navHistory.length - 1;
    }
    document.querySelectorAll<HTMLElement>('#sidebarNav .nav-item').forEach(b =>
      b.classList.toggle('active', b.dataset.view === viewId)
    );
    document.querySelectorAll<HTMLElement>('.view').forEach(v =>
      v.classList.toggle('active', v.id === `view-${viewId}`)
    );
    $('stageTitle').textContent = VIEW_TITLES[viewId] || '连接';
    $<HTMLButtonElement>('navBackBtn').disabled = navIndex <= 0;
    $<HTMLButtonElement>('navForwardBtn').disabled = navIndex >= navHistory.length - 1;
    for (const cb of viewListeners) cb(viewId);
  }

  function toggleSidebar(): void {
    $('macWindow').classList.toggle('sidebar-collapsed');
  }

  $('sidebarCollapseBtn').addEventListener('click', toggleSidebar);
  $('sidebarExpandBtn').addEventListener('click', toggleSidebar);

  document.addEventListener('keydown', e => {
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
  $('navBackBtn').addEventListener('click', () => {
    if (navIndex > 0) {
      navIndex--;
      switchView(navHistory[navIndex], false);
    }
  });
  $('navForwardBtn').addEventListener('click', () => {
    if (navIndex < navHistory.length - 1) {
      navIndex++;
      switchView(navHistory[navIndex], false);
    }
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

  $('topThemeBtn').addEventListener('click', () => applyTheme(theme === 'dark' ? 'light' : 'dark'));
  $('settingsThemeSeg').addEventListener('click', e => {
    const b = (e.target as HTMLElement).closest<HTMLElement>('[data-set-theme]');
    if (b?.dataset.setTheme === 'dark' || b?.dataset.setTheme === 'light') {
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
