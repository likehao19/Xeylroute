import { formatRate } from './traffic.mjs';
import { SF_CHECK, SF_CHEVRON_UD } from './icons';

export const $ = <T extends HTMLElement = HTMLElement>(id: string): T =>
  document.getElementById(id) as T;

export const esc = (value: unknown): string =>
  String(value ?? '').replace(/[&<>"']/g, ch => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  }[ch] || ch));

export function fmtTime(sec: number): string {
  const s = Math.max(0, Math.floor(sec));
  const h = String(Math.floor(s / 3600)).padStart(2, '0');
  const m = String(Math.floor((s % 3600) / 60)).padStart(2, '0');
  const rem = String(s % 60).padStart(2, '0');
  return `${h}:${m}:${rem}`;
}

let toastTimer: number | null = null;
export function notify(message: string, isError = false): void {
  const el = $('toast');
  if (!el) return;
  el.innerHTML = `<span class="toast-dot"></span><span>${esc(message)}</span>`;
  el.classList.toggle('error', isError);
  el.classList.add('show');
  if (toastTimer !== null) window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => el.classList.remove('show'), isError ? 3600 : 2300);
}

/* =========================================================================
   macOS Pop-Up Button & Translucent Frosted Pop-Up Menu
   ========================================================================= */
export type PopupMenuItem =
  | { sep: true }
  | {
      sep?: false;
      value: string;
      label: string;
      meta?: string;
      dot?: string;
    };

type ActivePopupContext = {
  trigger: HTMLElement;
  items: PopupMenuItem[];
  onSelect: (value: string, label: string) => void;
};

let activePopupCtx: ActivePopupContext | null = null;

export function popupDotClass(val: string): string {
  const lower = val.toLowerCase();
  if (lower === 'direct') return 'green';
  if (lower === 'reject' || lower === 'off') return 'red';
  if (lower === 'domain-rules' || lower === 'pass') return 'purple';
  if (lower === 'auto' || lower === 'global-follow' || lower === 'global' || lower === 'on') return 'cyan';
  return '';
}

export function macPopupBtnHtml(opts: {
  id?: string;
  value: string | null;
  label: string;
  width?: number;
  popupKind: string;
  popupKey?: string;
  disabled?: boolean;
}): string {
  const dot = popupDotClass(opts.value ?? '');
  const wStyle = opts.width ? `style="min-width:${opts.width}px;max-width:${opts.width + 24}px"` : '';
  return `
    <button type="button" class="mac-popup-btn"
      ${opts.id ? `id="${esc(opts.id)}"` : ''}
      ${wStyle}
      data-popup-kind="${esc(opts.popupKind)}"
      data-popup-key="${esc(opts.popupKey || '')}"
      ${opts.value === null ? '' : `data-popup-val="${esc(opts.value)}"`}
      aria-haspopup="menu" aria-expanded="false"
      ${opts.disabled ? 'disabled' : ''}>
      <span class="mac-popup-dot ${dot}"></span>
      <span class="mac-popup-label">${esc(opts.label)}</span>
      ${SF_CHEVRON_UD}
    </button>
  `;
}

export function closeMacMenu(): void {
  const pop = $('macMenuPopover');
  if (!pop) return;
  pop.classList.remove('open');
  if (activePopupCtx?.trigger) {
    activePopupCtx.trigger.setAttribute('aria-expanded', 'false');
  }
  activePopupCtx = null;
}

export function openMacMenu(
  trigger: HTMLElement,
  items: PopupMenuItem[],
  selectedValue: string | null,
  onSelect: (value: string, label: string) => void,
): void {
  const pop = $('macMenuPopover');
  if (activePopupCtx?.trigger === trigger && pop.classList.contains('open')) {
    closeMacMenu();
    return;
  }
  closeMacMenu();
  trigger.setAttribute('aria-expanded', 'true');
  pop.innerHTML = items.map((item, idx) => {
    if (item.sep) return '<div class="mac-menu-sep"></div>';
    const sel = item.value === selectedValue;
    return `
      <button type="button" class="mac-menu-item ${sel ? 'selected' : ''}" data-menu-idx="${idx}" role="menuitemradio" aria-checked="${sel}">
        <span class="mac-menu-check">${SF_CHECK}</span>
        <span class="mac-menu-item-text">${esc(item.label)}</span>
        ${item.meta ? `<span class="mac-menu-meta">${esc(item.meta)}</span>` : ''}
      </button>
    `;
  }).join('');

  const rect = trigger.getBoundingClientRect();
  const matchTriggerWidth = rect.width >= 240;
  pop.style.minWidth = `${matchTriggerWidth ? Math.round(rect.width) : Math.max(186, Math.round(rect.width))}px`;
  pop.style.maxWidth = `${matchTriggerWidth ? Math.round(rect.width) : 280}px`;
  pop.classList.add('open');
  const pw = pop.offsetWidth;
  const ph = pop.offsetHeight;
  let left = matchTriggerWidth ? rect.left : rect.right - pw;
  if (left < 12) left = rect.left;
  if (left + pw > window.innerWidth - 12) left = Math.max(12, window.innerWidth - pw - 12);
  const spaceBelow = window.innerHeight - rect.bottom - 14;
  const openBelow = spaceBelow >= ph || spaceBelow >= rect.top - 14;
  const top = openBelow ? rect.bottom + 6 : Math.max(12, rect.top - ph - 6);
  pop.style.left = `${Math.round(left)}px`;
  pop.style.top = `${Math.round(top)}px`;
  pop.style.transformOrigin = openBelow
    ? (matchTriggerWidth ? 'top center' : 'top right')
    : (matchTriggerWidth ? 'bottom center' : 'bottom right');
  activePopupCtx = { trigger, items, onSelect };
  (pop.querySelector<HTMLButtonElement>('.selected') ?? pop.querySelector('button'))?.focus({ preventScroll: true });
}

export function initMacMenuListener(): void {
  $('macMenuPopover').addEventListener('keydown', e => {
    if (!activePopupCtx) return;
    const buttons = Array.from($('macMenuPopover').querySelectorAll('button'));
    const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
    if (e.key === 'Escape') {
      e.stopPropagation();
      activePopupCtx.trigger.focus();
      closeMacMenu();
    } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      buttons[(index + (e.key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length]?.focus();
    }
  });
  $('macMenuPopover').addEventListener('click', e => {
    const btn = (e.target as HTMLElement).closest<HTMLElement>('[data-menu-idx]');
    if (!btn || !activePopupCtx) return;
    const item = activePopupCtx.items[Number(btn.dataset.menuIdx)];
    const cb = activePopupCtx.onSelect;
    activePopupCtx.trigger.focus();
    closeMacMenu();
    if (item && !item.sep) cb(item.value, item.label);
  });

  document.querySelector('.views-host')?.addEventListener('scroll', () => {
    if (activePopupCtx) closeMacMenu();
  }, { passive: true });
}

/* =========================================================================
   macOS 27 Structured Frosted Glass Spring Sheet Modal & Confirm Alert
   ========================================================================= */

export type SheetOptions = {
  title: string;
  subtitle?: string;
  iconHtml?: string;
  bodyHtml: string;
  actionsHtml?: string;
  actionsSplit?: boolean;
  size?: 'default' | 'wide' | 'compact';
};

let sheetOpener: HTMLElement | null = null;
let sheetDismissResolve: ((value: boolean) => void) | null = null;

export function isSheetOpen(): boolean {
  return $('sheetBackdrop').classList.contains('open');
}

function showSheet(): void {
  if (!isSheetOpen()) sheetOpener = document.activeElement as HTMLElement | null;
  $('macWindow').inert = true;
  $('sheetBackdrop').inert = false;
  $('sheetBackdrop').classList.add('open');
}

export function openSheet(opts: SheetOptions): void {
  closeMacMenu();
  const content = $('sheetContent');
  content.classList.toggle('sheet-wide', opts.size === 'wide');
  content.classList.toggle('sheet-compact', opts.size === 'compact');
  content.innerHTML = `
    <div class="sheet-head">
      <div class="sheet-head-left">
        ${opts.iconHtml || ''}
        <div style="min-width:0">
          <h3 id="sheetTitle">${esc(opts.title)}</h3>
          ${opts.subtitle ? `<p>${esc(opts.subtitle)}</p>` : ''}
        </div>
      </div>

    </div>
    <div class="sheet-body" id="sheetScrollBody">
      ${opts.bodyHtml}
    </div>
    ${opts.actionsHtml ? `<div class="sheet-actions${opts.actionsSplit ? ' sheet-actions-split' : ''}">${opts.actionsHtml}</div>` : ''}
  `;
  $('sheetScrollBody').addEventListener('scroll', () => {
    if (activePopupCtx) closeMacMenu();
  }, { passive: true });
  showSheet();
  content.focus({ preventScroll: true });
}

export function closeSheet(): void {
  closeMacMenu();
  $('sheetBackdrop').classList.remove('open');
  $('sheetBackdrop').inert = true;
  $('macWindow').inert = false;
  sheetOpener?.focus({ preventScroll: true });
  sheetOpener = null;
  if (sheetDismissResolve) {
    const resolve = sheetDismissResolve;
    sheetDismissResolve = null;
    resolve(false);
  }
}

export function confirmSheet(opts: {
  title: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  inform?: boolean;
  danger?: boolean;
  tone?: 'blue' | 'red' | 'orange' | 'cyan';
}): Promise<boolean> {
  return new Promise(resolve => {
    closeSheet();
    sheetDismissResolve = resolve;
    const tone = opts.tone || (opts.danger ? 'red' : 'blue');
    const iconSvg = opts.danger
      ? `<path d="M3 6h18"/><path d="M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>`
      : tone === 'cyan'
        ? `<path d="M12 3 4 7v5c0 5 3.5 8.5 8 9.8 4.5-1.3 8-4.8 8-9.8V7l-8-4Z"/>`
        : `<circle cx="12" cy="12" r="9"/><path d="M12 16v-4"/><path d="M12 8h.01"/>`;
    const primaryCls = opts.danger ? 'glass-btn-danger' : 'glass-btn-primary compact';

    const content = $('sheetContent');
    content.classList.remove('sheet-wide');
    content.classList.add('sheet-compact');
    content.innerHTML = `
      <div class="sheet-body" style="padding:20px 20px 18px">
        <div class="confirm-alert-body">
          <span class="sq confirm-alert-icon ${tone}">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">${iconSvg}</svg>
          </span>
          <div class="confirm-alert-copy">
            <h4 id="sheetTitle">${esc(opts.title)}</h4>
            <p>${esc(opts.message)}</p>
          </div>
        </div>
      </div>
      <div class="sheet-actions">
        ${opts.inform ? '' : `<button type="button" class="glass-btn-soft" id="sheetConfirmCancel">${esc(opts.cancelLabel || '取消')}</button>`}
        <button type="button" class="${primaryCls}" id="sheetConfirmOk">${esc(opts.confirmLabel || '确定')}</button>
      </div>
    `;
    showSheet();

    const finish = (accepted: boolean) => {
      sheetDismissResolve = null;
      closeSheet();
      resolve(accepted);
    };
    const cancel = document.getElementById('sheetConfirmCancel');
    if (cancel) cancel.onclick = () => finish(false);
    $('sheetConfirmOk').onclick = () => finish(true);
    (cancel || $('sheetConfirmOk')).focus();
  });
}

/* =========================================================================
   Traffic and connection history
   ========================================================================= */
export class TelemetryVisualizer {
  readonly down: number[];
  readonly up: number[];
  private readonly connections: ({ count: number; time: number; rates?: { down: number; up: number } | null } | null)[] = Array(96).fill(null);
  private peakConnections = 0;
  private hoverCell = -1;
  private selectedCell = -1;
  private samples: number;
  private chartMax = 10;
  private hoverIndex = -1;

  constructor(seedDemo: boolean) {
    this.samples = seedDemo ? 96 : 0;
    if (seedDemo) {
      this.down = Array.from({ length: 32 }, (_, i) =>
        Number((7.2 + Math.sin(i * 0.42) * 3.6 + Math.cos(i * 0.23) * 1.8).toFixed(1))
      );
      this.up = this.down.map((v, i) => Number((v * (0.13 + (i % 3) * 0.02)).toFixed(1)));
      const now = Date.now();
      this.connections = this.connections.map((_, i) => ({
        count: Math.round(18 + 12 * Math.sin(i * .14) + 5 * Math.cos(i * .36)),
        time: now - (95 - i) * 1000,
      }));
    } else {
      this.down = Array.from({ length: 32 }, () => 0);
      this.up = Array.from({ length: 32 }, () => 0);
    }
  }

  bindInteractions(): void {
    const svg = $('mainChartSvg');
    svg.addEventListener('pointermove', e => {
      const r = svg.getBoundingClientRect();
      if (!r.width) return;
      const frac = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
      this.hoverIndex = Math.round(frac * (this.down.length - 1));
      this.updateHover(this.hoverIndex);
    });
    svg.addEventListener('pointerleave', () => {
      this.hoverIndex = -1;
      $('chartHoverV').style.opacity = '0';
      $('chartDotDown').style.opacity = '0';
      $('chartDotUp').style.opacity = '0';
      $('chartTooltip').classList.remove('show');
    });

    const grid = $('connectionHistory');
    const cellIndex = (event: Event) => {
      const cell = (event.target as HTMLElement).closest<HTMLElement>('[data-sample]');
      return cell ? Number(cell.dataset.sample) : -1;
    };
    grid.addEventListener('pointerover', e => {
      this.hoverCell = cellIndex(e);
      this.showConnectionReading();
    });
    grid.addEventListener('pointerleave', () => {
      this.hoverCell = -1;
      this.showConnectionReading();
    });
    grid.addEventListener('click', e => {
      const i = cellIndex(e);
      this.selectCell(this.selectedCell === i ? -1 : i);
    });
    grid.addEventListener('keydown', e => {
      if (e.key === 'Escape') this.selectCell(-1);
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
      e.preventDefault();
      this.hoverCell = -1;
      const i = this.selectedCell < 0 ? 95 : this.selectedCell + (e.key === 'ArrowLeft' ? -1 : 1);
      this.selectCell(Math.max(0, Math.min(95, i)));
    });
  }

  private selectCell(index: number): void {
    const cells = $('connectionHistory').children;
    cells[this.selectedCell]?.removeAttribute('data-selected');
    this.selectedCell = index;
    cells[index]?.setAttribute('data-selected', '');
    this.showConnectionReading();
  }

  private showConnectionReading(): void {
    const i = this.selectedCell >= 0 ? this.selectedCell : this.hoverCell;
    const sample = this.connections[i];
    const latest = this.connections[this.connections.length - 1];
    let text = latest ? `最新 ${latest.count} 个 · 峰值 ${this.peakConnections} 个` : '等待连接采样';
    if (i >= 0) {
      text = sample ? `${new Date(sample.time).toLocaleTimeString('zh-CN', { hour12: false })} · ${sample.count} 个连接` : '尚未采样';
    }
    $('connectionReadout').textContent = text;
    $('connectionFoot').textContent = sample?.rates
      ? `↓ ${formatRate(sample.rates.down)} · ↑ ${formatRate(sample.rates.up)}` : '较早 → 最新';
  }

  pushConnectionCount(count: number, rates: { down: number; up: number } | null): void {
    this.connections.shift();
    this.connections.push({ count, time: Date.now(), rates });
    if (this.selectedCell >= 0) this.selectCell(this.selectedCell - 1);
    this.renderConnections();
  }

  pushSample(downMBs: number, upMBs: number): void {
    const d = Math.max(0, downMBs);
    const u = Math.max(0, upMBs);
    this.samples = Math.min(96, this.samples + 1);
    this.down.push(d);
    this.down.shift();
    this.up.push(u);
    this.up.shift();
    this.paintChart();
  }

  private smoothPath(coords: [number, number][]): string {
    if (!coords.length) return '';
    let d = `M ${coords[0][0].toFixed(1)} ${coords[0][1].toFixed(1)}`;
    for (let i = 0; i < coords.length - 1; i++) {
      const p0 = coords[Math.max(0, i - 1)];
      const p1 = coords[i];
      const p2 = coords[i + 1];
      const p3 = coords[Math.min(coords.length - 1, i + 2)];
      const cp1x = p1[0] + (p2[0] - p0[0]) / 6;
      const cp1y = Math.max(8, Math.min(124, p1[1] + (p2[1] - p0[1]) / 6));
      const cp2x = p2[0] - (p3[0] - p1[0]) / 6;
      const cp2y = Math.max(8, Math.min(124, p2[1] - (p3[1] - p1[1]) / 6));
      d += ` C ${cp1x.toFixed(1)} ${cp1y.toFixed(1)}, ${cp2x.toFixed(1)} ${cp2y.toFixed(1)}, ${p2[0].toFixed(1)} ${p2[1].toFixed(1)}`;
    }
    return d;
  }

  paintChart(): void {
    const peakVal = Math.max(...this.down, ...this.up, 0);
    this.chartMax = peakVal > 0 ? Math.max(1 / 1048576, 2 ** Math.ceil(Math.log2(peakVal))) : 1;
    const count = Math.min(this.samples, this.down.length);
    const avgD = this.down.reduce((a, b) => a + b, 0) / (count || 1);
    $('chartTickTop').textContent = formatRate(this.chartMax);
    $('chartTickMid').textContent = formatRate(this.chartMax / 2);
    $('chartAvgFoot').textContent = count
      ? `平均下载 ${formatRate(avgD)} · 峰值 ${formatRate(Math.max(...this.down))}` : '等待流量采样';

    const start = this.down.length - count;
    const toXY = (arr: number[]): [number, number][] =>
      arr.slice(start).map((v, i) => [
        ((start + i) / (arr.length - 1)) * 600,
        120 - (Math.min(v, this.chartMax) / this.chartMax) * 104,
      ]);
    const dPath = this.smoothPath(toXY(this.down));
    const uPath = this.smoothPath(toXY(this.up));
    $('mainDownLine').setAttribute('d', dPath);
    $('mainUpLine').setAttribute('d', uPath);
    const closeArea = ` L 600 130 L ${600 * start / (this.down.length - 1)} 130 Z`;
    $('mainDownArea').setAttribute('d', dPath ? dPath + closeArea : '');
    $('mainUpArea').setAttribute('d', uPath ? uPath + closeArea : '');

    const waveCoords: [number, number][] = this.down.slice(-16).map((v, i, arr) => [
      (i / (arr.length - 1)) * 200,
      30 - (Math.min(v, this.chartMax) / this.chartMax) * 24,
    ]);
    const sidePath = document.getElementById('sideWavePath');
    if (sidePath && waveCoords.length) {
      let s = `M 0 32 L ${waveCoords[0][0].toFixed(1)} ${waveCoords[0][1].toFixed(1)}`;
      for (let i = 1; i < waveCoords.length; i++) {
        s += ` L ${waveCoords[i][0].toFixed(1)} ${waveCoords[i][1].toFixed(1)}`;
      }
      s += ' L 200 32 Z';
      sidePath.setAttribute('d', s);
    }

    if (this.hoverIndex >= 0) this.updateHover(this.hoverIndex);
  }

  private updateHover(idx: number): void {
    const i = Math.max(0, Math.min(this.down.length - 1, idx));
    const pctX = (i / (this.down.length - 1)) * 100;
    const pctYd = ((120 - (Math.min(this.down[i], this.chartMax) / this.chartMax) * 104) / 130) * 100;
    const pctYu = ((120 - (Math.min(this.up[i], this.chartMax) / this.chartMax) * 104) / 130) * 100;
    const vLine = $('chartHoverV');
    vLine.style.left = `${pctX}%`;
    vLine.style.opacity = '1';
    const dDot = $('chartDotDown');
    dDot.style.left = `${pctX}%`;
    dDot.style.top = `${pctYd}%`;
    dDot.style.opacity = '1';
    const uDot = $('chartDotUp');
    uDot.style.left = `${pctX}%`;
    uDot.style.top = `${pctYu}%`;
    uDot.style.opacity = '1';
    const tip = $('chartTooltip');
    const stepAgo = this.down.length - 1 - i;
    tip.textContent = stepAgo >= this.samples ? '尚未采样'
      : `${stepAgo === 0 ? '最近采样' : `${stepAgo} 次采样前`} · ↓ ${formatRate(this.down[i])}  ↑ ${formatRate(this.up[i])}`;
    tip.style.left = pctX > 62 ? 'auto' : `calc(${pctX}% + 10px)`;
    tip.style.right = pctX > 62 ? `calc(${100 - pctX}% + 10px)` : 'auto';
    tip.classList.add('show');
  }

  renderConnections(): void {
    const plot = $('connectionHistory');
    if (!plot.childElementCount) {
      plot.innerHTML = this.connections.map((_, i) => `<span data-sample="${i}"></span>`).join('');
    }
    this.peakConnections = Math.max(...this.connections.map(s => s?.count ?? 0));
    this.connections.forEach((sample, i) => {
      const bar = plot.children[i] as HTMLElement;
      if (sample) {
        bar.style.setProperty('--bar-height', sample.count === 0 ? '1px' : `max(2px, ${100 * sample.count / this.peakConnections}%)`);
      } else {
        bar.style.removeProperty('--bar-height');
      }
    });
    this.showConnectionReading();
  }
}

/* =========================================================================
   Pointer-Tracking Glass Specular Sheen + Viewport-Aware Tooltip
   ========================================================================= */
export function initGlobalPolish(): void {
  let tipTimer: number | null = null;
  document.addEventListener('pointerover', e => {
    const el = (e.target as HTMLElement | null)?.closest<HTMLElement>('[data-tip]');
    if (!el || !el.dataset.tip) return;
    if (tipTimer !== null) window.clearTimeout(tipTimer);
    tipTimer = window.setTimeout(() => {
      const tip = $('macTooltip');
      const r = el.getBoundingClientRect();
      tip.textContent = el.dataset.tip || '';
      const nearBottom = r.bottom + 42 > window.innerHeight;
      tip.classList.toggle('flip-top', nearBottom);
      const halfW = Math.min(120, Math.max(48, (tip.textContent.length * 6.5) / 2 + 12));
      tip.style.left = `${Math.max(halfW, Math.min(window.innerWidth - halfW, r.left + r.width / 2))}px`;
      tip.style.top = nearBottom ? `${r.top - 8}px` : `${r.bottom + 8}px`;
      tip.classList.add('show');
    }, 280);
  });
  document.addEventListener('pointerout', e => {
    if ((e.target as HTMLElement | null)?.closest('[data-tip]')) {
      if (tipTimer !== null) window.clearTimeout(tipTimer);
      $('macTooltip').classList.remove('show');
    }
  });

  $('sheetBackdrop').addEventListener('click', e => {
    if (e.target === $('sheetBackdrop')) closeSheet();
  });
}
