import './styles.css';
import { mountDesktopApp } from './desktop-app';
import { mountPreviewApp } from './preview-app';
import { initShell } from './shell';
import { isTauri } from './tauri-bridge';
import { initGlobalPolish, initMacMenuListener } from './ui-kit';

initGlobalPolish();
initMacMenuListener();

const shell = initShell();

if (isTauri()) {
  mountDesktopApp(shell);
} else {
  mountPreviewApp(shell);
}

if (document.documentElement.classList.contains('platform-macos')) {
  void import('./glass-controls').then(({ mountGlassControls }) => mountGlassControls());
}
