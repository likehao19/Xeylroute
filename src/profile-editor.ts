import { confirmDialog, setDialogHeading, programFileIcon, programIconForPath } from './prototype.js';
import { groupRunningApps, normalizedProgramPath } from './running-apps.mjs';

type Invoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;

type Profile = {
  http?: number;
  socks?: number;
  mixed?: number;
  subscriptionScope?: string | null;
  rules?: string[];
  exits: string[];
  groups: { name: string; type: string; proxies?: string[]; use?: string[] }[];
  providers: { name: string; type: string; interval?: number }[];
};
type State = { profile: Profile; running: boolean };
type Edit = Record<string, unknown>;
type RunningApp = { path: string; name: string; exe: string; icon?: string | null };

export function mountProfileEditor(invoke: Invoke) {
  let state: State | undefined;
  let busy = false;
  const modal = document.createElement('dialog');
  modal.className = 'route-dialog profile-dialog';
  modal.addEventListener('click', event => { if (event.target === modal) modal.close(); });
  document.body.append(modal);

  function button(text: string, action: () => void, disabled = false) {
    const element = document.createElement('button');
    element.type = 'button';
    element.className = 'btn sm';
    element.textContent = text;
    element.disabled = disabled;
    element.onclick = action;
    return element;
  }

  async function reload() {
    if (busy) return;
    try {
      state = await invoke<State>('configured_profile_summary');
      render();
      document.dispatchEvent(new CustomEvent('routepilot:profile-visible', { detail: state.profile }));
    } catch (error) {
      document.getElementById('portStatus')!.textContent = String(error);
    }
  }

  async function commit(edit: Edit, feedback?: HTMLElement) {
    if (busy) return;
    busy = true;
    try {
      const profile = await invoke<Profile>('edit_core_profile', {
        edit, expectedScope: state?.profile.subscriptionScope ?? '',
      });
      state = { profile, running: state?.running ?? false };
      if (modal.open) modal.close();
      render();
      document.dispatchEvent(new CustomEvent('routepilot:profile-visible', { detail: profile }));
      document.dispatchEvent(new Event('routepilot:profile-changed'));
    } catch (error) {
      if (feedback) feedback.textContent = String(error);
      else void confirmDialog(String(error), { title: '操作失败', inform: true });
    } finally {
      busy = false;
    }
  }

  function field(form: HTMLElement, title: string, control: HTMLElement) {
    const label = document.createElement('label');
    label.className = 'profile-field';
    const caption = document.createElement('span');
    caption.textContent = title;
    label.append(caption, control);
    form.append(label);
    return control;
  }

  function input(value = '', type = 'text') {
    const el = document.createElement('input');
    el.className = 'search';
    el.type = type;
    el.value = value;
    return el;
  }

  function options(values: [string, string][], value?: string) {
    const el = document.createElement('select');
    el.className = 'select';
    for (const [key, label] of values) el.add(new Option(label, key));
    if (value) el.value = value;
    return el;
  }

  function open(title: string, createFields: (body: HTMLElement) => () => Edit) {
    modal.replaceChildren();
    setDialogHeading(modal, title);
    const form = document.createElement('form');
    form.className = 'profile-editor-body route-dialog-body';
    const readFields = createFields(form);
    const feedback = document.createElement('p');
    feedback.className = 'sub';
    feedback.setAttribute('role', 'status');
    const actions = document.createElement('div');
    actions.className = 'route-dialog-actions';
    const save = document.createElement('button');
    save.className = 'btn primary';
    save.textContent = '保存';
    actions.append(button('取消', () => modal.close()), save);
    form.append(feedback, actions);
    form.onsubmit = async event => {
      event.preventDefault();
      save.disabled = true;
      try { await commit(readFields(), feedback); }
      catch (error) { feedback.textContent = String(error); }
      finally { save.disabled = false; }
    };
    modal.append(form);
    modal.showModal();
  }

  function ruleForm(current?: string, index?: number, program?: string, selectedExit?: string, groupOnly = false) {
    const parts = current?.split(',') || [];
    const kind = program ? 'PROCESS-PATH' : parts[0] || 'DOMAIN';
    open(groupOnly ? '加入或移动分组' : program ? '设置程序出口' : current ? '编辑分流规则' : '添加分流规则', form => {
      const category = options(program ? [['PROCESS-PATH', '程序路径']] : [
        ['DOMAIN', '精确域名'], ['DOMAIN-SUFFIX', '域名后缀'],
        ['PROCESS-PATH', '程序路径'], ['MATCH', '默认出口'],
      ], kind);
      const target = input(program || (kind === 'MATCH' ? '' : parts[1]));
      target.readOnly = !!program;
      target.disabled = kind === 'MATCH';
      target.required = kind !== 'MATCH';
      category.onchange = () => {
        target.disabled = category.value === 'MATCH';
        target.required = !target.disabled;
      };
      const exits = groupOnly ? state?.profile.groups.map(group => group.name) : [...new Set(['GLOBAL', ...state?.profile.exits || []])];
      const exitLabels: Record<string, string> = { GLOBAL: '跟随全局出口', DIRECT: '直连 (DIRECT)', REJECT: '拒绝 (REJECT)', PASS: '跟随其余规则' };
      const exit = options((exits || []).map(name => [name, exitLabels[name] || name]),
        selectedExit || (kind === 'MATCH' ? parts[1] : parts[2]));
      field(form, '规则类型', category);
      field(form, '目标', target);
      exit.required = true;
      field(form, groupOnly ? '分组' : '出口', exit);
      return () => ({
        kind: 'rule', index, expected: current, category: category.value,
        target: category.value === 'MATCH' ? '' : target.value.trim(), exit: exit.value,
      });
    });
  }

  function addRuleForm() {
    open('添加分流规则', form => {
      const type = options([['DOMAIN', '网站 · 精确域名'], ['DOMAIN-SUFFIX', '网站 · 域名后缀'], ['PROCESS-PATH', '运行中的软件']]);
      const target = input('');
      target.placeholder = '例如 github.com';
      target.required = true;
      field(form, '目标类型', type);
      field(form, '目标域名', target);
      const search = input('');
      search.placeholder = '搜索软件名称或路径';
      search.setAttribute('aria-label', '搜索软件');
      const picker = document.createElement('div');
      picker.className = 'profile-picker';
      picker.textContent = '正在读取软件列表…';
      const panel = document.createElement('section');
      panel.className = 'profile-field';
      panel.hidden = true;
      panel.append(search, picker);
      form.append(panel);
      const groups = new Set(state?.profile.groups.map(group => group.name));
      const exits = state?.profile.exits || [];
      const exit = options(exits.map(name => [name, groups.has(name) ? '分组 · ' + name : name]), 'DIRECT');
      field(form, '分组或出口', exit);
      const selected = new Set<string>();
      let apps: ReturnType<typeof groupRunningApps<RunningApp>> = [];
      let loaded = false;
      const renderPicker = () => {
        const query = search.value.trim().toLowerCase();
        picker.replaceChildren();
        for (const app of apps) {
          if (query && ![app.name, ...app.paths].some(value => value.toLowerCase().includes(query))) continue;
          const row = document.createElement('label');
          row.className = 'profile-picker-row';
          const checkbox = document.createElement('input');
          checkbox.type = 'checkbox';
          checkbox.checked = app.paths.every(path => selected.has(path));
          checkbox.onchange = () => {
            for (const path of app.paths) {
              if (checkbox.checked) selected.add(path);
              else selected.delete(path);
            }
          };
          const text = document.createElement('span');
          text.textContent = app.name;
          const detail = document.createElement('small');
          detail.textContent = app.paths.length > 1 ? `${app.paths.length} 个可执行文件` : app.exe;
          detail.title = app.paths.join('\n');
          text.append(detail);
          row.append(checkbox);
          row.insertAdjacentHTML('beforeend', programFileIcon(app.icon));
          row.append(text);
          picker.append(row);
        }
        if (!picker.childElementCount) picker.textContent = '没有匹配的软件';
      };
      search.oninput = renderPicker;
      type.onchange = () => {
        const program = type.value === 'PROCESS-PATH';
        target.closest('label')!.hidden = program;
        target.disabled = program;
        panel.hidden = !program;
        if (!program || loaded) return;
        loaded = true;
        void invoke<RunningApp[]>('list_running_processes').then(processes => {
          apps = groupRunningApps(processes);
          renderPicker();
        }).catch(error => {
          picker.textContent = String(error);
          loaded = false;
        });
      };
      return () => type.value === 'PROCESS-PATH'
        ? { kind: 'programRules', targets: [...selected], exit: exit.value }
        : { kind: 'rule', category: type.value, target: target.value.trim(), exit: exit.value };
    });
  }

  function applicationForm(name: string, paths: string[], groupOnly: boolean) {
    const rules = new Map((state?.profile.rules || []).filter(line => line.startsWith('PROCESS-PATH,')).map(line => {
      const [, path, exit] = line.split(',');
      return [normalizedProgramPath(path), exit];
    }));
    const current = new Set(paths.map(path => rules.get(normalizedProgramPath(path))));
    const existing = current.size === 1 ? current.values().next().value : undefined;
    open((groupOnly ? '加入或移动分组 · ' : '设置软件出口 · ') + name, form => {
      const exits = groupOnly ? (state?.profile.groups || []).map(group => group.name)
        : [...new Set(['GLOBAL', ...state?.profile.exits || []])];
      const exit = options([['', '请选择'], ...exits.map(name => [name, name] as [string, string])], existing);
      exit.required = true;
      field(form, groupOnly ? '分组' : '出口', exit);
      const list = document.createElement('div');
      list.className = 'profile-picker app-path-picker';
      const selected = paths.map(path => {
        const row = document.createElement('label');
        row.className = 'profile-picker-row';
        const checkbox = document.createElement('input');
        checkbox.type = 'checkbox';
        checkbox.checked = true;
        const text = document.createElement('span');
        text.textContent = path.split(/[\\/]/).at(-1) || path;
        const detail = document.createElement('small');
        detail.textContent = path;
        detail.title = path;
        text.append(detail);
        row.append(checkbox);
        row.insertAdjacentHTML('beforeend', programIconForPath(path));
        row.append(text);
        list.append(row);
        return { path, checkbox };
      });
      form.append(list);
      return () => ({ kind: 'programRules', targets: selected.filter(item => item.checkbox.checked).map(item => item.path), exit: exit.value });
    });
  }

  function groupForm(group?: Profile['groups'][number]) {
    open(group ? '编辑分组' : '创建分组', form => {
      const name = input(group?.name);
      name.required = true;
      name.readOnly = !!group;
      const policy = options([['select', '手动选择'], ['url-test', '自动选择'], ['fallback', '故障切换']], group?.type);
      const members = options((state?.profile.exits || []).filter(item => item !== group?.name).map(item => [item, item]));
      members.multiple = true;
      members.size = 4;
      for (const option of members.options) option.selected = group?.proxies?.includes(option.value) ?? false;
      field(form, '分组名称', name);
      field(form, '策略', policy);
      field(form, '成员（可多选）', members);
      const scope = state?.profile.subscriptionScope;
      const providers = options((state?.profile.providers || []).filter(item => !scope || item.name === scope).map(item => [item.name, item.name]));
      providers.multiple = true;
      providers.size = 3;
      for (const option of providers.options) option.selected = group?.use?.includes(option.value) ?? false;
      if(providers.options.length)field(form, '订阅来源（可多选）', providers);
      return () => ({
        kind: 'group', name: name.value.trim(), policy: policy.value,
        members: [...members.selectedOptions].map(item => item.value),
        providers: [...providers.selectedOptions].map(item => item.value),
      });
    });
  }

  const addRule = document.querySelector<HTMLButtonElement>('#rules [data-add]')!;
  const createGroup = document.querySelector<HTMLButtonElement>('#createGroup')!;
  addRule.disabled = createGroup.disabled = true;
  addRule.onclick = event => {
    event.stopPropagation();
    if (state) addRuleForm();
  };
  createGroup.onclick = event => {
    event.stopPropagation();
    if (state) groupForm();
  };

  function render() {
    if (!state) return;
    const { profile, running } = state;
    addRule.disabled = createGroup.disabled = false;
    if (!portForm.contains(document.activeElement)) {
      portInputs.forEach((input, index) => input.value = String([profile.http, profile.socks, profile.mixed][index] || 0));
    }
    for (const input of portInputs) input.disabled = running;
    portSave.disabled = running;
    portSave.title = running ? '停止内核后可编辑配置' : '';
  }

  const portForm = document.querySelector<HTMLFormElement>('#portSettings')!;
  const portInputs = ['httpPort', 'socksPort', 'mixedPort'].map(id => document.getElementById(id) as HTMLInputElement);
  const portSave = portForm.querySelector<HTMLButtonElement>('button[type="submit"]')!;
  const portStatus = document.getElementById('portStatus')!;
  portInputs.forEach(input => { input.min = '0'; input.required = true; });
  portForm.onsubmit = async event => {
    event.preventDefault();
    if (busy || !state || state.running) return;
    portStatus.textContent = '';
    const [http, socks, mixed] = portInputs.map(input => input.valueAsNumber);
    await commit({ kind: 'ports', http, socks, mixed }, portStatus);
    if (!portStatus.textContent) portStatus.textContent = '端口已保存，启动内核后生效。';
  };

  document.addEventListener('routepilot:core-state', () => void reload());
  document.addEventListener('routepilot:profile-changed', () => void reload());
  document.addEventListener('routepilot:default-exit', async event => {
    if (!state) return;
    const index = state.profile.rules?.findIndex(rule => rule.startsWith('MATCH,')) ?? -1;
    const exit = (event as CustomEvent<string>).detail;
    await commit({
      kind: 'rule', index: index < 0 ? undefined : index,
      expected: index < 0 ? undefined : state.profile.rules?.[index], category: 'MATCH', target: '', exit,
    });
  });
  document.addEventListener('change', event => {
    const field = (event.target as HTMLElement).closest<HTMLInputElement>('[data-profile-toggle]');
    if (!field || !state) return;
    const enabled = field.checked;
    field.checked = !enabled;
    if (field.dataset.profileToggle === 'rule') {
      void commit({ kind: 'toggleRule', index: Number(field.dataset.profileId), expected: field.dataset.profileExpected, enabled });
    } else {
      void commit({ kind: 'toggleGroup', name: field.dataset.profileId, enabled });
    }
  });
  document.addEventListener('click', async event => {
    const target = (event.target as HTMLElement).closest<HTMLElement>('[data-native-program-path],[data-profile-edit],[data-profile-remove],[data-restore-subscription-exit]');
    if (!target) return;
    if (target.dataset.restoreSubscriptionExit) {
      await commit({ kind: 'toggleGroup', name: target.dataset.restoreSubscriptionExit, enabled: true });
      return;
    }
    await reload();
    if (!state) return;
    const { profile } = state;
    const identifier = target.dataset.profileId || '';
    const kind = target.dataset.profileEdit || target.dataset.profileRemove;
    if (target.dataset.nativeProgramPath) {
      const path = target.dataset.nativeProgramPath;
      const index = (profile.rules || []).findIndex(rule => rule.toLowerCase().startsWith('process-path,' + path.toLowerCase() + ','));
      const groupOnly = target.hasAttribute('data-native-program-group');
      if (groupOnly && profile.groups.length === 0) {
        void confirmDialog('请先在分组管理中创建分组。', { title: '暂无分组', inform: true });
        return;
      }
      if (target.dataset.nativeAppPaths) {
        applicationForm(target.dataset.nativeAppName || path, JSON.parse(target.dataset.nativeAppPaths), groupOnly);
        return;
      }
      ruleForm(index < 0 ? undefined : profile.rules?.[index], index < 0 ? undefined : index, path, undefined, groupOnly);
    } else if (kind === 'rule' || kind === 'member') {
      const index = Number(identifier);
      const rule = profile.rules?.[index];
      if (!rule || rule !== target.dataset.profileExpected) return;
      if (kind === 'member') {
        await commit({ kind: 'detachRule', index, expected: rule });
      } else if (target.dataset.profileRemove) {
        if (await confirmDialog('删除这条规则？', { confirmLabel: '删除' })) await commit({ kind: 'removeRule', index, expected: rule });
      } else ruleForm(rule, index);
    } else if (kind === 'group') {
      const group = profile.groups.find(item => item.name === identifier);
      if (!group) return;
      if (target.dataset.profileRemove) {
        if (await confirmDialog('删除该分组？', { confirmLabel: '删除' })) await commit({ kind: 'removeGroup', name: identifier });
      } else groupForm(group);
    } else if (kind === 'provider' && await confirmDialog('移除订阅？', { confirmLabel: '移除' })) {
      await commit({ kind: 'removeProvider', name: identifier });
    }
  });
  void reload();
}
