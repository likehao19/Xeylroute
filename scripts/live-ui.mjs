function wireLiveData(source) {
  const swap = (start, end, code) => {
    const a = source.indexOf(start);
    const b = source.indexOf(end, a + start.length);
    if (a < 0 || b < 0) throw new Error('Cannot locate live integration boundary: ' + start);
    source = source.slice(0, a) + code + '\n' + source.slice(b);
  };
  const inject = (marker, code) => {
    if (!source.includes(marker)) throw new Error('Cannot locate live integration marker: ' + marker);
    source = source.replace(marker, code + '\n' + marker);
  };
  source = source.replace(
    '交互原型|Interactive prototype',
    `交互原型|Interactive prototype
代理总开关|Proxy power
暂无可选出口|No exit available
正在读取软件列表…|Reading running applications…
目标域名|Destination domain
目标类型|Target type
分组或出口|Group or exit
运行中的软件|Running applications
网站 · 精确域名|Website · Exact domain
网站 · 域名后缀|Website · Domain suffix
搜索软件名称或路径|Search by application or path
没有匹配的软件|No matching applications
移出分组|Remove from group
跟随全局出口|Use global exit
跟随其余规则|Continue matching rules
粘贴 HTTPS 订阅或节点链接|Paste an HTTPS subscription or node link
代理服务未启动|Proxy service stopped
代理服务运行中|Proxy service running
暂无连接记录|No connection records`);
  inject('function renderRouting(state){', `
const native = window.__TAURI__?.core;
let liveStatus=null, liveCore=null, liveRefresh=null, refreshAgain=false, liveTotals=null, liveError='', exitIp='';
let networkUpdating=false, localCoreStart=null, selectingNode=false;
let changingMode=false, traySignature='', trayUpdate=Promise.resolve();
function syncTray(){
 if(!window.__TAURI__?.event)return;
 const global=liveCore?.proxies?.proxies?.GLOBAL;
 const state={
   english:document.documentElement.lang==='en',
   configured:!!liveStatus?.configured,
   running:!!liveStatus?.running,
   systemProxy:!!liveStatus?.systemProxy,
   tun:!!liveStatus?.tun,
   busy:networkUpdating||selectingNode||changingMode||changingSubscription,
   mode:db.routingMode,
   nodes:global?.type==='Selector'?subscriptionNodeCards().map(node=>node.name).filter(name=>global.all?.includes(name)):[],
   selected:global?.now||''
 };
 const signature=JSON.stringify(state);
 if(signature===traySignature)return;
 traySignature=signature;
 trayUpdate=trayUpdate.then(()=>native.invoke('update_tray_menu',{state})).catch(error=>{
   if(traySignature===signature)traySignature='';
   console.warn('Could not update the RoutePilot tray menu:',error);
 });
}
const renderedMarkup=new WeakMap();
function setLiveMarkup(element,markup){
 if(renderedMarkup.get(element)===markup)return;
 element.innerHTML=markup;
 renderedMarkup.set(element,markup);
}
let networkDetails=null, lastNetworkRead=0, readingNetwork=false;
async function refreshWindowsNetwork(){
 if(readingNetwork||Date.now()-lastNetworkRead<15000)return;
 readingNetwork=true;
 lastNetworkRead=Date.now();
 try{networkDetails=await native.invoke('windows_network_details')}
 catch{networkDetails={error:true}}
 finally{readingNetwork=false;renderNetworkDetails(realOverview())}
}
let savedSubscriptions=[];
const subscriptionSelectionKey='routepilot-active-subscription';
let selectedLiveSubscription=localStorage.getItem(subscriptionSelectionKey)||'';
let changingSubscription=false, scopeMigrationAttempted=false, subscriptionRead=0;
let pendingSubscription='';
function savedSubscriptionMap(key){
 try{return new Map(JSON.parse(localStorage.getItem(key)||'[]'))}
 catch{return new Map()}
}
const subscriptionNodes=savedSubscriptionMap('routepilot-subscription-nodes');
const subscriptionSelections=savedSubscriptionMap('routepilot-subscription-exits');
const subscriptionCardData=savedSubscriptionMap('routepilot-subscription-card-data');
const subscriptionCardReads=new Set();
const groupSelections=savedSubscriptionMap('routepilot-scoped-group-exits');
let restoredGroupScope=null;
const pendingNodeKey='routepilot-pending-subscription-exit';
function rememberSubscriptionNode(provider,name){
 subscriptionSelections.set(provider,name);
 localStorage.setItem('routepilot-subscription-exits',JSON.stringify([...subscriptionSelections]));
}
function persistNodeCache(){
 try{
   const cache=JSON.stringify([...subscriptionNodes]);
   if(localStorage.getItem('routepilot-subscription-nodes')!==cache)localStorage.setItem('routepilot-subscription-nodes',cache);
 }catch(error){console.warn('Could not cache subscription nodes:',error)}
}
async function readOfflineNodes(name){
 if(!name)return;
 const nodes=await native.invoke('subscription_nodes',{name}).catch(()=>null);
 if(!Array.isArray(nodes)||!savedSubscriptions.some(item=>item.name===name))return;
 subscriptionNodes.set(name,nodes);
 persistNodeCache();
 if(current==='nodes'&&name===selectedLiveSubscription)renderNodes();
}
function saveSubscriptionCardData(name, updatedAt, usage){
 const old=subscriptionCardData.get(name)||{};
 const hasNewUsage=usage&&Object.keys(usage).length&&(!old.usage||updatedAt>=(old.usageAt||0));
 const next={updatedAt:Math.max(old.updatedAt||0,updatedAt||0),usage:hasNewUsage?usage:old.usage,usageAt:hasNewUsage?updatedAt:old.usageAt};
 if(JSON.stringify(old)===JSON.stringify(next))return;
 subscriptionCardData.set(name,next);
 try{localStorage.setItem('routepilot-subscription-card-data',JSON.stringify([...subscriptionCardData]))}
 catch(error){console.warn('Could not cache subscription metadata:',error)}
}
async function loadSubscriptionCardData(name, refresh=false){
 if(!refresh&&subscriptionCardReads.has(name))return '';
 subscriptionCardReads.add(name);
 const showError=message=>{
   if(!refresh&&(current==='subscriptions'||(current==='nodes'&&selectedLiveSubscription===name)))notify(message,true);
 };
 try{
   const data=await native.invoke('subscription_card_metadata',{name});
   if(!savedSubscriptions.some(item=>item.name===name))return '';
   saveSubscriptionCardData(name,data.updatedAt?data.updatedAt*1000:0,data.usage);
   if(Array.isArray(data.nodes)&&data.nodes.length){
     subscriptionNodes.set(name,data.nodes);
     persistNodeCache();
   }
   if(data.error)showError(data.error);
   if(current==='subscriptions')renderSubscriptions();
   if(current==='nodes'&&selectedLiveSubscription===name)renderNodes();
   return data.error||'';
 }catch(error){
   console.warn('Could not read subscription metadata:',error);
   showError('订阅读取失败');
   return '订阅读取失败';
 }
}
function loadSubscriptionCards(){
 for(const {name} of savedSubscriptions)loadSubscriptionCardData(name);
}
function loadSelectedRemoteSubscription(){
 if(savedSubscriptions.some(item=>item.name===selectedLiveSubscription&&item.type==='http')){
   loadSubscriptionCardData(selectedLiveSubscription);
 }
}
let visibleProfile=null;
let lastRunningState=null;
let connectionHistory=[];
let logReadSequence=0;
let savingSubscription=false;
async function readSavedSubscriptions(){
 const sequence=++subscriptionRead;
 if(changingSubscription)return;
 const {profile}=await native.invoke('configured_profile_summary');
 if(sequence!==subscriptionRead||changingSubscription)return;
 if(profile.subscriptionScope)scopeMigrationAttempted=false;
 if(!scopeMigrationAttempted&&!profile.subscriptionScope&&profile.providers.length){
   scopeMigrationAttempted=true;
   const preferred=profile.providers.find(item=>item.name===selectedLiveSubscription)?.name;
   await switchSubscription(preferred||profile.providers[0].name);
   return;
 }
 applySubscriptionProfile(profile);
 if(current==='nodes'){renderNodes();loadSelectedRemoteSubscription()}
 void readOfflineNodes(selectedLiveSubscription);
 if(current==='subscriptions')loadSubscriptionCards();
}
function applySubscriptionProfile(profile){
 savedSubscriptions=profile.providers;
 for(const name of subscriptionCardData.keys()){
   if(!savedSubscriptions.some(item=>item.name===name)){
     subscriptionCardData.delete(name);
     subscriptionCardReads.delete(name);
   }
 }
 selectedLiveSubscription=profile.subscriptionScope||'';
 if(selectedLiveSubscription)localStorage.setItem(subscriptionSelectionKey,selectedLiveSubscription);
 else localStorage.removeItem(subscriptionSelectionKey);
 renderSubscriptions();
}
function routingRuleStatus(){
 if(changingSubscription)return ['正在切换配置',''];
 if(db.routingMode!=='rule')return ['仅规则模式生效',''];
 if(!liveStatus?.running)return ['代理服务未启动',''];
 if(!liveCore)return ['正在读取规则状态',''];
 return [liveStatus.systemProxy||liveStatus.tun?'当前规则已生效':'本地监听已应用',' text-green'];
}
function renderRoutingScope(){
 const source=visibleProfile?.subscriptionScope;
 const [status]=routingRuleStatus();
 setLiveMarkup($('groupsScope'),'<span class="text-tag text-blue">'+(source?'订阅配置 · '+esc(source):'默认配置')+'</span><span class="sub">'+(source?'仅此订阅 · ':'未选择订阅时使用 · ')+status+'</span>');
}
function rememberGroupSelection(scope,group,name){
 groupSelections.set(JSON.stringify([scope,group]),name);
 localStorage.setItem('routepilot-scoped-group-exits',JSON.stringify([...groupSelections]));
}
async function restoreGroupSelections(snapshot){
 if(!visibleProfile)return;
 const scope=visibleProfile.subscriptionScope||'';
 if(restoredGroupScope===scope)return;
 const exits=snapshot.proxies?.proxies;
 for(const {name:group} of visibleProfile.groups||[]){
   const live=exits?.[group];
   if(live?.type!=='Selector'||!live.all?.length)continue;
   const saved=groupSelections.get(JSON.stringify([scope,group]));
   const name=live.all.includes(saved)?saved:scope||restoredGroupScope?live.all[0]:live.now;
   if(name&&name!==live.now){
     await native.invoke('mihomo_select_group',{group,name});
     live.now=name;
   }
 }
 restoredGroupScope=scope;
}
async function switchSubscription(name){
 if(changingSubscription||networkUpdating||selectingNode||changingMode)return false;
 changingSubscription=true;
 pendingSubscription=name;
 $('subscriptionList').setAttribute('aria-busy','true');
 renderSubscriptions();
 if(current==='rules')renderRules();
 syncTray();
 try{
   const previous=visibleProfile?.subscriptionScope||'';
   for(const {name:group} of visibleProfile?.groups||[]){
     const live=liveCore?.proxies?.proxies?.[group];
     if(live?.type==='Selector'&&live.now&&!groupSelections.has(JSON.stringify([previous,group]))){
       rememberGroupSelection(previous,group,live.now);
     }
   }
   const profile=await native.invoke('set_subscription_scope',{name:name||null});
   applySubscriptionProfile(profile);
   const remembered=subscriptionSelections.get(name);
   if(remembered)localStorage.setItem(pendingNodeKey,JSON.stringify([name,remembered]));
   document.dispatchEvent(new CustomEvent('routepilot:profile-visible',{detail:profile}));
   return true;
 }catch(error){
   notify(String(error),true);
   return false;
 }finally{
   changingSubscription=false;
   pendingSubscription='';
   $('subscriptionList').setAttribute('aria-busy','false');
   renderSubscriptions();
   if(current==='rules')renderRules();
   document.dispatchEvent(new Event('routepilot:profile-changed'));
 }
}
const liveDelays=new Map();
const liveInvocations=new Map();
const internalSpeedGroup='RoutePilot.Internal.SpeedTest';
const hiddenNodeNames=new Set(['PASS','PASS-RULE','COMPATIBLE','REJECT-DROP',internalSpeedGroup]);
const isTestableNode=item=>item&&!hiddenNodeNames.has(item.name)&&!subscriptionPolicies.some(policy=>policy.name===item.name);
function realNodes(){
 if(!liveCore){
   return [{name:'DIRECT',type:'Direct'},{name:'REJECT',type:'Reject'},...(visibleProfile?.nodes||[])];
 }
 const list=new Map(Object.values(liveCore?.proxies?.proxies||{}).filter(item=>item.name!=='GLOBAL').map(item=>[item.name,item]));
 for(const [provider,entry] of Object.entries(liveCore?.providers?.providers||{})){
   if(entry.vehicleType==='Compatible')continue;
   for(const node of entry.proxies||[])if(!list.has(node.name))list.set(node.name,{...node,provider});
 }
 return [...list.values()].filter(item=>!hiddenNodeNames.has(item.name));
}
function activeSubscriptionNodes(){
 const provider=selectedLiveSubscription;
 if(!provider)return [];
 const nodes=liveCore?.providers?.providers?.[provider]?.proxies??subscriptionNodes.get(provider)??[];
 return nodes.filter(isTestableNode).map(node=>({...node,provider}));
}
const subscriptionPolicies=[
 {name:'DIRECT',type:'直连'},
 {name:'REJECT',type:'拒绝'},
 {name:'AUTO',type:'自动选择'}
];
function subscriptionNodeCards(){
 if(!selectedLiveSubscription)return [];
 const automatic=liveCore?.proxies?.proxies?.AUTO;
 const policies=subscriptionPolicies.map(policy=>({
   ...policy,provider:selectedLiveSubscription,policy:true,
   now:policy.name==='AUTO'?automatic?.now:undefined
 }));
 return [...policies.slice(0,2),...activeSubscriptionNodes(),policies[2]];
}
async function rememberLiveNodes(snapshot){
 const providers=snapshot.providers?.providers||{};
 const global=snapshot.proxies?.proxies?.GLOBAL;
 const pending=localStorage.getItem(pendingNodeKey);
 const [provider,name]=pending?JSON.parse(pending):[];
 for(const {name:source} of savedSubscriptions){
   const providerData=providers[source];
   const updatedAt=Date.parse(providerData?.updatedAt||'');
   if(providerData?.subscriptionInfo||new Date(updatedAt).getFullYear()>1970){
     saveSubscriptionCardData(source,new Date(updatedAt).getFullYear()>1970?updatedAt:0,providerData.subscriptionInfo);
   }
   const nodes=providerData?.proxies;
   if(!Array.isArray(nodes))continue;
   subscriptionNodes.set(source,nodes.map(({name,type})=>({name,type})));
   if(source!==provider&&global?.now&&nodes.some(node=>node.name===global.now)&&subscriptionSelections.get(source)!==global.now){
     rememberSubscriptionNode(source,global.now);
   }
 }
 persistNodeCache();
 if(!pending||provider!==selectedLiveSubscription||snapshot.config?.mode==='rule'||global?.type!=='Selector')return;
 const belongs=subscriptionPolicies.some(policy=>policy.name===name)||providers[provider]?.proxies?.some(node=>node.name===name);
 if(!belongs||!global.all?.includes(name))return;
 if(global.now!==name)await native.invoke('mihomo_select',{name});
 global.now=name;
 rememberSubscriptionNode(provider,name);
 if(localStorage.getItem(pendingNodeKey)===pending)localStorage.removeItem(pendingNodeKey);
}
async function readConnectionLogs(clear=false){
 const sequence=++logReadSequence;
 const rows=await native.invoke('connection_log_rows',{clear});
 if(sequence!==logReadSequence)return;
 connectionHistory=rows;
 if(current==='logs')renderLogs();
}
function realOverview(){
 const mode=liveCore?.config?.mode;
 const capture=[liveStatus?.systemProxy?'Windows 系统代理':'',liveStatus?.tun?'全局 TUN（实验）':''].filter(Boolean).join(' + ');
 const upstream=liveCore?.proxies?.proxies?.GLOBAL?.now;
 return {
   title:liveStatus?.running?'代理服务运行中':'代理服务未启动',
   status:networkUpdating?'正在更新代理…':capture?'接管已启用':liveStatus?.running?'本地监听':'未接管',
   capture,
   summary:liveStatus?.running?(mode==='global'&&upstream?'全局出口 · '+upstream:'路由模式 · '+(mode||'读取中')):liveStatus?.configured?'当前未接管系统流量。':'在订阅页添加订阅或导入本地配置。',
   traffic:!!liveCore
 };
}
function recordLiveTraffic(connection){
 const down=connection?.downloadTotal,up=connection?.uploadTotal;
 const time=performance.now();
 if(!Number.isFinite(down)||!Number.isFinite(up)){
   liveTotals=null;
   $('downloadNow').textContent=$('uploadNow').textContent='—';
   $('downloadTotal').textContent=$('uploadTotal').textContent='—';
   return;
 }
 const elapsed=(time-(liveTotals?.time||time))/1000;
 const mb=1024*1024;
 const downRate=elapsed>0?Math.max(0,down-liveTotals.down)/elapsed/mb:0;
 const upRate=elapsed>0?Math.max(0,up-liveTotals.up)/elapsed/mb:0;
 liveTotals={time,down,up};
 trafficSamples.push({down:downRate,up:upRate});
 trafficSamples.shift();
 $('downloadNow').textContent=downRate.toFixed(2)+' MB/s';
 $('uploadNow').textContent=upRate.toFixed(2)+' MB/s';
 $('downloadTotal').textContent=fmtMB(down/mb);
 $('uploadTotal').textContent=fmtMB(up/mb);
 paintTraffic();
}
function refreshRealData(afterChange=false){
 if(!native)return Promise.resolve();
 if(liveRefresh){
   if(afterChange)refreshAgain=true;
   return liveRefresh;
 }
 liveRefresh=(async()=>{
   do{
     refreshAgain=false;
     await readRealData();
   }while(refreshAgain);
 })().finally(()=>{liveRefresh=null});
 return liveRefresh;
}
function waitForLocalCoreStart(){return localCoreStart}
function ensureLocalCore(){
 if(networkUpdating)return Promise.reject(new Error('正在更新代理，请稍后重试。'));
 if(localCoreStart)return localCoreStart;
 if(liveStatus?.running&&liveCore)return Promise.resolve(true);
 localCoreStart=(async()=>{
   const status=await native.invoke('core_status');
   if(!status.configured)return false;
   if(!status.available)throw new Error('缺少代理组件，请先安装。');
   if(!status.running)await native.invoke('start_local_core');
   await refreshRealData(true);
   if(!liveCore)throw new Error(liveError||'暂时无法读取运行中的节点。');
   return true;
 })().finally(()=>{localCoreStart=null;if(current==='nodes')renderNodes()});
 if(current==='nodes')renderNodes();
 return localCoreStart;
}
async function readRealData(){
 try{
   liveStatus=await native.invoke('core_status');
   liveError='';
   if(lastRunningState!==liveStatus.running){
     lastRunningState=liveStatus.running;
     document.dispatchEvent(new Event('routepilot:core-state'));
   }
   if(liveStatus.running){
     const next=await native.invoke('mihomo_snapshot');
     if(!next.providers)next.providers=liveCore?.providers;
     await rememberLiveNodes(next).catch(error=>console.warn('Could not restore the subscription exit:',error));
     await restoreGroupSelections(next).catch(error=>console.warn('Could not restore group exits:',error));
     liveCore=next;
     if(next.config?.mode)db.routingMode=next.config.mode;
   }else{
     liveCore=null;exitIp='';
     restoredGroupScope=null;
     if(visibleProfile?.mode)db.routingMode=visibleProfile.mode;
   }
   if(current==='logs')void readConnectionLogs().catch(error=>notify(String(error),true));
   if(current==='network')void refreshWindowsNetwork();
 }catch(error){
   liveError=String(error);
 }finally{
   recordLiveTraffic(liveCore?.connections);
   if(!document.querySelector('#modalBack.show'))render();
   else syncTray();
 }
}
`);
  source = source.replace('const state=overviewState();renderNetworkDetails(state)', 'const state=native?realOverview():overviewState();renderNetworkDetails(state)');
  source = source.replace('function renderRouting(state){', `function renderRouting(state){
 if(native){
   renderRoutingScope();
   const proxies=liveCore?.proxies?.proxies;
   const global=proxies?.GLOBAL;
   $('mainTitle').textContent=state.title;
   $('policySummary').textContent=liveError||state.summary;
   $('modeText').textContent=state.capture||'未接管';
   $('power').checked=!!(liveStatus?.systemProxy||liveStatus?.tun);
   $('power').disabled=networkUpdating;
   $('globalExitField').hidden=db.routingMode!=='global'||!selectedLiveSubscription;
   const names=subscriptionNodeCards().map(node=>node.name).filter(name=>global?.all?.includes(name));
   setLiveMarkup($('globalExit'),'<option value="" disabled>请选择节点</option>'+names.map(name=>'<option value="'+esc(name)+'">'+esc(name)+'</option>').join(''));
   if(global&&document.activeElement!==$('globalExit'))$('globalExit').value=global.now;
   $('globalExit').disabled=!names.length||selectingNode;
   $('ruleDefaultField').hidden=db.routingMode!=='rule';
   const match=visibleProfile?.rules?.find(line=>line.startsWith('MATCH,'));
   const ruleDefault=$('ruleDefaultExit');
   if(document.activeElement!==ruleDefault){
     const exit=match?.split(',')[1];
     ruleDefault.innerHTML=(visibleProfile?.exits||[]).map(name=>'<option value="'+esc(name)+'" '+(name===exit?'selected':'')+'>'+esc(name)+'</option>').join('');
   }
   ruleDefault.disabled=!visibleProfile;
   $('addGlobalExit').hidden=true;
   $('homeRuleSection').hidden=db.routingMode!=='rule';
   $('trafficScope').textContent=liveCore?'代理流量':'暂无流量数据';
   for(const option of document.querySelectorAll('[name="routingMode"]')){
     option.checked=option.value===db.routingMode;option.disabled=!visibleProfile;
   }
   syncTray();
   // System settings are controlled from the dedicated native panel.
   for(const option of document.querySelectorAll('[data-network]')){
     option.checked=option.dataset.network==='tun'?!!liveStatus?.tun:!!liveStatus?.systemProxy;
   }
   return;
 }
`);
  source = source.replace("$('groupCount').textContent=db.groups.length;$('ruleCount').textContent=db.rules.length;$('nodeCount').textContent=db.nodes.length;$('overviewConfigs').innerHTML=db.rules.filter(r=>r.on).length+' <em>条已启用规则</em>';", `if(native){
 const rules=liveCore?.rules?.rules||[];
 const proxies=realNodes();
 const storedRules=(visibleProfile?.rules||[]).filter(rule=>!rule.startsWith('MATCH,'));
 $('groupCount').textContent=visibleProfile?.groups?.length??0;
 $('nodeCount').textContent=proxies.filter(p=>!Array.isArray(p.all)&&!['Direct','Reject','Pass'].includes(p.type)).length;
 $('ruleCount').textContent=storedRules.length;
 $('overviewConfigs').textContent=liveCore?rules.length+' 条内核规则':storedRules.length?storedRules.length+' 条已配置规则':'—';
 }else{
 $('groupCount').textContent=db.groups.length;$('ruleCount').textContent=db.rules.length;$('nodeCount').textContent=db.nodes.length;$('overviewConfigs').innerHTML=db.rules.filter(r=>r.on).length+' <em>条已启用规则</em>';
 }`);
  source = source.replace('function renderNetworkDetails(state){', `function renderNetworkDetails(state){
 if(native){
   state=realOverview();
   const config=liveCore?.config||{};
   $('detailMixedPort').textContent=config['mixed-port']||(visibleProfile?.mixed?visibleProfile.mixed+'（未监听）':'—');
   $('detailHttpPort').textContent=config.port||(visibleProfile?.http&&!liveCore?visibleProfile.http+'（未监听）':'—');
   $('detailSocksPort').textContent=config['socks-port']||(visibleProfile?.socks&&!liveCore?visibleProfile.socks+'（未监听）':'—');
   $('detailMode').textContent=config.mode||visibleProfile?.mode||'—';
   $('detailCapture').textContent=state.capture||'未接管';
   $('detailGlobalExit').textContent=liveCore?.proxies?.proxies?.GLOBAL?.now||'—';
   $('detailRuleExit').textContent=liveCore?.rules?.rules?.findLast(rule=>rule.type==='Match')?.proxy
     ||visibleProfile?.ruleExits?.[visibleProfile.rules?.findLastIndex(rule=>rule.startsWith('MATCH,'))]||'—';
   $('detailLocalIp').textContent=networkDetails?.error?'读取失败':networkDetails?.addresses?.join('、')||'—';
   $('detailSystemDns').textContent=networkDetails?.error?'读取失败':networkDetails?.dns?.join('、')||'—';
   $('detailExitIp').textContent=exitIp||'未检测';
   $('checkExitIp').disabled=!liveCore||!(config.port||config['mixed-port']);
   return;
 }
`);
  source = source.replace('function testNode(nodeId){', `function testNode(nodeId){
 if(native){
   const node=subscriptionNodeCards().find(item=>item.name===nodeId);
   if(networkUpdating||changingSubscription||!node||!(node.name==='AUTO'||isTestableNode(node)))return;
   const key=JSON.stringify([node.provider,nodeId]);
   if(liveInvocations.has(key))return liveInvocations.get(key);
   const task=ensureLocalCore().then(async ready=>{
     if(node.provider!==selectedLiveSubscription||changingSubscription)return;
     if(!ready)throw new Error('测速失败');
     const result=await native.invoke('mihomo_delay',{name:nodeId,provider:node.policy?null:node.provider});
     liveDelays.set(key,result);
   }).catch(()=>liveDelays.set(key,'测速失败')).finally(()=>{
     liveInvocations.delete(key);renderNodes();
   });
   liveInvocations.set(key,task);
   renderNodes();
   return task;
 }
`);
  source = source.replace('renderRules();renderGroups();renderNodes();renderSubscriptions();renderRunning();renderLogs();', "if(native){({overview:renderRules,rules:renderRules,groups:renderGroups,nodes:renderNodes,subscriptions:renderSubscriptions,processes:renderRunning,logs:renderLogs})[current]?.()}else{renderRules();renderGroups();renderNodes();renderSubscriptions();renderRunning();renderLogs();}");
  source = source.replace('function renderNodes(){', `function renderNodes(){
 if(native){
   const nodes=subscriptionNodeCards();
   const global=liveCore?.proxies?.proxies?.GLOBAL;
   const hint=$('nodeSelectionHint');
   const canSelect=db.routingMode!=='rule';
   hint.hidden=true;
   const hasTests=nodes.some(node=>!node.policy&&isTestableNode(node));
   const controlsBusy=networkUpdating||changingSubscription;
   const preferred=(liveCore&&canSelect?global?.now:null)||subscriptionSelections.get(selectedLiveSubscription);
   const selectedName=nodes.some(node=>node.name===preferred)?preferred:'AUTO';
   $('testAllNodes').hidden=!hasTests;
   $('testAllNodes').disabled=controlsBusy||batchTesting||!hasTests;
   $('testAllNodes').textContent=batchTesting?'测速中…':'全部测速';
   setLiveMarkup($('nodeList'),nodes.map(item=>{
     const usable=item.name==='AUTO'?hasTests:isTestableNode(item);
     const selectable=canSelect&&(!liveCore||(global?.type==='Selector'&&global.all?.includes(item.name)));
     const selected=selectedName===item.name;
     const name=esc(item.name);
     const key=JSON.stringify([item.provider,item.name]);
     const value=liveDelays.get(key);
     let results='';
     const testing=liveInvocations.has(key);
     if(testing)results='测速中…';
     else if(typeof value==='string')results=testErrorBadge(value);
     else if(value){
       const speed=value.mbps;
       const rate=typeof speed==='number'?'<span class="speed-value speed-'+(speed>=100?'fast':speed>=50?'medium':'slow')+'">'+esc(speed.toFixed(1))+' Mbps</span>':testErrorBadge('下载测试失败');
       results=(typeof value.delay==='number'?latencyBadge(value.delay):testErrorBadge('延迟测试失败'))+' · '+rate;
     }
     const selection=selectable?'<button type="button" class="node-select-hit" data-live-node="'+name+'" aria-pressed="'+selected+'" aria-label="设为全局出口 '+name+'"></button>':'';
     const test=usable?'<div class="node-actions"><button type="button" class="icon-btn" data-test-node="'+name+'" aria-label="测速 '+name+'" title="'+(testing?'测速中…':'测速')+'"'+(controlsBusy||testing?' disabled':'')+'>'+nodeIcon('test')+'</button></div>':'';
     const metrics=results&&usable?'<span class="node-metrics">'+results+'</span>':'';
     return '<article class="node-tile'+(selectable?' selectable':'')+(selected?' selected':'')+'"><div class="node-tile-top"><div class="node-label"><strong>'+name+'</strong><small class="node-meta"><span>'+esc(item.type)+(item.now?' · '+esc(item.now):'')+'</span>'+metrics+'</small></div>'+selection+test+'</div></article>';
   }).join('')||'<div class="card empty">'+(selectedLiveSubscription?'暂无节点':'请选择订阅')+'</div>');
   return;
 }
`);
  source = source.replace("try{await Promise.all(db.nodes.filter(n=>!n.retired).map(n=>testNode(n.id)))}", `try{
   if(!native){await Promise.all(db.nodes.filter(n=>!n.retired).map(n=>testNode(n.id)));return}
   const nodes=activeSubscriptionNodes();
   if(!nodes.length||networkUpdating||changingSubscription)return;
   if(!await ensureLocalCore())throw new Error('测速失败');
   for(const node of nodes){
     if(!liveStatus?.running||node.provider!==selectedLiveSubscription||changingSubscription)break;
     await testNode(node.name);
   }
 }catch(error){
   if(native)notify('测速失败',true);
   else throw error;
 }`);
  source = source.replace('function renderLogs(){', `function renderLogs(){
 if(native){
   $('logRows').innerHTML=connectionHistory.map(item=>{
     return '<tr><td>'+esc(item.time)+'</td><td>'+esc(item.app||'—')+'</td><td>'+esc(item.target)+'</td><td>'+esc(item.protocol)+'</td><td>'+esc(item.exit)+'</td><td>'+(item.failed?testErrorBadge(item.decision):esc(item.decision||'—'))+'</td></tr>';
   }).join('')||'<tr><td colspan="6" class="empty">暂无连接记录</td></tr>';
   return;
 }
`);
  source = source.replace('function renderRules(){', `function renderRules(){
 if(native){
   const [status,tone]=routingRuleStatus();
   const source=visibleProfile?.subscriptionScope;
   const scope=source?'订阅 · '+source:'默认配置';
   const scopeTag='<span class="rule-config-name" title="'+esc(scope)+'">'+esc(scope)+'</span>';
   const keyword=$('ruleSearch').value.toLowerCase();
   const configured=(visibleProfile?.rules||[]).map((line,index)=>{
     const [type,payload]=line.split(',');
     const proxy=visibleProfile.ruleExits?.[index];
     const enabled=!visibleProfile.disabledRules?.includes(line);
     return {type,payload:type==='MATCH'?'':payload,proxy,line,index,enabled,active:enabled&&!visibleProfile.disabledGroups?.includes(proxy)};
   });
   const kindOf=rule=>String(rule.type).replaceAll('-','').toLowerCase();
   const rules=configured.filter(rule=>{
     const type=kindOf(rule);
     const matchesFilter=filter==='all'||(filter==='website'&&type.startsWith('domain'))||(filter==='app'&&type.startsWith('process'));
     return matchesFilter&&[rule.type,rule.payload,rule.proxy].join(' ').toLowerCase().includes(keyword);
   });
   const card=(rule,preview)=>{
     const type=kindOf(rule);
     const kind=type.startsWith('domain')?'website':type.startsWith('process')?'app':'';
     const isDefault=rule.type==='MATCH';
     const label=isDefault?'默认出口':rule.payload||rule.type;
     const attrs=' data-profile-id="'+rule.index+'" data-profile-expected="'+esc(rule.line)+'"';
     const edit=rule.line&&/^(?:DOMAIN|DOMAIN-SUFFIX|PROCESS-PATH),[^,]+,[^,]+$|^MATCH,[^,]+$/.test(rule.line);
     const actions=preview?'':'<span class="rule-actions"><button type="button" class="icon-btn" data-profile-edit="rule"'+attrs+(edit?'':' disabled')+' aria-label="编辑规则">'+nodeIcon('edit')+'</button><button type="button" class="icon-btn" data-profile-remove="rule"'+attrs+' aria-label="删除规则">'+nodeIcon('delete')+'</button></span>';
     const toggle=preview||rule.type==='MATCH'?'':'<div class="rule-state"><label class="switch"><input type="checkbox" aria-label="启用规则" data-profile-toggle="rule"'+attrs+(rule.enabled?' checked':'')+'><i></i></label></div>';
     const icon=kind==='app'?programIconForPath(rule.payload):kind==='website'?assetIcon(kind,label,label):'';
     const kindLabel=isDefault?'':'<span class="text-tag rule-kind" data-kind="'+kind+'">'+esc(rule.type)+'</span>';
     const details=isDefault&&preview?'':'<small>'+kindLabel+(preview?'':scopeTag)+'</small>';
     const badge=!rule.active?'<span class="text-tag text-warning">已停用</span>':preview?'':'<span class="text-tag rule-effect'+tone+'">'+status+'</span>';
     return '<article class="rule-card'+(isDefault?' default-rule':'')+'"><div class="rule-main">'+icon+'<span class="target-title"><strong>'+esc(label)+'</strong>'+details+'</span></div>'+toggle+'<div class="rule-footer"><span class="rule-meta"><span class="route-label">'+esc(rule.proxy||'—')+'</span>'+badge+'</span>'+actions+'</div></article>';
   };
   $('allRules').innerHTML=rules.map(rule=>card(rule,false)).join('')||'<div class="empty rules-empty">'+scopeTag+'<span>没有匹配的规则</span></div>';
   $('homeRules').innerHTML=configured.filter(rule=>rule.active).slice(0,6).map(rule=>card(rule,true)).join('')||'<div class="empty">暂无规则</div>';
   return;
 }
`);
  source = source.replace('function renderGroups(){', `function renderGroups(){
 if(native){
   if(document.activeElement?.matches('[data-live-group]'))return;
   const groups=visibleProfile?.groups||[];
   setLiveMarkup($('groupList'),groups.map(group=>{
     const name=esc(group.name);
     const live=liveCore?.proxies?.proxies?.[group.name];
     const targets=(visibleProfile.rules||[]).map((line,index)=>({line,index}))
       .filter(item=>visibleProfile.ruleExits?.[item.index]===group.name&&!item.line.startsWith('MATCH,'));
     const editable=['select','url-test','fallback'].includes(group.type);
     const controls='<div class="group-icons"><label class="group-power" title="仅在规则模式中启用或停用该分组的目标"><span class="switch"><input type="checkbox" aria-label="启用分组 '+name+'" data-profile-toggle="group" data-profile-id="'+name+'"'+(group.enabled?' checked':'')+'><i></i></span></label><button type="button" class="icon-btn" data-profile-edit="group" data-profile-id="'+name+'"'+(editable?'':' disabled')+' aria-label="编辑分组">'+nodeIcon('edit')+'</button><button type="button" class="icon-btn" data-profile-remove="group" data-profile-id="'+name+'" aria-label="删除分组">'+nodeIcon('delete')+'</button></div>';
     const selection=live?.type==='Selector'?'<select class="select" aria-label="当前出口" data-live-group="'+name+'">'+live.all.map(member=>'<option value="'+esc(member)+'" '+(member===live.now?'selected':'')+'>'+esc(member)+'</option>').join('')+'</select>':'<span class="sub">'+esc(live?.now||[...(group.proxies||[]),...(group.use||[])].join('、')||'—')+'</span>';
     const members=targets.map(({line,index})=>{
       const [type,target]=line.split(',');
       const icon=type.startsWith('PROCESS-')?programIconForPath(target):'';
       return '<div class="group-target-line"><span class="group-target-name">'+icon+'<span>'+esc(target)+'</span></span><button type="button" class="icon-btn" data-profile-remove="member" data-profile-id="'+index+'" data-profile-expected="'+esc(line)+'" aria-label="移出分组">'+nodeIcon('delete')+'</button></div>';
     }).join('');
     return '<article class="group-card compact-group"><div class="group-compact-head">'+groupGlyph()+'<div class="compact-group-title"><strong>'+name+'</strong><small>'+targets.length+' 个目标'+(!group.enabled?' · 已停用':'')+'</small></div>'+controls+'</div><div class="group-controls">'+selection+'</div>'+(members?'<div class="group-members">'+members+'</div>':'')+'</article>';
   }).join('')||'<div class="card empty">暂无分组</div>');
   return;
 }
`);
  source = source.replace('function renderSubscriptions(){', `function renderSubscriptions(){
 if(native){
   setLiveMarkup($('subscriptionList'),savedSubscriptions.map(saved=>{
     const name=esc(saved.name);
     const remove='<button type="button" class="icon-btn" data-profile-remove="provider" data-profile-id="'+name+'" aria-label="移除订阅">'+nodeIcon('delete')+'</button>';
     const refresh='<button class="icon-btn" data-live-provider="'+name+'" aria-label="刷新订阅">'+nodeIcon('test')+'</button>';
     const selected=selectedLiveSubscription===saved.name;
     const remote=saved.type==='http';
     const {updatedAt,usage}=subscriptionCardData.get(saved.name)||{};
     const bytes=value=>{
       const unit=value>0?Math.min(4,Math.floor(Math.log(value)/Math.log(1024))):0;
       return (value/1024**unit).toLocaleString(undefined,{maximumFractionDigits:2})+' '+['B','KB','MB','GB','TB'][unit];
     };
     const used=(usage?.Upload||0)+(usage?.Download||0);
     const days=updatedAt?Math.max(0,Math.floor((Date.now()-updatedAt)/86400000)):null;
     const date=value=>new Date(value).toLocaleDateString();
     const source=remote?'<div class="subscription-source"><span>'+esc(saved.source||'远程订阅')+'</span>'+(days===null?'':'<span title="'+esc(date(updatedAt))+'">'+(days?days+' 天前':'今天')+'</span>')+'</div>':'';
     const hasQuota=remote&&usage?.Total>0;
     const traffic=hasQuota?'<span>'+esc(bytes(used)+' / '+bytes(usage.Total))+'</span>'
       :remote&&(Number.isFinite(usage?.Upload)||Number.isFinite(usage?.Download))?'<span>'+esc('已用 '+bytes(used))+'</span>':'';
     const expiry=remote&&usage?.Expire>0?'<time title="到期日期">'+esc(date(usage.Expire*1000))+'</time>':'';
     const localDate=!remote&&updatedAt?'<time title="文件日期">'+esc(date(updatedAt))+'</time>':'';
     const detail=(traffic||expiry||localDate?'<div class="subscription-meta">'+traffic+(expiry||localDate)+'</div>':'')
       +(hasQuota?'<progress class="subscription-usage" aria-label="已用流量" max="'+usage.Total+'" value="'+Math.min(used,usage.Total)+'"></progress>':'');
     const restore=saved.ruleExitDisabled?'<button type="button" class="btn" data-restore-subscription-exit="'+name+'">恢复规则出口</button>':'';
     const note=pendingSubscription===saved.name?'<span class="sub">正在切换配置…</span>':'';
     return '<article data-live-subscription="'+name+'" class="card node-tile subscription-card'+(selected?' selected':'')+'"><div class="subscription-heading"><button type="button" class="subscription-select" aria-pressed="'+selected+'"'+(changingSubscription?' disabled':'')+'><strong>'+name+'</strong></button><div class="subscription-actions">'+refresh+remove+'</div></div>'+source+restore+detail+note+'</article>';
   }).join('')||'<div class="card empty">还没有订阅。在上方粘贴 HTTPS 订阅链接即可添加。</div>');
   return;
 }
`);
  source = source.replace('function testSite(button){', `function testSite(button){
 if(native){
   if(siteTests.has(button))return siteTests.get(button);
   const output=button.previousElementSibling;
   button.setAttribute('aria-disabled','true');
   output.textContent='测速中…';
   output.className='site-result';
   output.removeAttribute('title');
   const task=ensureLocalCore().then(ready=>{
     if(!ready)throw new Error('请先添加订阅或导入配置。');
     return native.invoke('mihomo_website_probe',{host:button.dataset.testSite});
   })
     .then(result=>{output.textContent=result.ms+' ms · HTTP '+result.status;output.className='site-result speed-value '+(result.status>=400?'test-error':latencyClass(result.ms))})
     .catch(error=>{output.textContent='请求失败';output.title=String(error);output.className='site-result speed-value test-error'})
     .finally(()=>{siteTests.delete(button);button.removeAttribute('aria-disabled')});
   siteTests.set(button,task);
   return task;
 }
`);
  inject("current=tabs.some(", `
if(native){
 document.documentElement.classList.add('desktop-live');
 const scope=document.createElement('div');
 scope.className='routing-scope';
 scope.id='groupsScope';
 scope.setAttribute('role','status');
 $('groups').querySelector('.page-scroll').before(scope);
 document.querySelector('.sidefoot').innerHTML='<b>RoutePilot Desktop</b>Windows';
 const powerLabel=document.querySelector('.overview-power');
 powerLabel.querySelector('span').textContent='代理总开关';
 powerLabel.title='开启系统代理；关闭时停止系统代理、TUN 和本地监听。';
 document.querySelector('#network .network-note').hidden=true;
 document.addEventListener('routepilot:desktop-message',event=>notify(event.detail));
 document.addEventListener('routepilot:core-state',()=>{
   void refreshRealData(true);
 });
 document.addEventListener('routepilot:network-updating',event=>{
   networkUpdating=event.detail;
   document.querySelectorAll('[data-network]').forEach(input=>input.disabled=networkUpdating);
   render();
 });
 document.addEventListener('routepilot:profile-visible',event=>{
   visibleProfile=event.detail;
   if(!liveCore&&visibleProfile?.mode)db.routingMode=visibleProfile.mode;
   renderRoutingScope();
   renderRules();
   renderGroups();
   renderNodes();
   renderRunning();
 });
 $('checkExitIp').hidden=false;
 $('checkExitIp').onclick=async()=>{
   const button=$('checkExitIp');
   button.disabled=true;
   try{exitIp=await native.invoke('mihomo_exit_ip')}
   catch(error){exitIp='';notify(String(error))}
   finally{renderNetworkDetails(realOverview())}
 };
 async function selectLiveNode(name,fromTray=false){
   const global=liveCore?.proxies?.proxies?.GLOBAL;
   if(selectingNode||changingMode||changingSubscription||networkUpdating||db.routingMode==='rule'||global?.type!=='Selector'||!global.all?.includes(name))return;
   selectingNode=true;
   render();
   try{
     await native.invoke('mihomo_select',{name});
     const global=liveCore?.proxies?.proxies?.GLOBAL;
     if(global)global.now=name;
     if(subscriptionNodeCards().some(node=>node.name===name))rememberSubscriptionNode(selectedLiveSubscription,name);
     localStorage.removeItem(pendingNodeKey);
     render();
     notify((db.routingMode==='direct'?'已预选全局出口 ':'全局出口已切换至 ')+name);
     await refreshRealData(true);
   }catch(error){
     if(fromTray)await native.invoke('show_routepilot').catch(()=>{});
     notify(String(error),true);
   }finally{
     selectingNode=false;
     render();
   }
 }
 async function changeLiveMode(mode,fromTray=false){
   if(changingMode||selectingNode||changingSubscription||networkUpdating||mode===db.routingMode){render();return}
   changingMode=true;
   syncTray();
   try{
     const profile=await native.invoke('edit_core_profile',{edit:{kind:'mode',mode}});
     db.routingMode=profile.mode;
     document.dispatchEvent(new Event('routepilot:profile-changed'));
     await refreshRealData(true);
   }catch(error){
     if(fromTray)await native.invoke('show_routepilot').catch(()=>{});
     notify(String(error));
   }finally{
     changingMode=false;
     render();
   }
 }
 void window.__TAURI__.event?.listen('routepilot-tray-action',({payload})=>{
   const separator=payload.indexOf(':');
   const control=payload.slice(0,separator);
   const value=payload.slice(separator+1);
   if(networkUpdating||selectingNode||changingMode||changingSubscription)return;
   if(control==='node')void selectLiveNode(value,true);
   else if(control==='mode'&&['rule','global','direct'].includes(value))void changeLiveMode(value,true);
   else if(['power','system','tun'].includes(control)&&['on','off'].includes(value)){
     document.dispatchEvent(new CustomEvent('routepilot:network-control',{detail:{control:control==='power'?'core':control,enabled:value==='on',fromTray:true}}));
   }
 }).catch(error=>console.warn('Could not listen for RoutePilot tray actions:',error));
 $('uiLanguage').addEventListener('change',syncTray);
 document.addEventListener('click',event=>{
   const button=event.target.closest('[data-live-node],[data-live-provider]');
   if(!button)return;
   if(button.dataset.liveNode){
     const name=button.dataset.liveNode;
     if(!liveCore&&db.routingMode!=='rule'&&subscriptionNodeCards().some(node=>node.name===name)){
       rememberSubscriptionNode(selectedLiveSubscription,name);
       localStorage.setItem(pendingNodeKey,JSON.stringify([selectedLiveSubscription,name]));
       renderNodes();
     }else void selectLiveNode(name);
   }
   else if(button.dataset.liveProvider){
     const metadata=loadSubscriptionCardData(button.dataset.liveProvider,true);
     const refresh=async()=>{
       if(!await ensureLocalCore())throw new Error('请先添加订阅或导入配置。');
       await native.invoke('mihomo_refresh_provider',{name:button.dataset.liveProvider});
       await refreshRealData(true);
       notify('订阅已刷新');
     };
     void refresh().catch(async()=>notify(await metadata||'订阅刷新失败',true));
   }
 });
 document.addEventListener('change',event=>{
   const field=event.target;
   if(field.name==='routingMode'){
     event.stopImmediatePropagation();
     void changeLiveMode(field.value);
     return;
   }
   if(field.id==='globalExit'){
     event.stopImmediatePropagation();
     void selectLiveNode(field.value);
     return;
   }
   if(field.id==='ruleDefaultExit'){
     event.stopImmediatePropagation();
     document.dispatchEvent(new CustomEvent('routepilot:default-exit',{detail:field.value}));
     return;
   }
   if(field.id==='power'||field.dataset.network){
     event.stopImmediatePropagation();
     const control=field.dataset.network||'power';
     const enabled=field.checked;
     field.checked=control==='power'?!!(liveStatus?.systemProxy||liveStatus?.tun):!!liveStatus?.[control==='system'?'systemProxy':'tun'];
     if(changingSubscription)return;
     document.dispatchEvent(new CustomEvent('routepilot:network-control',{detail:{control,enabled}}));
     return;
   }
   if(field.dataset.liveGroup){
     event.stopImmediatePropagation();
     if(changingSubscription)return;
     const scope=visibleProfile?.subscriptionScope||'';
     const group=field.dataset.liveGroup, name=field.value;
     void native.invoke('mihomo_select_group',{group,name}).then(()=>{
       rememberGroupSelection(scope,group,name);
       return refreshRealData(true);
     }).catch(error=>notify(String(error),true));
   }
 },true);
 async function copyLiveAddress(environment){
   const config=liveCore?.config;
   const http=config?.['mixed-port']||config?.port;
   const socks=config?.['mixed-port']||config?.['socks-port'];
   if(!http&&!socks){$('copyStatus').textContent='暂无运行中的代理端口。';return}
   const httpAddress=http?'http://127.0.0.1:'+http:null;
   const socksAddress=socks?'socks5://127.0.0.1:'+socks:null;
   const values=environment?{HTTP_PROXY:httpAddress,HTTPS_PROXY:httpAddress,ALL_PROXY:socksAddress}:{HTTP:httpAddress,SOCKS5:socksAddress};
   const text=Object.entries(values).filter(([,address])=>address).map(([name,address])=>{
     if(!environment)return name+': '+address;
     return db.desktop.shell==='bash'?"export "+name+"='"+address+"'":"$env:"+name+" = '"+address+"'";
   }).join(String.fromCharCode(10));
   try{
     await navigator.clipboard.writeText(text);
     $('copyStatus').textContent='已复制实际监听地址。';
   }catch{$('copyStatus').textContent='无法访问剪贴板，请手动复制地址。'}
 }
 $('copyProxy').onclick=()=>void copyLiveAddress(false);
 $('copyProxyEnv').onclick=()=>void copyLiveAddress(true);
 const savePreferences=$('backupSettings').onclick;
 const restorePreferences=$('restoreSettings').onclick;
 for(const [id,restore] of [['backupSettings',false],['restoreSettings',true]]){
   $(id).onclick=async event=>{
     const button=$(id);
     if(restore&&!await confirmDialog('恢复备份会替换当前的代理配置。',{title:'恢复设置备份',confirmLabel:'恢复'}))return;
     button.disabled=true;
     try{
       await native.invoke('core_profile_backup',{restore});
       if(restore&&localStorage.getItem('routepilot-settings-backup'))restorePreferences.call(button,event);
       if(!restore)savePreferences.call(button,event);
       else if(localStorage.getItem('routepilot-settings-backup'))restorePreferences.call(button,event);
       notify(restore?'已恢复代理配置备份':'已保存代理配置备份');
       document.dispatchEvent(new Event('routepilot:core-state'));
     }catch(error){notify(String(error))}
     finally{button.disabled=false}
   };
 }
 $('tunScope').value='all';
 $('tunScope').disabled=true;
 $('tunScope').title='TUN 接管全部受支持流量';
 document.querySelector('[data-setting="fallback"]').closest('.settings-row').hidden=true;
 for(const id of ['testTarget','testSystemProxy','testProxyFailure']){
   $(id).closest('label').hidden=true;
 }
 $('clearLogs').onclick=()=>void readConnectionLogs(true).catch(error=>notify(String(error)));
 $('testConnection').onsubmit=async event=>{
   event.preventDefault();
   const host=$('testHost').value.trim();
   try{
     if(!await ensureLocalCore())throw new Error('请先添加订阅或导入配置。');
     const result=await native.invoke('mihomo_website_probe',{host});
     notify('HTTP '+result.status+' · '+result.ms+' ms',result.status>=400||result.ms>=160);
     void readConnectionLogs().catch(error=>notify(String(error)));
   }catch(error){notify(String(error),true)}
 };
 $('subscriptions').querySelector('.import-history-title').textContent='已添加的订阅';
 $('nodeUri').placeholder='粘贴 HTTPS 订阅或节点链接';
 $('importNode').textContent='添加订阅';
 $('linkImport').onsubmit=async event=>{
   event.preventDefault();
   if(savingSubscription)return;
   const url=$('nodeUri').value.trim();
   if(!url)return;
   savingSubscription=true;
   $('importNode').disabled=true;
   try{
     const asNode=['ss','ssr','vmess','vless','trojan','hysteria','hysteria2','hy2','tuic','wireguard','anytls'].includes(url.split('://',1)[0].toLowerCase());
     const profile=asNode?await native.invoke('import_subscription_file',{name:'本地节点订阅',content:url}):await native.invoke('import_subscription_link',{url});
     savedSubscriptions=profile.providers;
     $('nodeUri').value='';
     $('importStatus').textContent='订阅已保存。';
     document.dispatchEvent(new Event('routepilot:subscription-added'));
     renderSubscriptions();
   }catch(error){$('importStatus').textContent=String(error)}
   finally{
     savingSubscription=false;
     $('importNode').disabled=!$('nodeUri').value.trim();
   }
 };
 const reloadSubscriptions=()=>void readSavedSubscriptions().catch(error=>{
   $('importStatus').textContent=String(error);
 });
 document.addEventListener('routepilot:profile-changed',reloadSubscriptions);
 document.addEventListener('routepilot:profile-changed',()=>void refreshRealData(true));
 document.addEventListener('routepilot:subscription-added',()=>{
   document.dispatchEvent(new Event('routepilot:profile-changed'));
 });
 $('subscriptionList').addEventListener('click',async event=>{
   const card=event.target.closest('[data-live-subscription]');
   if(!card||event.target.closest('.subscription-actions,[data-restore-subscription-exit]'))return;
   const name=card.dataset.liveSubscription;
   if(selectedLiveSubscription===name||!await switchSubscription(name))return;
   [...$('subscriptionList').querySelectorAll('[data-live-subscription]')].find(item=>item.dataset.liveSubscription===name)?.querySelector('.subscription-select')?.focus({preventScroll:true});
 });
 document.addEventListener('routepilot:core-state',reloadSubscriptions);
 reloadSubscriptions();
 $('webtests').querySelector('.site-test-toolbar .sub').textContent='显示网站的实际响应时间。';
 $('trafficChart').setAttribute('aria-label','代理流量折线图');
 const badge=$('trafficChart').closest('.traffic-panel')?.querySelector('.demo-chip');
 if(badge)badge.textContent='内核数据';
 void refreshRealData();
 setInterval(refreshRealData,2000);
}
`);
  source = source.replace('render();tickTraffic();setInterval(tickTraffic,1000);', 'render();if(!native){tickTraffic();setInterval(tickTraffic,1000)}');
  source = source.replace("function navigate(v){current=v;render();", "function navigate(v){current=v;render();if(native&&v==='subscriptions')loadSubscriptionCards();if(native&&v==='nodes')loadSelectedRemoteSubscription();");
  source = source.replace('function refreshAutoTests(){', 'function refreshAutoTests(){\n if(native)return;');
  source = source.replace("notify('网站模拟测速完成')", "notify(native?'网站测速请求已完成':'网站模拟测速完成')");
  source = source.replace('function renderRunning(){', `
let runningMarkup='';
function renderNativeRunning(){
 const query=$('processSearch').value.trim().toLowerCase();
 const byApp=scanType==='app';
 const rules=new Map();
 for(const line of visibleProfile?.rules||[]){
   if(!line.startsWith('PROCESS-PATH,')||visibleProfile.disabledRules?.includes(line))continue;
   const [,path,exit]=line.split(',');
   const key=normalizedPath(path);
   if(!rules.has(key))rules.set(key,exit);
 }
 const groups=new Map((visibleProfile?.groups||[]).map(group=>[group.name,group]));
 const disabledGroups=new Set(visibleProfile?.disabledGroups||[]);
 const pathRules=new Map(), nameRules=new Map();
 (visibleProfile?.processRules||[]).forEach((rule,index)=>{
   const byPath=rule.kind==='PROCESS-PATH';
   const key=byPath?normalizedPath(rule.target):rule.target.toLowerCase();
   const matches=byPath?pathRules:nameRules;
   if(!matches.has(key))matches.set(key,{exit:rule.exit,index});
 });
 const matches=item=>[item.name,item.exe,item.path,String(item.pid)].some(value=>value.toLowerCase().includes(query));
 const rows=RUNNING.filter(item=>item.type===scanType&&(matches(item)||item.members?.some(matches)));
 const markup=rows.map(item=>{
   const paths=item.paths||[item.path];
   const programs=item.members||[item];
   const targets=programs.map(program=>{
     const key=normalizedPath(program.path);
     const pathRule=pathRules.get(key), nameRule=nameRules.get(program.exe.toLowerCase());
     const active=pathRule&&(!nameRule||pathRule.index<nameRule.index)?pathRule:nameRule;
     return {active:active?.exit, configured:rules.get(key)};
   });
   const groupNames=new Set(targets.map(target=>groups.get(target.active||target.configured)?.name||'未分组'));
   const route=liveCore?.proxies?.proxies;
   const ruleMode=!!liveStatus?.running&&db.routingMode==='rule';
   const exits=new Set(targets.map(target=>{
     if(db.routingMode==='direct')return 'DIRECT';
     if(db.routingMode==='global')return route?.GLOBAL?.now||'按当前模式';
     return ruleMode&&target.active?route?.[target.active]?.now||target.active:'按目标匹配';
   }));
   const inactive=targets.some(({active,configured})=>!ruleMode?active||configured:!active&&disabledGroups.has(configured));
   const icon=programFileIcon(item.icon);
   const metric=byApp?item.instances+' 个进程':'PID '+item.pid+' · '+item.threadCount+' 个线程';
   const detailLabel=byApp?'查看所属进程':'查看线程详情';
   const detail='<button class="icon-btn" data-process-detail="'+item.pid+'" data-detail-type="'+scanType+'" title="'+detailLabel+'" aria-label="'+detailLabel+'">'+nodeIcon('details')+'</button>';
   const actionPaths=paths.length>1?' data-native-app-paths="'+esc(JSON.stringify(paths))+'" data-native-app-name="'+esc(item.name)+'"':'';
   const tun=liveStatus?.tun?'全局接管':'关闭';
   return '<article class="running-card"><div class="running-info"><div class="target">'+icon+
     '<span class="program-identity"><strong title="'+esc(item.name)+'">'+esc(item.name)+'</strong><small title="'+esc(item.path)+'"><span class="program-exe">'+esc(item.exe)+'</span><span class="process-metric">'+esc(metric)+'</span></small></span></div>'+
     '<div class="running-route"><span class="text-tag">分组 · '+esc(groupNames.size>1?'多个分组':groupNames.values().next().value)+'</span><span class="text-tag text-blue">出口 · '+esc(exits.size>1?'多个出口':exits.values().next().value)+'</span><span class="text-tag '+(liveStatus?.tun?'text-green':'')+'">TUN · '+tun+'</span>'+(inactive?'<span class="text-tag text-warning">部分或全部规则未生效</span>':'')+'</div></div>'+
     '<div class="running-actions">'+detail+'<button type="button" class="icon-btn" title="设置程序出口" aria-label="设置程序出口" data-native-program-path="'+esc(item.path)+'"'+actionPaths+'>'+nodeIcon('edit')+'</button>'+
     '<button type="button" class="icon-btn" title="加入或移动分组" aria-label="加入或移动分组" data-native-program-path="'+esc(item.path)+'"'+actionPaths+' data-native-program-group>'+nodeIcon('add')+'</button></div></article>';
 }).join('')||'<div class="card empty">没有匹配的运行目标</div>';
 if(markup!==runningMarkup){$('runningList').innerHTML=markup;runningMarkup=markup}
 document.querySelectorAll('[data-scan-type]').forEach(button=>button.classList.toggle('active',button.dataset.scanType===scanType));
}
async function showProcessDetails(item){
 const dialog=document.createElement('dialog');
 dialog.className='route-dialog process-dialog';
 setDialogHeading(dialog,item.name);
 dialog.querySelector('h2').insertAdjacentHTML('afterbegin',programFileIcon(item.icon));
 const body=document.createElement('div');
 body.className='route-dialog-body process-detail';
 const started=new Date(Number(BigInt(item.startedAt)/10000n-11644473600000n)).toLocaleString();
 body.innerHTML='<dl><dt>进程标识</dt><dd class="process-metric">PID '+item.pid+'</dd><dt>启动时间</dt><dd>'+esc(started)+'</dd><dt>可执行文件</dt><dd>'+esc(item.path)+'</dd></dl><div class="process-thread-list" aria-live="polite"><p class="sub">正在读取线程列表…</p></div><form method="dialog" class="route-dialog-actions"><button class="btn primary">关闭</button></form>';
 dialog.append(body);
 dialog.addEventListener('close',()=>dialog.remove(),{once:true});
 dialog.addEventListener('click',event=>{if(event.target===dialog)dialog.close()});
 document.body.append(dialog);
 dialog.showModal();
 const view=body.querySelector('.process-thread-list');
 try{
   const threads=await native.invoke('list_process_threads',{pid:item.pid,startedAt:item.startedAt});
   const icon=programFileIcon(item.icon);
   view.innerHTML=threads.length?'<table><thead><tr><th>线程 ID</th><th>基础优先级</th></tr></thead><tbody>'+threads.map(thread=>'<tr><td>'+icon+Number(thread.tid)+'</td><td>'+Number(thread.basePriority)+'</td></tr>').join('')+'</tbody></table>':'<p class="sub">没有可读取的线程</p>';
 }catch(error){view.textContent=String(error)}
}
function showApplicationProcesses(item){
 const dialog=document.createElement('dialog');
 dialog.className='route-dialog process-dialog';
 setDialogHeading(dialog,item.name+' · '+item.instances+' 个进程');
 dialog.querySelector('h2').insertAdjacentHTML('afterbegin',programFileIcon(item.icon));
 const body=document.createElement('div');
 body.className='route-dialog-body process-detail';
 const rows=item.members.map(process=>'<tr><td title="'+esc(process.path)+'">'+programFileIcon(process.icon)+esc(process.exe)+'</td><td>'+process.pid+'</td><td>'+process.threadCount+'</td><td><button type="button" class="btn sm" data-process-detail="'+process.pid+'" data-detail-type="process">线程详情</button></td></tr>');
 body.innerHTML='<div class="process-thread-list"><table><thead><tr><th>可执行文件</th><th>PID</th><th>线程数</th><th></th></tr></thead><tbody>'+rows.join('')+'</tbody></table></div><form method="dialog" class="route-dialog-actions"><button class="btn primary">关闭</button></form>';
 dialog.append(body);
 dialog.addEventListener('close',()=>dialog.remove(),{once:true});
 dialog.addEventListener('click',event=>{if(event.target===dialog)dialog.close()});
 document.body.append(dialog);
 dialog.showModal();
}
document.addEventListener('click',event=>{
 const button=event.target.closest('[data-process-detail]');
 if(!button||!native)return;
 const item=RUNNING.find(row=>row.type===button.dataset.detailType&&row.pid===Number(button.dataset.processDetail));
 if(item?.type==='app')showApplicationProcesses(item);
 else if(item)void showProcessDetails(item);
});
function renderRunning(){
 if(native){renderNativeRunning();return}
`);
  source = source.replace('x.checked=!!db.network[x.dataset.network]', "x.checked=native?(x.dataset.network==='tun'?!!liveStatus?.tun:!!liveStatus?.systemProxy):!!db.network[x.dataset.network]");
  return source;
}
export { wireLiveData };
