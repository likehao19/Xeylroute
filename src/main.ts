import { confirmDialog, waitForLocalCoreStart } from './prototype.js';
import { mountProfileEditor } from './profile-editor';

type CoreStatus = {
  available: boolean;
  configured: boolean;
  running: boolean;
  tun: boolean;
  systemProxy: boolean;
};

type Control = { control: 'power' | 'core' | 'system' | 'tun'; enabled: boolean; fromTray?: boolean };

const host = window as Window & {
  __TAURI__?: { core: { invoke<T>(command: string, args?: Record<string, unknown>): Promise<T> } };
};

if (host.__TAURI__) {
  const { invoke } = host.__TAURI__.core;
  const fileInput = document.querySelector<HTMLInputElement>('#nodeFile')!;
  const importButton = document.querySelector<HTMLButtonElement>('#importFile')!;
  const importStatus = document.getElementById('importStatus')!;
  let busy = false;

  mountProfileEditor(invoke);

  function notify(message: string) {
    document.dispatchEvent(new CustomEvent('routepilot:desktop-message', { detail: message }));
  }

  async function updateNetwork({ control, enabled }: Control) {
    await waitForLocalCoreStart()?.catch(() => {});
    const current = await invoke<CoreStatus>('core_status');
    if (enabled && !current.available) throw new Error('缺少代理组件，请先安装。');
    if (enabled && !current.configured) throw new Error('请先在订阅页添加订阅或导入配置。');
    if (control === 'tun') {
      if (enabled === current.tun) return;
      if (enabled && !await confirmDialog('TUN 会接管系统网络流量。确认后，Windows 会请求授权启动 TUN 后台，RoutePilot 窗口继续以普通权限运行。', {
        title: '开启全局 TUN', confirmLabel: '继续',
      })) return;
      try {
        if (current.running) await invoke('stop_local_core');
        if (enabled) await invoke('start_global_tun');
        else await invoke('start_local_core');
        if (current.systemProxy) await invoke('set_system_proxy', { enabled: true });
      } catch (error) {
        if (current.running) {
          try {
            const status = await invoke<CoreStatus>('core_status');
            if (status.running && status.tun !== current.tun) await invoke('stop_local_core');
            if (current.tun && (!status.running || !status.tun)) {
              if (!await confirmDialog('未能切换到普通代理。是否重新开启原来的 TUN？Windows 可能再次请求授权。', {
                title: '恢复原 TUN 连接', confirmLabel: '恢复 TUN',
              })) throw new Error('已取消恢复 TUN。');
              await invoke('start_global_tun');
            } else if (!current.tun && (!status.running || status.tun)) {
              await invoke('start_local_core');
            }
            if (current.systemProxy) await invoke('set_system_proxy', { enabled: true });
          } catch (restoreError) {
            throw new Error(String(error) + '\n原代理未能恢复。' + String(restoreError));
          }
          throw new Error(String(error) + '\n已恢复切换前的代理状态。');
        }
        throw error;
      }
      return;
    }

    if (control === 'core' || (control === 'power' && !enabled)) {
      if (enabled && !current.running) await invoke('start_local_core');
      if (!enabled && current.running) await invoke('stop_local_core');
      return;
    }
    if (enabled && !current.running) await invoke('start_local_core');
    try {
      if (current.systemProxy !== enabled) await invoke('set_system_proxy', { enabled });
    } catch (error) {
      if (control === 'power' && !current.running) {
        try {
          await invoke('stop_local_core');
        } catch (cleanupError) {
          throw new Error(String(error) + '\n代理服务停止失败。' + String(cleanupError));
        }
      }
      throw error;
    }
  }

  document.addEventListener('routepilot:network-control', async event => {
    if (busy) return;
    const action = (event as CustomEvent<Control>).detail;
    busy = true;
    document.dispatchEvent(new CustomEvent('routepilot:network-updating', { detail: true }));
    try {
      await updateNetwork(action);
    } catch (error) {
      if (action.fromTray) await invoke('show_routepilot').catch(() => {});
      notify(String(error).replace(/^Error: /, ''));
    } finally {
      busy = false;
      document.dispatchEvent(new CustomEvent('routepilot:network-updating', { detail: false }));
      document.dispatchEvent(new Event('routepilot:core-state'));
    }
  });

  fileInput.accept = '.yaml,.yml,.txt,.conf,.json,.b64,.base64';
  importButton.onclick = () => fileInput.click();
  fileInput.onchange = async () => {
    const file = fileInput.files?.[0];
    fileInput.value = '';
    if (!file || busy) return;
    if (file.size > 4 * 1024 * 1024) {
      importStatus.textContent = '配置文件不得超过 4 MiB。';
      return;
    }
    busy = true;
    try {
      const content = await file.text();
      let fullProfile = false;
      if (file.name.toLowerCase().endsWith('.json')) {
        const config: unknown = JSON.parse(content.replace(/^\uFEFF/, ''));
        fullProfile = !!config && typeof config === 'object'
          && ['port', 'mixed-port', 'socks-port', 'rules', 'proxy-groups', 'proxy-providers'].some(key => key in config);
      }
      if (fullProfile) {
        const status = await invoke<CoreStatus>('core_status');
        if (status.running) throw new Error('请先关闭首页的接管总开关，再替换完整配置。');
        if (status.configured && !await confirmDialog('导入本地配置会替换已有配置。', {
          title: '替换本地配置', confirmLabel: '导入',
        })) return;
        await invoke('import_core_config', { content });
        importStatus.textContent = '本地配置已导入。';
        document.dispatchEvent(new Event('routepilot:core-state'));
      } else {
        await invoke('import_subscription_file', { name: file.name, content });
        importStatus.textContent = '本地订阅已添加。';
        document.dispatchEvent(new Event('routepilot:subscription-added'));
      }
    } catch (error) {
      importStatus.textContent = String(error).replace(/^Error: /, '');
    } finally {
      busy = false;
    }
  };
}
