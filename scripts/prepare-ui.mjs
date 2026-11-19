import fs from 'node:fs';
import { wireLiveData } from './live-ui.mjs';

const html = fs.readFileSync('routepilot-v08-fixed.html', 'utf8');
const start = html.indexOf('<script>');
const end = html.lastIndexOf('</script>');
if (start < 0 || end < start) throw new Error('Cannot locate the original interface script');
let prototype = html.slice(start + '<script>'.length, end)
  .replace("'./public/site-icons/'", "'/site-icons/'")
  .replaceAll('routepilot-group-v3', 'routepilot-desktop-preview-v1')
  .replace("defaultNode:'n1',on:true,mode:'system',network:{tun:false,system:true}", "defaultNode:'n1',on:false,mode:'system',network:{tun:false,system:false}");
const records = 'const RUNNING=';
if (!prototype.includes(records)) throw new Error('Cannot locate process data');
prototype = prototype.replace(records, 'const RUNNING=window.__TAURI__?[]:');
const refreshStart = prototype.indexOf("$('refreshProcesses').onclick=");
const refreshEnd = prototype.indexOf("$('clearLogs').onclick=", refreshStart);
if (refreshStart < 0 || refreshEnd < 0) throw new Error('Cannot locate process refresh');
prototype = prototype.slice(0, refreshStart) + `
async function refreshDesktopProcesses(){
  if(!window.__TAURI__){renderRunning();notify('模拟运行列表已刷新');return}
  const button=$('refreshProcesses');
  button.disabled=true;
  try{
    const processes=await window.__TAURI__.core.invoke('list_running_processes');
    const apps=groupRunningApps(processes).map(app=>({...app,type:'app'}));
    RUNNING.splice(0,RUNNING.length,...apps,...processes.map(process=>({...process,type:'process'})));
    const target=$('testTarget');
    const previous=target.value;
    target.options.length=1;
    for(const process of processes)target.add(new Option(process.name+' · PID '+process.pid,String(process.pid)));
    if([...target.options].some(option=>option.value===previous))target.value=previous;
    render();
  }catch(error){notify(String(error))}
  finally{button.disabled=false}
}
$('refreshProcesses').onclick=refreshDesktopProcesses;
if(window.__TAURI__)void refreshDesktopProcesses();
` + prototype.slice(refreshEnd);
const desktopScript = wireLiveData(prototype);
const scriptEnd = desktopScript.lastIndexOf('})();');
if (scriptEnd < 0) throw new Error('Cannot locate prototype closure');
fs.writeFileSync('src/prototype.js',
  "import { groupRunningApps } from './running-apps.mjs';\nexport const { confirmDialog, setDialogHeading, programFileIcon, programIconForPath, waitForLocalCoreStart } = " + desktopScript.slice(0, scriptEnd).trimStart()
  + '\nreturn { confirmDialog, setDialogHeading, programFileIcon, programIconForPath, waitForLocalCoreStart };\n' + desktopScript.slice(scriptEnd));
const shell = html.slice(0, start)
  .replace('./public/app-icon.png', '/app-icon.png')
  .replace('<dt>系统 DNS</dt><dd>无法读取</dd>', '<dt>系统 DNS</dt><dd id="detailSystemDns">无法读取</dd>')
  .replace('<dt>本机 IP</dt><dd>无法读取</dd>', '<dt>本机 IP</dt><dd id="detailLocalIp">无法读取</dd>')
  .replace('<dt>出口 IP</dt><dd>未检测</dd>', '<dt>出口 IP</dt><dd><span id="detailExitIp">未检测</span> <button type="button" class="btn sm" id="checkExitIp" title="检测出口 IP" hidden>检测</button></dd>')
  .replace('</style>', `.desktop-live [hidden]{display:none!important}
.profile-editor-body{display:grid;gap:8px}
.profile-field{display:grid;gap:5px}
.profile-field :is(.search,.select){width:100%;max-width:none}
.profile-field select[multiple]{height:auto;min-height:85px}
.profile-picker{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));max-height:220px;overflow:auto;border:1px solid var(--line);border-radius:6px}
.profile-picker-row{display:flex;align-items:center;gap:8px;padding:8px 10px;border-bottom:1px solid var(--line)}
.profile-picker-row span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.profile-picker-row small{display:block;color:var(--muted);font-size:11px}
.app-path-picker{grid-template-columns:1fr}
.app-path-picker small{overflow:hidden;text-overflow:ellipsis}
.desktop-live .running-info>.target{flex:0 1 clamp(215px,31%,310px);min-width:min(32%,160px)}
.running-card .program-identity{min-width:0}
.running-card .program-identity small{display:flex;align-items:center;gap:6px;white-space:nowrap}
.running-card .program-identity .program-exe{overflow:hidden;text-overflow:ellipsis}
.running-card .process-metric{flex:none;font:11px var(--font-mono);color:var(--text-purple)}
.process-dialog h2{display:flex;align-items:center;gap:8px}
.process-detail td .program-file-icon{margin-inline-end:6px}
.process-detail{display:grid;gap:12px}
.process-detail dl{display:grid;grid-template-columns:82px minmax(0,1fr);gap:8px;margin:0;font-size:13px}
.process-detail dd{margin:0;overflow-wrap:anywhere}
.process-detail table{width:100%;border-collapse:collapse;font-size:12px;text-align:left}
.process-detail th,.process-detail td{padding:7px 8px;border-bottom:1px solid var(--line)}
.process-thread-list{max-height:240px;overflow:auto;border:1px solid var(--line);border-radius:6px}
.subscription-select{background:transparent;border:0;color:inherit;cursor:pointer;text-align:left;min-width:0;padding:2px 0}
.subscription-select strong{display:block}
.subscription-usage{display:block;width:100%;height:4px;accent-color:var(--blue)}
.group-target-line{display:flex;gap:8px;align-items:center;justify-content:space-between;min-width:0;padding:4px 2px}
.group-target-line span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.group-target-name{display:flex;align-items:center;gap:6px;min-width:0}
.group-target-line+.group-target-line{border-top:1px solid var(--line)}
.routing-scope{display:flex;flex:none;align-items:center;flex-wrap:wrap;gap:6px 8px;min-width:0;padding:8px 11px}
#groupsScope{padding-inline:0}
#allRules .default-rule{grid-template-columns:minmax(0,max-content) minmax(0,1fr);gap:10px;min-height:42px}
#allRules .default-rule .rule-footer{grid-column:2;grid-row:1}
#allRules .rule-config-name{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--muted)}
#allRules .rule-effect{flex:none}
#allRules .rules-empty{display:flex;flex-direction:column;gap:4px}
@media(max-width:620px){
 #allRules .default-rule{grid-template-columns:minmax(0,1fr)}
 #allRules .default-rule .rule-footer{grid-column:1;grid-row:2}
}
</style>`);
fs.writeFileSync('index.html', shell + '<script type="module" src="/src/main.ts"></script>' + html.slice(end + '</script>'.length));
