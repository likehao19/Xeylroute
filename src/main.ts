import './styles.css';
import { initSiteIcons } from './icons';
import { mountDesktopApp } from './desktop-app';
import { mountPreviewApp } from './preview-app';
import { initShell } from './shell';
import { isTauri } from './tauri-bridge';
import { initGlobalPolish, initMacMenuListener } from './ui-kit';
import { initLanguage } from './ui-language';

initSiteIcons();
initGlobalPolish();
initMacMenuListener();
initLanguage();

const shell = initShell();

if (isTauri()) {
  mountDesktopApp(shell);
} else {
  mountPreviewApp(shell);
}
