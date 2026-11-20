import { GlassContainer } from '@wxperia/liquid-glass-vue';
import { h, render } from 'vue';

// Keep the existing form elements, focus targets and event handlers above the optical layer.
export function mountGlassControls(): void {
  const observer = new ResizeObserver(entries => {
    for (const { target } of entries) {
      const host = target as HTMLElement;
      const layer = host.querySelector<HTMLElement>(':scope > .control-material')!;
      const width = host.offsetWidth;
      const height = host.offsetHeight;
      render(width && height ? h(GlassContainer, {
        glassSize: { width, height },
        cornerRadius: height / 2,
        padding: '0',
        displacementScale: 20,
        blurAmount: 0.08,
        saturation: 122,
        aberrationIntensity: 0.5,
      }) : null, layer);
    }
  });

  document.querySelectorAll<HTMLElement>('[data-glass-control]').forEach(host => {
    const layer = document.createElement('span');
    layer.className = 'control-material';
    layer.setAttribute('aria-hidden', 'true');
    host.prepend(layer);
    observer.observe(host, { box: 'border-box' });
  });
}
