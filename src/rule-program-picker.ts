import { renderProgramIcon } from './icons';
import type { GroupedRunningApp } from './tauri-bridge';
import { $, esc } from './ui-kit';

export function bindRuleProgramPicker(program: HTMLInputElement, multiple: boolean) {
  const list = $('ruleAppList');
  const search = $<HTMLInputElement>('ruleAppSearch');
  const selectedPaths = new Set<string>();
  let apps: GroupedRunningApp[] = [];
  let emptyMessage = '';

  function syncSelection(): void {
    const selected = new Set(selectedPaths);
    if (program.value.trim()) selected.add(program.value.trim());
    $('ruleAppCount').textContent = selected.size ? `已选 ${selected.size} 个文件` : '';
    list.querySelectorAll<HTMLInputElement>('input').forEach(input => {
      const app = apps[Number(input.dataset.app)];
      if (input.dataset.file !== undefined) {
        input.checked = selected.has(app.paths[Number(input.dataset.file)]);
      } else {
        input.checked = selected.has(app.path);
      }
    });
  }

  function filter(): void {
    const query = search.value.trim().toLowerCase();
    let visible = 0;
    Array.from(list.children).forEach((row, index) => {
      const app = apps[index];
      const nameMatch = app.name.toLowerCase().includes(query);
      const matches = app.paths.some(path => path.toLowerCase().includes(query));
      (row as HTMLElement).hidden = !nameMatch && !matches;
      if (nameMatch || matches) visible++;
      const details = row.querySelector('details')!;
      if (query) {
        if (details.dataset.wasOpen === undefined) details.dataset.wasOpen = String(details.open);
        details.open = !nameMatch && matches;
      } else if (details.dataset.wasOpen !== undefined) {
        details.open = details.dataset.wasOpen === 'true';
        delete details.dataset.wasOpen;
      }
      row.querySelectorAll<HTMLElement>('.rule-program-file').forEach((file, i) => {
        file.hidden = !nameMatch && !app.paths[i].toLowerCase().includes(query);
      });
    });
    const empty = $('ruleAppEmpty');
    empty.hidden = visible > 0;
    empty.textContent = apps.length ? '没有匹配的软件或路径' : emptyMessage;
  }

  function refresh(items: GroupedRunningApp[], status: string): void {
    if (!list.isConnected) return;
    apps = items.filter(app => app.path);
    emptyMessage = status;
    list.innerHTML = apps.map((app, i) => `
      <div class="rule-program-row">
        <input type="checkbox" data-app="${i}" aria-label="${esc('选择主程序：' + app.name)}">
        <details><summary>${renderProgramIcon(app.icon, app.name)}
          <strong>${esc(app.name)}</strong><small>主程序${app.paths.length > 1 ? ` · ${app.paths.length - 1} 个辅助程序` : ''}</small><span class="rule-disclosure" aria-hidden="true">›</span>
        </summary>
        ${app.paths.map((path, j) => `<label class="rule-program-file" title="${esc(path)}">
          <input type="checkbox" data-app="${i}" data-file="${j}"><span>
          <strong>${esc(path.split(/[\\/]/).pop() || path)}</strong><small>${esc(path)}</small></span>
        </label>`).join('')}</details>
      </div>`).join('');
    filter();
    syncSelection();
  }

  list.onchange = event => {
    const input = event.target;
    if (!(input instanceof HTMLInputElement)) return;
    const app = apps[Number(input.dataset.app)];
    const paths = input.dataset.file !== undefined ? [app.paths[Number(input.dataset.file)]]
      : [app.path];
    if (multiple) {
      for (const path of paths) {
        if (input.checked) selectedPaths.add(path);
        else {
          selectedPaths.delete(path);
          if (program.value === path) program.value = '';
        }
      }
    } else {
      program.value = input.checked ? paths[0] : '';
    }
    syncSelection();
  };
  search.oninput = filter;
  program.oninput = syncSelection;
  return { selectedPaths, refresh, syncSelection };
}
