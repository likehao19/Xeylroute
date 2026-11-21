import { $, closeSheet, confirmSheet, esc, openSheet } from './ui-kit';

export type RuleBatchAction = 'enable' | 'disable' | 'delete';

export function openRuleBatch(
  rows: { title: string; detail: string; enabled: boolean | null; count?: number }[],
  apply: (action: RuleBatchAction, selected: number[]) => void,
): void {
  openSheet({
    title: '批量管理规则',
    size: 'wide',
    bodyHtml: `
      <label class="batch-select-all"><input type="checkbox" id="batchAll">全选当前列表<span id="batchCount"></span></label>
      <div class="sheet-picker batch-rule-list">${rows.map((row, i) => `
        <label class="sheet-picker-row">
          <input type="checkbox" data-batch-row="${i}">
          <span class="picker-meta"><strong>${esc(row.title)}</strong><small title="${esc(row.detail)}">${esc(row.detail)}</small></span>
          <small>${row.enabled === null ? '部分启用' : row.enabled ? '启用' : '停用'}</small>
        </label>`).join('')}</div>`,
    actionsSplit: true,
    actionsHtml: `<button type="button" class="glass-btn-soft" id="batchCancel">取消</button>
      <div class="sheet-actions-group">
        <button type="button" class="glass-btn-soft" data-batch-action="enable">启用</button>
        <button type="button" class="glass-btn-soft" data-batch-action="disable">停用</button>
        <button type="button" class="glass-btn-danger" data-batch-action="delete">删除</button>
      </div>`,
  });
  const all = $<HTMLInputElement>('batchAll');
  const checks = [...$('sheetContent').querySelectorAll<HTMLInputElement>('[data-batch-row]')];
  const buttons = $('sheetContent').querySelectorAll<HTMLButtonElement>('[data-batch-action]');
  function sync(): void {
    const count = checks.filter(c => c.checked).length;
    all.checked = count > 0 && count === checks.length;
    all.indeterminate = count > 0 && !all.checked;
    $('batchCount').textContent = `已选 ${count} / ${checks.length}`;
    buttons.forEach(b => { b.disabled = count === 0; });
  }
  all.onchange = () => { checks.forEach(c => { c.checked = all.checked; }); sync(); };
  $('sheetContent').querySelector('.batch-rule-list')!.addEventListener('change', sync);
  $('batchCancel').onclick = closeSheet;
  buttons.forEach(b => { b.onclick = async () => {
    const selected = checks.filter(c => c.checked).map(c => Number(c.dataset.batchRow));
    const action = b.dataset.batchAction as RuleBatchAction;
    const count = selected.reduce((sum, i) => sum + (rows[i].count ?? 1), 0);
    if (action === 'delete' && !await confirmSheet({
      title: `删除 ${count} 条规则？`, message: '这些规则将从当前配置中移除。', confirmLabel: '删除', danger: true,
    })) return;
    closeSheet();
    apply(action, selected);
  }; });
  sync();
}
