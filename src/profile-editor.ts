import { tauriApi } from './tauri-bridge';
import { $, closeSheet, isSheetOpen, notify, openSheet } from './ui-kit';

export type DocumentMode = 'new' | 'file' | 'remote' | 'copy' | 'config';
const titles = {
  new: '新建本地 YAML', file: '编辑本地订阅', remote: '编辑远程订阅',
  copy: '另存为本地 YAML', config: '编辑完整配置',
};
const template = '# 将示例地址和端口替换为自己的代理服务\nproxies:\n  - name: 我的代理\n    type: socks5\n    server: 127.0.0.1\n    port: 1080\n';

export async function openProfileEditor(mode: DocumentMode, name: string, saved: () => Promise<void>): Promise<void> {
  const create = mode === 'new' || mode === 'copy';
  const remote = mode === 'remote';
  openSheet({
    title: titles[mode], subtitle: name || undefined, size: remote ? 'default' : 'wide',
    bodyHtml: `
      ${create ? '<div class="sheet-field"><label for="docName">文件名</label><input class="sheet-input" id="docName"></div>' : ''}
      <div class="sheet-field"><label for="docText">${remote ? '订阅地址' : 'YAML 内容'}</label>
        ${remote ? '<input class="sheet-input" id="docText" type="url" spellcheck="false" autocomplete="off">' : '<textarea class="sheet-textarea yaml-editor" id="docText" wrap="off" spellcheck="false" autocomplete="off"></textarea>'}
      </div>
      ${mode === 'config' ? '<p class="sheet-hint">包含当前保存的所有订阅与规则。修改完整配置需要先停止内核。</p>' : ''}
      <p role="alert" id="docError" class="sheet-error"></p>`,
    actionsSplit: remote,
    actionsHtml: `${remote ? '<button type="button" class="glass-btn-soft" id="copyDoc">编辑本地副本…</button>' : ''}
      <div class="sheet-actions-group"><button type="button" class="glass-btn-soft" id="docCancel">取消</button>
      <button type="button" class="glass-btn-primary compact" id="docSave" disabled>${create ? '创建' : '保存'}</button></div>`,
  });
  const input = $<HTMLTextAreaElement | HTMLInputElement>('docText');
  const filename = document.querySelector<HTMLInputElement>('#docName');
  const submit = $<HTMLButtonElement>('docSave');
  const error = $('docError');
  const active = () => submit.isConnected && isSheetOpen();
  $('docCancel').onclick = closeSheet;
  if (remote) $('copyDoc').onclick = () => { void openProfileEditor('copy', name, saved); };
  if (filename) filename.value = name ? name + ' 副本.yaml' : '自建.yaml';
  input.disabled = true;
  try {
    const original = mode === 'new' ? template : await tauriApi.readProfileDocument(name || null, mode === 'copy');
    if (!active()) return;
    input.value = original;
    input.disabled = false;
    const sync = () => { submit.disabled = !input.value.trim() || (create ? !filename?.value.trim() : input.value === original); };
    input.oninput = sync;
    if (filename) filename.oninput = sync;
    sync();
    (filename || input).focus();
    submit.onclick = async () => {
      submit.disabled = input.disabled = true;
      if (filename) filename.disabled = true;
      error.textContent = '';
      try {
        if (remote) await tauriApi.editSubscriptionUrl(name, original, input.value.trim());
        else if (mode === 'config') await tauriApi.importCoreConfig(input.value, original);
        else await tauriApi.importSubscriptionFile(filename?.value.trim() || name, input.value, {
          expected: create ? undefined : original, authored: true,
        });
        if (active()) closeSheet();
        await saved();
        notify(create ? '已创建本地订阅' : '修改已保存');
      } catch (err) {
        error.textContent = String(err);
        input.disabled = false;
        if (filename) filename.disabled = false;
        sync();
      }
    };
  } catch (err) {
    error.textContent = String(err);
  }
}
