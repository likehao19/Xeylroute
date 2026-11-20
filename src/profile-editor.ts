import { tauriApi } from './tauri-bridge';
import { $, closeSheet, isSheetOpen, notify, openSheet } from './ui-kit';

export type DocumentMode = 'new' | 'file' | 'remote' | 'copy' | 'config';
const titles = {
  new: '新建本地 YAML', file: '编辑本地订阅', remote: '编辑远程订阅',
  copy: '另存为本地 YAML', config: '编辑完整配置',
};
const template = '# 将示例地址和端口替换为自己的代理服务\nproxies:\n  - name: 我的代理\n    type: socks5\n    server: 127.0.0.1\n    port: 1080\n';

function bindLineNumbers(input: HTMLTextAreaElement): void {
  const numbers = $('docNumbers');
  const count = $('docCount');
  const lineHeight = parseFloat(getComputedStyle(input).lineHeight);
  let lines = 1;
  function scroll() {
    const offset = Math.max(0, input.scrollTop);
    const first = Math.floor(offset / lineHeight);
    // Cover the entire sheet even if the user resizes the window between scroll events.
    const visible = Math.min(lines - first, Math.ceil(680 / lineHeight) + 2);
    numbers.textContent = Array.from({ length: visible }, (_, i) => first + i + 1).join('\n');
    numbers.style.transform = `translateY(-${offset % lineHeight}px)`;
  }
  function update() {
    const value = input.value;
    lines = 1;
    for (let pos = value.indexOf('\n'); pos !== -1; pos = value.indexOf('\n', pos + 1)) lines++;
    count.textContent = `${lines.toLocaleString()} 行`;
    numbers.parentElement!.style.width = `${String(lines).length + 3}ch`;
    scroll();
  }
  input.addEventListener('input', update);
  input.addEventListener('scroll', scroll, { passive: true });
  update();
  input.classList.toggle('short-document', lines <= 12);
}

export async function openProfileEditor(mode: DocumentMode, name: string, saved: () => Promise<void>): Promise<void> {
  const create = mode === 'new' || mode === 'copy';
  const remote = mode === 'remote';
  openSheet({
    title: titles[mode], subtitle: name || undefined, size: remote ? 'default' : 'wide',
    iconHtml: remote ? undefined : '<span class="doc-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3.5h8l4.5 4.5v12.5H6zM14 3.5V8h4.5M10.5 11.5l-2 2 2 2m3-4 2 2-2 2"/></svg></span>',
    bodyHtml: `
      ${create ? '<div class="doc-name"><label for="docName">文件名</label><input class="sheet-input" id="docName" autocomplete="off" spellcheck="false"></div>' : ''}
      ${remote ? '<div class="sheet-field"><label for="docText">订阅地址</label><input class="sheet-input" id="docText" type="url" spellcheck="false" autocomplete="off"></div>' : `
        <div class="doc-editor">
          <div class="doc-bar"><label for="docText">YAML 源码</label><span id="docCount"></span></div>
          <div class="doc-code">
            <div class="doc-gutter" aria-hidden="true"><pre id="docNumbers"></pre></div>
            <textarea id="docText" wrap="off" spellcheck="false" autocomplete="off" autocapitalize="off" autocorrect="off"></textarea>
          </div>
        </div>`}
      ${mode === 'config' ? '<p class="sheet-hint">包含当前保存的所有订阅与规则。修改完整配置需要先停止内核。</p>' : ''}
      <p role="alert" id="docError" class="sheet-error"></p>`,
    actionsSplit: remote,
    actionsHtml: `${remote ? '<button type="button" class="glass-btn-soft" id="copyDoc">编辑本地副本…</button>' : ''}
      <div class="sheet-actions-group"><button type="button" class="glass-btn-soft" id="docCancel">取消</button>
      <button type="button" class="glass-btn-primary compact" id="docSave" disabled>${mode === 'copy' ? '创建副本' : create ? '创建' : '保存'}</button></div>`,
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
    if (input instanceof HTMLTextAreaElement) {
      input.setSelectionRange(0, 0);
      input.scrollTop = input.scrollLeft = 0;
      bindLineNumbers(input);
    }
    const sync = () => { submit.disabled = !input.value.trim() || (create ? !filename?.value.trim() : input.value === original); };
    input.oninput = sync;
    if (filename) filename.oninput = sync;
    sync();
    (filename || input).focus({ preventScroll: true });
    if (filename) filename.setSelectionRange(0, filename.value.replace(/\.yaml$/i, '').length);
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
