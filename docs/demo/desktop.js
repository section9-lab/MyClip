/* Semantic HTML interactions. Native screenshots are references only, never rendered. */
document.addEventListener('DOMContentLoaded', () => {
  const root = document.querySelector('#myclip-ui');
  const views = window.MyClipViews;
  const data = window.MYCLIP_APP_DATA;
  const scenes = window.MYCLIP_DEMO.scenes.filter(scene => !scene.kind);
  const pageTitles = {memory:'Memory',timeline:'Timeline',kanban:'Kanban',reports:'Kanban',backstage:'Backstage',settings:'Settings'};
  const createState = () => ({
    page:'onboarding', onboardingStep:1, permissions:{screen:false,access:false,files:false}, language:'简体中文', agent:null,
    documents:data.documents.map(item=>({...item})), file:'Memory.md', query:'', linksOpen:false, sourcesOpen:false,
    timelineApp:'全部应用', timelineEvent:'全部事件', timelineDate:'全部日期', timelineRange:null, captureID:'c1', captureTab:'截图',
    tasks:data.tasks.map(item=>({...item})), candidates:data.candidates.map(item=>({...item})), candidateOpen:null,
    candidatesCollapsed:false, lastReview:null, taskID:'candidate1', newTask:false, modal:null,
    editorMode:'编辑', editorDraft:'', reportPeriod:'周报', reportDate:'2026-09-24', reportHTML:'', reportDraft:'', reportCopied:false,
    jobFilter:'全部', paused:false, usageRange:'30 天', usageTable:false, mcpConfigured:false, toast:'',
    settings:{scope:'前台焦点应用窗口',keyboard:'字母键后再回车',mouseClick:false,mouseScroll:false,mcp:true,
      clients:['codex','claude-desktop'],retention:'30 天',excluded:['密码','1Password','MyClip']},
  });
  let state=createState(), currentScene='', manualScene='', dragTask=null, interacting=false;
  function pageFor(id) {
    if(id.startsWith('onboarding'))return 'onboarding';
    if(id.startsWith('memory'))return 'memory';
    if(id.startsWith('timeline')||id.startsWith('capture'))return 'timeline';
    if(id.startsWith('kanban')||id.startsWith('task'))return 'kanban';
    if(id.startsWith('report'))return 'reports';
    if(id.startsWith('backstage')||id==='execution')return 'backstage';
    return 'settings';
  }
  function pause() {
    interacting=true;
    if(window.parent!==window)window.parent.postMessage({type:'demo-interact'},window.location.origin);
  }
  function navigate(id) {
    const scene=scenes.find(s=>s.id===id);
    if(!scene)return;
    manualScene=id; currentScene='';
    window.seekDemo(scene.time);
    if(window.parent!==window)window.parent.postMessage({type:'demo-jump',time:scene.time},window.location.origin);
  }
  function draw(preserveScroll=true) {
    const offsets=preserveScroll?[...root.querySelectorAll('.page-scroll,.board-scroll,.report-scroll,.document-scroll')].map(el=>({className:el.className,top:el.scrollTop})):[];
    root.innerHTML=state.page==='onboarding'?views.onboarding(state):`<div class="library-shell">${views.sidebar(state.page==='reports'?'kanban':state.page,state)}<main class="main-panel"><header class="window-toolbar"><strong>${pageTitles[state.page]}</strong></header><div class="window-content" id="view-content">${views[state.page](state)}</div></main></div>`;
    // A modal makes its covered parent page a decorative, non-interactive backdrop.
    // Audit each page in its own scene, and the dialog in its modal scene.
    if(state.modal){const shell=root.querySelector('.library-shell');shell.inert=true;shell.setAttribute('data-layout-ignore','');}
    root.insertAdjacentHTML('beforeend',views.modal(state)+(state.toast?`<div class="toast" role="status">${views.escape(state.toast)}</div>`:''));
    for(const offset of offsets){const el=root.querySelector('.'+offset.className.split(' ').join('.'));if(el)el.scrollTop=offset.top;}
  }
  function notify(message) {state.toast=message;draw();}
  function openModal(name) {
    state.modal=name; state.toast='';
    if(name==='memory-editor')state.editorDraft=state.documents.find(doc=>doc.path===state.file).markdown;
    draw(); root.querySelector('[role="dialog"] button')?.focus({preventScroll:true});
  }
  function reportText() {
    const el=document.createElement('div');el.innerHTML=state.reportHTML||views.reportPaper(state);
    el.querySelectorAll('h1,h2,h3,p,.report-date,.report-project-heading').forEach(block=>block.append('\n'));
    return el.textContent.trim();
  }
  async function copyReport(destination) {
    try {
      const html=state.reportHTML||views.reportPaper(state);
      await navigator.clipboard.write([new ClipboardItem({'text/html':new Blob([html],{type:'text/html'}),'text/plain':new Blob([reportText()],{type:'text/plain'})})]);
      state.reportCopied=true;
      notify(destination?`演示：报告已复制，可在 ${destination} 中粘贴。`:'报告已复制，保留标题与段落格式。');
    }catch{notify('浏览器未允许复制，可在“更多”中导出 Markdown。');}
  }
  function autoScene(id) {
    state=createState(); state.agent='claude';state.permissions.screen=true;state.permissions.access=true;
    state.page=pageFor(id);
    if(id==='onboarding'){state.permissions.screen=false;state.permissions.access=false;state.agent=null;}
    if(id==='onboarding-ready')state.agent=null;
    if(id==='onboarding-agent')state.onboardingStep=2;
    if(id==='reports')state.reportPeriod='日报';
    if(id.startsWith('capture')){state.modal='capture';state.captureTab=id.endsWith('ocr')?'OCR 文本':'截图';}
    if(id==='report-share')state.modal='share-report';
  }
  window.renderApp = (time) => {
    const scene=[...scenes].reverse().find(s=>time>=s.time)||scenes[0];
    if(currentScene!==scene.id){
      if(manualScene===scene.id){state.page=pageFor(scene.id);state.modal=null;state.toast='';manualScene='';}
      else {interacting=false;autoScene(scene.id);}
      currentScene=scene.id;draw(false);
      if(scene.id==='backstage-usage'){const el=root.querySelector('#usage-panel');if(el)root.querySelector('#backstage-scroll').scrollTop=el.offsetTop-24;}
      if(scene.id==='settings-bottom'){const el=root.querySelector('#settings-scroll');if(el)el.scrollTop=el.scrollHeight-el.clientHeight;}
    }
    if(scene.id==='onboarding'&&!interacting){
      const screen=time>=3.35,access=time>=4.18;
      if(state.permissions.screen!==screen||state.permissions.access!==access){state.permissions.screen=screen;state.permissions.access=access;draw(false);}
    }
  };
  window.resetAppDemo=()=>{state=createState();currentScene='';manualScene='';};
  root.addEventListener('input', event => {
    pause();const el=event.target;
    if(el.id==='app-search'){
      state.query=el.value;state.modal=null;state.toast='';
      if(!['memory','timeline','kanban'].includes(state.page)){state.page='memory';draw();const input=root.querySelector('#app-search');input.focus();input.setSelectionRange(input.value.length,input.value.length);}
      else root.querySelector('#view-content').innerHTML=views[state.page](state);
      root.querySelector('.search-clear').hidden=!state.query;
    }
    if(el.id==='markdown-editor')state.editorDraft=el.value;
    if(el.id==='report-editor')state.reportDraft=el.value;
  });
  root.addEventListener('change', event => {
    pause();const el=event.target;
    if(el.id==='app-search'){
      if(state.query!==el.value){state.query=el.value;root.querySelector('#view-content').innerHTML=views[state.page](state);root.querySelector('.search-clear').hidden=!state.query;}
      return;
    }
    if(el.dataset.check){state.settings[el.dataset.check]=el.checked;return;}
    const key=el.dataset.setting;if(!key)return;
    if(key==='reportDate'&&(!el.value||!el.checkValidity())){draw();return;}
    if(key==='reportPeriod'||key==='reportDate'){state.reportHTML='';state.reportCopied=false;}
    if(key==='taskStatus'){
      const task=state.tasks.concat(state.candidates).find(t=>t.id===state.taskID);
      if(task)task.status={'待办':'todo','进行中':'doing','已完成':'done'}[el.value];
    }else if(key in state.settings)state.settings[key]=el.value;
    else state[key]=el.value;
    draw();
  });
  root.addEventListener('click', async event => {
    if(event.target.classList.contains('report-share-layer')){pause();state.modal=null;state.toast='';draw();return;}
    const target=event.target.closest('button');if(!target||target.disabled)return;
    pause();state.toast='';
    if(target.dataset.route){navigate(target.dataset.route);return;}
    if(target.dataset.file){if(!state.documents.some(d=>d.path===target.dataset.file)){notify('尚未找到这篇关联记忆');return;}state.file=target.dataset.file;state.query='';state.modal=null;state.page='memory';draw(false);return;}
    if(target.dataset.toggle){const key=target.dataset.toggle;if(key in state.permissions)state.permissions[key]=!state.permissions[key];else state.settings[key]=!state.settings[key];draw();return;}
    if(target.dataset.selectAgent){state.agent=state.agent===target.dataset.selectAgent?null:target.dataset.selectAgent;draw();return;}
    if(target.dataset.client){const id=target.dataset.client;const list=state.settings.clients;state.settings.clients=list.includes(id)?list.filter(c=>c!==id):[...list,id];state.mcpConfigured=false;draw();return;}
    if(target.dataset.capture){state.captureID=target.dataset.capture;state.captureTab='截图';openModal('capture');return;}
    if(target.dataset.task){state.taskID=target.dataset.task;openModal('task-detail');return;}
    if(target.dataset.candidate){state.candidateOpen=state.candidateOpen===target.dataset.candidate?null:target.dataset.candidate;draw();return;}
    const id=target.dataset.id,value=target.dataset.value;
    switch(target.dataset.action){
      case 'clear-search':state.query='';draw();root.querySelector('#app-search').focus();return;
      case 'sidebar': {const shell=root.querySelector('.library-shell');shell.classList.toggle('sidebar-collapsed');return;}
      case 'onboarding-next':state.onboardingStep=2;navigate('onboarding-agent');return;
      case 'onboarding-back':state.onboardingStep=1;navigate('onboarding-ready');return;
      case 'onboarding-finish':navigate('memory');return;
      case 'reopen-onboarding':state.onboardingStep=1;state.query='';navigate('onboarding-ready');return;
      case 'quit-demo':state=createState();currentScene='';window.seekDemo(0);if(window.parent!==window)window.parent.postMessage({type:'demo-jump',time:0},window.location.origin);return;
      case 'edit-memory':state.editorMode='编辑';openModal('memory-editor');return;
      case 'editor-mode':state.editorMode=value;break;
      case 'save-memory':state.documents.find(d=>d.path===state.file).markdown=state.editorDraft;state.modal=null;state.toast='Markdown 已保存';break;
      case 'file-info':openModal('file-info');return;
      case 'close-modal':state.modal=null;break;
      case 'date-filter':openModal('date-filter');return;
      case 'timeline-date':state.timelineDate=value;state.timelineRange=value==='全部日期'?null:['2026-09-24','2026-09-24'];state.modal=null;break;
      case 'apply-dates': {const start=root.querySelector('[aria-label="开始日期"]').value,end=root.querySelector('[aria-label="结束日期"]').value;if(!start||!end||start>end){notify('请选择有效的起止日期');return;}state.timelineRange=[start,end];state.timelineDate=start.slice(5)+' — '+end.slice(5);state.modal=null;break;}
      case 'capture-tab':state.captureTab=value;break;
      case 'collapse-candidates':state.candidatesCollapsed=!state.candidatesCollapsed;break;
      case 'confirm-task': {const task=state.candidates.find(t=>t.id===id);if(task){state.candidates=state.candidates.filter(t=>t.id!==id);state.tasks.push({...task});state.lastReview=task;}break;}
      case 'ignore-task':state.candidates=state.candidates.filter(t=>t.id!==id);state.toast='已忽略这条建议';break;
      case 'undo-task':if(state.lastReview){state.tasks=state.tasks.filter(t=>t.id!==state.lastReview.id);state.candidates.unshift(state.lastReview);state.lastReview=null;}break;
      case 'dismiss-review':state.lastReview=null;break;
      case 'discover':state.candidatesCollapsed=false;state.toast='已核对近期记忆，任务进展已更新';break;
      case 'new-task':state.newTask=true;openModal('task-editor');return;
      case 'task-detail':state.taskID=id;openModal('task-detail');return;
      case 'edit-task':state.newTask=false;openModal('task-editor');return;
      case 'save-task': {
        const form=root.querySelector('#task-editor');if(!form.reportValidity())return;
        const fields=new FormData(form), title=fields.get('title').trim();if(!title)return;
        if(state.newTask){const task={id:'new-'+state.tasks.length,title,project:fields.get('project')||'MyClip',status:'todo',evidence:fields.get('description'),count:0};state.tasks.push(task);state.taskID=task.id;}
        else{const task=state.tasks.concat(state.candidates).find(t=>t.id===state.taskID);Object.assign(task,{title,project:fields.get('project'),evidence:fields.get('description')});}
        state.modal='task-detail';break;
      }
      case 'previous-report':
      case 'next-report': {
        const offset=target.dataset.action==='previous-report'?-1:1,date=new Date(state.reportDate+'T12:00:00Z');
        if(state.reportPeriod==='月报'){date.setUTCDate(1);date.setUTCMonth(date.getUTCMonth()+offset);}
        else date.setUTCDate(date.getUTCDate()+offset*(state.reportPeriod==='周报'?7:1));
        state.reportDate=[date.toISOString().slice(0,10),'2026-09-24'].sort()[0];state.reportHTML='';state.reportCopied=false;break;
      }
      case 'current-report':state.reportDate='2026-09-24';state.reportHTML='';break;
      case 'edit-report':state.reportDraft=reportText();openModal('report-editor');return;
      case 'save-report':state.reportHTML=views.markdown(state.reportDraft);state.modal=null;state.toast='本期报告草稿已保存';break;
      case 'share-report':state.reportCopied=false;openModal('share-report');return;
      case 'report-sources':openModal('report-sources');return;
      case 'report-share-more':openModal('report-share-more');return;
      case 'copy-report':await copyReport();return;
      case 'share-destination':await copyReport(value);return;
      case 'export-report': {const url=URL.createObjectURL(new Blob([reportText()],{type:'text/markdown;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download='MyClip-report.md';a.click();URL.revokeObjectURL(url);state.toast='已导出示例报告';break;}
      case 'connect-agent':state.agent=id;state.toast='已连接 '+data.agents.find(a=>a.id===id).name;break;
      case 'agent-menu':openModal('agent-menu');return;
      case 'reconnect-agent':state.modal=null;state.toast='Agent 已重新连接';break;
      case 'disable-agent':state.agent=null;state.modal=null;break;
      case 'pause-jobs':state.paused=!state.paused;break;
      case 'job-filter':state.jobFilter=value;break;
      case 'organize':state.toast='记忆已整理，更新了 3 个 Markdown 文件';break;
      case 'execution':openModal('execution');return;
      case 'usage-range':state.usageRange=value;break;
      case 'usage-table':state.usageTable=!state.usageTable;break;
      case 'mouse-settings':openModal('mouse-settings');return;
      case 'scope-option':state.settings.scope=value;state.modal=null;break;
      case 'mcp-help':openModal('mcp-help');return;
      case 'configure-mcp':state.mcpConfigured=true;state.toast='已为所选客户端完成演示配置';break;
      case 'retention':state.settings.retention=value;break;
      case 'remove-excluded':state.settings.excluded=state.settings.excluded.filter(n=>n!==value);break;
      case 'add-excluded':openModal('add-excluded');return;
      case 'exclude-app':state.settings.excluded.push(value);state.modal=null;break;
      case 'demo-library':openModal('library-info');return;
      case 'reindex':state.toast='索引已重建 · '+state.documents.length+' 篇记忆';break;
      default:return;
    }
    draw();
  });
  root.addEventListener('dragstart', event=>{const el=event.target.closest('[data-task]');if(el){pause();dragTask=el.dataset.task;event.dataTransfer.setData('text/plain',dragTask);}});
  root.addEventListener('dragover', event=>{if(event.target.closest('[data-drop-status]'))event.preventDefault();});
  root.addEventListener('drop', event=>{const column=event.target.closest('[data-drop-status]');if(column&&dragTask){event.preventDefault();state.tasks.find(t=>t.id===dragTask).status=column.dataset.dropStatus;dragTask=null;draw();}});
  root.addEventListener('keydown', event=>{
    if(event.key==='Tab'&&state.modal){
      const focusable=[...root.querySelectorAll('[role="dialog"] button:not(:disabled),[role="dialog"] input,[role="dialog"] textarea,[role="dialog"] select,[role="dialog"] summary')];
      const first=focusable[0],last=focusable.at(-1);
      if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}
      else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}
    }
    if(event.key==='Escape'&&state.modal){event.preventDefault();state.modal=null;draw();root.querySelector('.nav-item.selected')?.focus();}
    if(event.key==='Enter'&&state.page==='onboarding'&&event.target.tagName!=='SELECT'&&event.target.tagName!=='BUTTON')root.querySelector('[data-action="onboarding-next"],[data-action="onboarding-finish"]')?.click();
  });
  root.addEventListener('toggle',event=>{if(event.target.dataset.reference)state[event.target.dataset.reference]=event.target.open;},true);
  root.addEventListener('pointerdown',()=>pause());
  root.addEventListener('wheel',()=>pause(),{passive:true});
});
