import { englishMessages } from './ui-language-en';

const LANGUAGE_KEY = 'xeylroute-language';
const ATTRIBUTES = ['aria-label', 'title', 'placeholder', 'data-tip'];
const SOURCE_CONTENT = 'script, style, pre, code, [translate="no"], .cp-node-title, #heroNodeName';

const counters: [RegExp, (match: RegExpMatchArray) => string][] = [
  [/^(\d+) 条$/, ([, count]) => `${count} ${count === '1' ? 'rule' : 'rules'}`],
  [/^全部 (\d+) 个节点 ›$/, ([, count]) => `All ${count} nodes ›`],
  [/^(\d+) 行$/, ([, count]) => `${count} lines`],
  [/^刷新中 (\d+\/\d+)$/, ([, count]) => `Refreshing ${count}`],
  [/^出口 IP[：:]\s*(.+)$/, ([, ip]) => `Exit IP: ${ip}`],
  [/^(\d+) 个节点$/, ([, count]) => `${count} nodes`],
  [/^(\d+) 个目标$/, ([, count]) => `${count} targets`],
  [/^(\d+) 条程序规则$/, ([, count]) => `${count} app rules`],
  [/^(\d+) 进程$/, ([, count]) => `${count} processes`],
  [/^(\d+) 个进程$/, ([, count]) => `${count} processes`],
  [/^(\d+) 线程$/, ([, count]) => `${count} threads`],
  [/^当前订阅共 (\d+) 个可用节点$/, ([, count]) => `${count} available nodes in this subscription`],
  [/^管理组成员 \((\d+)\)$/, ([, count]) => `Manage members (${count})`],
  [/^辅助程序（(\d+)）$/, ([, count]) => `Helper processes (${count})`],
  [/^移除端口 (\d+)$/, ([, port]) => `Remove port ${port}`],
  [/^(.+) 在此订阅中不可用$/, ([, exit]) => `${exit} is unavailable in this subscription`],
  [/^到期 (.+)$/, ([, date]) => `Expires ${date}`],
  [/^更新 (.+)$/, ([, date]) => `Updated ${date}`],
  [/^已用 (.+ \/ .+)$/, ([, usage]) => `Used ${usage}`],
];

function english(text: string, composite = true): string {
  const message = text.trim();
  const translation = englishMessages.get(message);
  if (translation !== undefined) return text.replace(message, () => translation);
  for (const [pattern, format] of counters) {
    const match = message.match(pattern);
    if (match) return text.replace(message, () => format(match));
  }
  // Status labels use a middle dot between their fields. Translate only known fields.
  if (composite && text.includes(' · ')) return text.split(' · ').map(part => english(part, false)).join(' · ');
  return text;
}

export function initLanguage(): void {
  const select = document.getElementById('settingsLanguage') as HTMLSelectElement;
  type Original = { source: string; displayed: string };
  const originals = new WeakMap<Node, Map<string, Original>>();
  let useEnglish = false;

  function update(node: Node, name: string, value: string, write: (text: string) => void): void {
    let values = originals.get(node);
    const previous = values?.get(name);
    const source = previous?.displayed === value ? previous.source : value;
    const displayed = useEnglish ? english(source) : source;
    if (displayed === value) return;
    if (!values) originals.set(node, values = new Map());
    values.set(name, { source, displayed });
    write(displayed);
  }

  function updateText(node: Text): void {
    if (!node.parentElement?.closest(`textarea, ${SOURCE_CONTENT}`)) {
      update(node, 'text', node.data, text => { node.data = text; });
    }
  }

  function updateAttributes(element: Element): void {
    if (element.closest(SOURCE_CONTENT)) return;
    for (const name of ATTRIBUTES) {
      const value = element.getAttribute(name);
      if (value) update(element, name, value, text => element.setAttribute(name, text));
    }
  }

  function updateTree(root: Node): void {
    if (root instanceof Text) { updateText(root); return; }
    if (!(root instanceof Element)) return;
    updateAttributes(root);
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const node = walker.currentNode;
      if (node instanceof Text) updateText(node);
      else if (node instanceof Element) updateAttributes(node);
    }
  }

  const observer = new MutationObserver(records => {
    for (const record of records) {
      if (record.type === 'childList') {
        for (const node of record.addedNodes) updateTree(node);
      } else if (record.target instanceof Element) {
        updateAttributes(record.target);
      } else if (record.target instanceof Text) {
        updateText(record.target);
      }
    }
  });

  const apply = () => {
    observer.disconnect();
    useEnglish = select.value === 'en';
    document.documentElement.lang = useEnglish ? 'en' : 'zh-CN';
    updateTree(document.body);
    if (useEnglish) {
      observer.observe(document.body, {
        subtree: true, childList: true, characterData: true,
        attributes: true, attributeFilter: ATTRIBUTES,
      });
    }
  };
  select.value = localStorage.getItem(LANGUAGE_KEY) === 'en' ? 'en' : 'zh-CN';
  select.addEventListener('change', () => {
    localStorage.setItem(LANGUAGE_KEY, select.value);
    apply();
  });
  apply();
}
