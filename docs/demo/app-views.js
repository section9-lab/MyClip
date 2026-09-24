/* HTML views mirror the installed MyClip window; state and navigation live in desktop.js. */
(() => {
  const data = window.MYCLIP_APP_DATA;
  const escape = (value) => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const paths = {
    folder:'M3 6h6l2 2h10v12H3z M3 6V4h6l2 2h10v2',
    timeline:'M8 8h13v13H8z M16 8V3H3v13h5',
    kanban:'M3 4h18v16H3z M9 4v16 M15 4v16',
    layers:'m3 7 9-5 9 5-9 5z M3 12l9 5 9-5 M3 17l9 5 9-5',
    search:'M16 16l5 5 M18 10a8 8 0 1 0-16 0 8 8 0 0 0 16 0',
    gear:'M9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1z M16 12a4 4 0 1 0-8 0 4 4 0 0 0 8 0',
    sidebar:'M3 4h18v16H3z M9 4v16 M5 7h2 M5 10h2 M5 13h2',
    doc:'M5 2h9l5 5v15H5z M14 2v6h5 M8 12h8 M8 16h8',
    chevron:'m9 5 7 7-7 7', down:'m5 9 7 7 7-7',
    plus:'M12 4v16 M4 12h16', close:'m6 6 12 12 M18 6 6 18',
    check:'m5 12 4 4L19 6', circle:'M21 12a9 9 0 1 0-18 0 9 9 0 0 0 18 0',
    progress:'M21 12a9 9 0 1 0-18 0 9 9 0 0 0 18 0 M12 3v18 M8 5v14 M5 8v8',
    done:'M21 12a9 9 0 1 0-18 0 9 9 0 0 0 18 0 m-14 0 3 3 7-7',
    edit:'m14 4 6 6 M13 5l3-3 6 6-3 3 M13 5 4 14l-2 8 8-2 9-9',
    link:'m10 14 4-4 M9 16l-2 2a4 4 0 0 1-6-6l4-4a4 4 0 0 1 6 0 M15 8l2-2a4 4 0 0 1 6 6l-4 4a4 4 0 0 1-6 0',
    calendar:'M3 5h18v16H3z M3 10h18 M7 2v6 M17 2v6 M7 14h2 M12 14h2 M17 14h1 M7 18h2 M12 18h2',
    keyboard:'M2 6h20v13H2z M5 9h1 M9 9h1 M13 9h1 M17 9h1 M5 12h1 M9 12h1 M13 12h1 M17 12h1 M6 16h12',
    mouse:'M12 2c-5 0-7 3-7 7v7a7 7 0 0 0 14 0V9c0-4-2-7-7-7z M12 2v7 M5 9h14',
    camera:'M4 7h4l2-3h4l2 3h4v14H4z M16 13a4 4 0 1 0-8 0 4 4 0 0 0 8 0',
    screen:'M3 3h15v12H3z M7 9h14v12H7',
    cursor:'m5 2 1 17 4-5 4 8 3-2-4-7 7-1z',
    globe:'M21 12a9 9 0 1 0-18 0 9 9 0 0 0 18 0 M3 12h18 M12 3c-5 5-5 13 0 18 5-5 5-13 0-18',
    arrow:'M4 12h16 m-6-6 6 6-6 6',
    clip:'m9 14 7-7a2 2 0 0 1 3 3l-9 9a4 4 0 0 1-6-6L15 2a5 5 0 0 1 7 7L10 21',
    tray:'m5 4-3 9v6h20v-6l-3-9z M2 13h6l2 3h4l2-3h6',
    spark:'m12 2 2 7 7 3-7 2-2 8-3-8-7-2 7-3z',
    shield:'m12 2 8 4v6c0 5-8 10-8 10s-8-5-8-10V6z m-4 10 3 3 5-6',
    moon:'M20 14A8 8 0 0 1 10 4 9 9 0 1 0 20 14',
    pause:'M8 4v16 M16 4v16',
    play:'m7 3 14 9-14 9z',
    refresh:'M20 8a9 9 0 1 0 1 8 M20 2v6h-6',
    more:'M4 12h.1 M12 12h.1 M20 12h.1',
    hand:'M8 12V4a2 2 0 0 1 4 0v7-9a2 2 0 0 1 4 0v10-7a2 2 0 0 1 4 0v10c0 9-10 9-13 3l-4-6c-1-3 2-4 4-1l1 1',
    network:'M12 5v7 M4 18l8-6 8 6 M14 3a2 2 0 1 0-4 0 2 2 0 0 0 4 0 M6 20a2 2 0 1 0-4 0 2 2 0 0 0 4 0 M22 20a2 2 0 1 0-4 0 2 2 0 0 0 4 0',
    drive:'m5 3-3 12v5h20v-5L19 3z M2 15h20 M6 18h1 M10 18h1',
    info:'M21 12a9 9 0 1 0-18 0 9 9 0 0 0 18 0 M12 11v6 M12 7v.1',
    share:'M12 16V2 m-5 5 5-5 5 5 M7 10H3v12h18V10h-4',
    copy:'M8 7H3v15h12v-5 M9 2h8l4 4v11H9z M16 2v5h5',
    power:'M12 2v10 M6 5a9 9 0 1 0 12 0',
  };
  const icon = (name, extra='') => `<svg class="icon ${extra}" viewBox="0 0 24 24" aria-hidden="true"><path d="${paths[name] || paths.doc}"/></svg>`;
  const brand = (id) => id === 'claude' ? `<svg class="brand crab" viewBox="-16 0 132 100" aria-hidden="true"><g fill="#e58970"><path d="M0 14h100v62H0z M-13 43H0v14h-13z M100 43h13v14h-13z M10 74h8v15h-8z M28 74h8v15h-8z M64 74h8v15h-8z M82 74h8v15h-8z"/></g><path fill="#251a14" d="M25 36h6v15h-6z M70 36h6v15h-6z"/></svg>` : `<img class="brand" src="assets/ui/${id}.svg" alt="">`;
  const button = (label, action, kind='', attrs='') => `<button class="ui-button ${kind}" data-action="${action}" ${attrs}>${label}</button>`;
  const iconButton = (label, name, action, attrs='') => `<button class="icon-button" aria-label="${escape(label)}" title="${escape(label)}" data-action="${action}" ${attrs}>${icon(name)}</button>`;
  const toggle = (label, key, on) => `<button class="toggle" role="switch" aria-label="${escape(label)}" aria-checked="${Boolean(on)}" data-toggle="${key}"></button>`;
  const lights = '<div class="traffic-lights" aria-hidden="true"><i></i><i></i><i></i></div>';
  const optionSelect = (label, key, values, selected) => `<select aria-label="${label}" data-setting="${key}">${values.map(value => `<option ${value===selected?'selected':''}>${escape(value)}</option>`).join('')}</select>`;
  const segmented = (values, active, action, label) => `<div class="segmented" role="group" aria-label="${label}">${values.map(value => `<button class="${active===value?'active':''}" data-action="${action}" data-value="${value}" aria-pressed="${active===value}">${value}</button>`).join('')}</div>`;
  const statusName = {todo:'待办', doing:'进行中', done:'已完成'};
  const statusIcon = {todo:'circle', doing:'progress', done:'done'};
  function markdown(source) {
    const inline = text => escape(text).replace(/\[\[([^\]]+)\]\]/g, (_, name) => `<button class="text-link" data-file="${name}">${name.replace(/\.md$/,'').split('/').pop()}</button>`).replace(/\*\*(.+?)\*\*/g,'<strong>$1</strong>').replace(/`([^`]+)`/g,'<code>$1</code>');
    let list = '', result='';
    const close = () => { if(list) {result+=`</${list}>`;list='';} };
    for(const line of source.split('\n')) {
      const heading=line.match(/^(#{1,3}) (.+)/), item=line.match(/^(- |\d+\. )(.+)/);
      if(item) { const tag=item[1]==='- '?'ul':'ol'; if(list!==tag) {close();result+=`<${tag}>`;list=tag;} result+=`<li>${inline(item[2])}</li>`; }
      else {close();if(heading) result+=`<h${heading[1].length}>${inline(heading[2])}</h${heading[1].length}>`;else if(line.trim())result+=`<p>${inline(line)}</p>`;}
    }
    close(); return result;
  }
  function miniWindow(capture) {
    const type=capture.type;
    const copy=type==='code' ? '<pre>import SwiftUI\n\nstruct OnboardingView: View {\n  @State var step = 1\n\n  var body: some View {\n    VStack(spacing: 24) {\n      PermissionSettings()\n      AgentSelection()\n    }\n  }\n}</pre>' : type==='chat' ? '<h4>找回之前的决定</h4><p>MyClip 演示的方向和下一步是什么？</p><p>我会先搜索相关记忆，再核对原文与来源。</p>' : type==='notes' ? '<h4>今天的工作记录</h4><p>检查首次使用与权限引导。</p><p>复核截图、记忆和待办之间的来源关系。</p><p>整理日报，准备同步进展。</p>' : '<h4>MyClip</h4><p>截图，成为记忆。</p><p>从工作中的线索，找到接下来的行动。</p><div class="mini-line"></div><div class="mini-line"></div><div class="mini-line"></div>';
    return `<div class="mini-window mini-${type}" aria-hidden="true" data-layout-ignore><div class="mini-toolbar"><i></i><i></i><i></i><span>${type==='browser'?'github.com / MyClip':escape(capture.title)}</span></div><div class="mini-body"><div class="mini-nav">${type==='code'?'Explorer':'MyClip'}<p>今天</p><p>项目记录</p><p>工作进展</p></div><div class="mini-copy">${copy}</div></div></div>`;
  }
  function captureCard(capture, compact=false) {
    return `<button class="capture-card" data-capture="${capture.id}" aria-label="查看 ${escape(capture.app)} ${escape(capture.title)}"><div class="capture-thumb">${miniWindow(capture)}${capture.count>1?`<span class="capture-count">×${capture.count}</span>`:''}</div><div class="capture-meta"><strong>${capture.app}</strong><small>${capture.time}</small></div>${compact?'':`<p>${capture.title}</p><div class="capture-foot"><span>9月${capture.date.endsWith('24')?'24':'23'}日${capture.count>1?` · ${capture.count} 张不同画面`:''}</span>${icon(capture.event==='回车触发'?'keyboard':'mouse')}</div>`}</button>`;
  }
  function sidebar(page, state) {
    return `<aside class="app-sidebar"><div class="sidebar-chrome">${lights}${iconButton('折叠边栏','sidebar','sidebar')}</div><div class="global-search">${icon('search')}<input id="app-search" aria-label="搜索任务、记忆与截图" placeholder="搜索任务、记忆与截图" value="${escape(state.query)}"><button class="search-clear" data-action="clear-search" aria-label="清除搜索" ${state.query?'':'hidden'}>${icon('close')}</button></div><div class="sidebar-caption">资料库</div><nav class="main-navigation" aria-label="MyClip 页面">${[['memory','Memory','folder'],['timeline','Timeline','timeline'],['kanban','Kanban','kanban'],['backstage','Backstage','layers']].map(([id,label,symbol]) => `<button class="nav-item ${id===page?'selected':''}" data-route="${id}" ${id===page?'aria-current="page"':''}>${icon(symbol)}<span>${label}</span></button>`).join('')}</nav><div class="sidebar-bottom"><button class="icon-button" data-route="backstage" aria-label="整理 Agent 状态">${brand(state.agent||'codex')}</button><button class="icon-button ${page==='settings'?'selected':''}" data-route="settings" aria-label="设置">${icon('gear')}</button></div></aside>`;
  }
  function directory(state) {
    const file = doc => `<button class="file-row ${doc.path===state.file&&!state.query?'selected':''}" data-file="${doc.path}">${icon('doc')}<span>${doc.path.split('/').pop()}</span></button>`;
    return `<aside class="memory-dir" aria-label="Memory 文件目录">${['Daily','Inbox','Wiki'].map(name=>`<details class="folder-tree" ${state.file.startsWith(name+'/')?'open':''}><summary class="folder-label">${icon('chevron','chevron')}${icon('folder')}${name}</summary><div class="folder-files">${state.documents.filter(doc=>doc.path.startsWith(name+'/')).map(file).join('')||'<div class="empty-folder">文件夹为空</div>'}</div></details>`).join('')}${state.documents.filter(doc=>!doc.path.includes('/')).map(file).join('')}</aside>`;
  }
  function memory(state) {
    const doc=state.documents.find(item=>item.path===state.file)||state.documents[0];
    const matches=state.documents.filter(item=>(item.title+item.markdown).toLowerCase().includes(state.query.toLowerCase()));
    const content=state.query ? `<div class="search-results"><h1>搜索结果</h1><p class="secondary">${matches.length} 篇记忆</p>${matches.length?matches.map(item=>`<button class="result-row" data-file="${item.path}">${icon('doc')}<div><strong>${item.title}</strong><p>${escape(item.markdown.replace(/[#\[\]]/g,'').replace(/\n/g,' ').slice(0,115))}</p><small>9月24日 · ${item.path}</small></div>${icon('chevron')}</button>`).join(''):'<div class="empty-state">'+icon('search')+'<div>没有找到相关记忆</div><p>试试其他关键词，或从目录中选择文件。</p></div>'}</div>` : `<article class="memory-document" data-document="${doc.path}"><div class="document-actions">${iconButton('编辑 Markdown','edit','edit-memory')}${iconButton('文件信息','info','file-info')}</div><div class="markdown">${markdown(doc.markdown)}</div><div class="references"><details data-reference="linksOpen" ${state.linksOpen?'open':''}><summary>关联记忆 · 3</summary><div class="reference-list">${state.documents.filter(item=>item.path!==doc.path).slice(0,3).map(item=>`<button class="text-link" data-file="${item.path}">${icon('link')} ${item.title}</button>`).join('')}</div></details><details data-reference="sourcesOpen" ${state.sourcesOpen?'open':''}><summary>来源截图 · 2</summary><div class="capture-grid" style="grid-template-columns:1fr 1fr;margin-top:14px">${data.captures.slice(0,2).map(item=>captureCard(item,true)).join('')}</div></details></div></article>`;
    return `<div class="memory-layout">${directory(state)}<div class="document-scroll">${content}</div></div>`;
  }
  function timeline(state) {
    const captures=data.captures.filter(c=>(state.timelineApp==='全部应用'||c.app===state.timelineApp)&&(state.timelineEvent==='全部事件'||c.event===state.timelineEvent)&&(!state.timelineRange||(c.date>=state.timelineRange[0]&&c.date<=state.timelineRange[1]))&&(!state.query||(c.app+c.title).includes(state.query)));
    return `<div class="page-scroll"><div class="timeline-page"><div class="timeline-filter"><div class="filter-summary">${captures.length} 个画面 · ${captures.reduce((n,c)=>n+c.count,0)} 次出现<small>显示最近 500 条记录</small></div>${optionSelect('应用筛选','timelineApp',['全部应用',...new Set(data.captures.map(c=>c.app))],state.timelineApp)}${button(icon('calendar')+' '+state.timelineDate+' '+icon('down'),'date-filter')}${optionSelect('触发事件筛选','timelineEvent',['全部事件','回车触发','鼠标静止后点击','滚动停止'],state.timelineEvent)}</div>${['2026-09-24','2026-09-23'].map(date=>{const items=captures.filter(c=>c.date===date);return items.length?`<h2>2026年9月${date.endsWith('24')?'24日 周四':'23日 周三'}</h2><div class="capture-grid">${items.map(c=>captureCard(c)).join('')}</div>`:'';}).join('')}${captures.length?'':'<div class="empty-state">没有符合筛选条件的截图</div>'}</div></div>`;
  }
  const boardTabs = reports => `<div class="board-tabs" role="tablist" aria-label="工作看板"><button class="board-tab ${reports?'':'active'}" role="tab" aria-selected="${!reports}" data-route="kanban">Kanban</button><button class="board-tab ${reports?'active':''}" role="tab" aria-selected="${reports}" data-route="reports">Reports</button></div>`;
  function kanban(state) {
    const tasks=state.tasks.filter(t=>!state.query||(t.title+t.project).includes(state.query));
    return `${boardTabs(false)}<div class="board-scroll"><div class="board-tools"><span class="secondary">当前任务 · ${tasks.length} 项</span><span class="spacer"></span>${button(icon('spark')+' AI 更新进展','discover')}${button(icon('plus')+' 新建待办','new-task','primary')}</div>${state.candidates.length?`<section class="candidate-panel"><div class="candidate-heading">${icon('tray')}<strong>待确认</strong><span class="count-pill">${state.candidates.length}</span><small>AI 从近期活动中发现</small><span class="spacer"></span>${button((state.candidatesCollapsed?'展开':'收起')+' '+icon('down'),'collapse-candidates','plain')}</div>${state.candidatesCollapsed?'':state.candidates.map(c=>`<div class="candidate-item"><div class="candidate-main"><button class="candidate-title" data-candidate="${c.id}" aria-expanded="${state.candidateOpen===c.id}"><strong>${escape(c.title)}</strong><small>${c.project} · ${c.count} 条依据 ›</small></button><span class="suggested">${icon(statusIcon[c.status])} 建议${statusName[c.status]}</span>${button(icon('check')+' 确认','confirm-task','',`data-id="${c.id}" aria-label="确认${escape(c.title)}"`)}${iconButton('忽略'+c.title,'close','ignore-task',`data-id="${c.id}"`)}</div>${state.candidateOpen===c.id?`<div class="candidate-evidence"><p>${escape(c.evidence)}</p><div class="flex-row"><button class="text-link" data-file="Now.md">Now.md · 下一步</button><span class="spacer"></span>${button('查看来源与详情','task-detail','plain',`data-id="${c.id}"`)}</div></div>`:''}</div>`).join('')}<div class="candidate-footer">${icon('spark')}确认后，加入建议的看板列<span class="spacer"></span>1–${state.candidates.length} / ${state.candidates.length}</div></section>`:''}${state.lastReview?`<div class="review-notice">${icon('check')}已加入「${statusName[state.lastReview.status]}」<span class="secondary">${escape(state.lastReview.title)}</span><span class="spacer"></span>${button('撤销','undo-task','plain')}${iconButton('关闭确认提示','close','dismiss-review')}</div>`:''}<div class="board-columns">${['todo','doing','done'].map(status=>{const items=tasks.filter(t=>t.status===status);return `<section class="task-column ${status}" data-drop-status="${status}"><div class="column-heading">${icon(statusIcon[status])}<strong>${statusName[status]}</strong><small>${items.length}</small></div><div class="task-list" aria-label="${statusName[status]}任务">${items.map(t=>`<button class="task-card" draggable="true" data-task="${t.id}"><strong>${escape(t.title)}</strong><footer><span>${escape(t.project)}</span><span>${status==='done'?'24/9':t.count+' 条依据'}</span></footer></button>`).join('')||'<p class="secondary">暂无任务</p>'}</div></section>`;}).join('')}</div></div>`;
  }
  function reportDate(state) {
    const start=new Date(state.reportDate+'T12:00:00Z');
    const format=date=>`${date.getUTCFullYear()}年${date.getUTCMonth()+1}月${date.getUTCDate()}日`;
    if(state.reportPeriod==='日报')return format(start);
    if(state.reportPeriod==='月报')return `${start.getUTCFullYear()}年${start.getUTCMonth()+1}月`;
    start.setUTCDate(start.getUTCDate()-(start.getUTCDay()+6)%7);
    const end=new Date(start);
    end.setUTCDate(start.getUTCDate()+6);
    return `${format(start)} — ${format(end)}`;
  }
  function reportSections(state) {
    const period=state.reportPeriod==='日报'?'今日':state.reportPeriod==='月报'?'本月':'本周';
    const next=state.reportPeriod==='日报'?'明日':state.reportPeriod==='月报'?'下月':'下周';
    return [{title:`一、${period}工作与成果`,status:'done'},{title:'二、进行中的工作',status:'doing'},{title:`三、${next}工作计划`,status:'todo'}].map(section=>({...section,tasks:state.tasks.filter(task=>task.status===section.status)}));
  }
  const reportStatus = status => `<span class="report-status ${status}" aria-label="${statusName[status]}">${status==='done'?icon('check'):''}</span>`;
  function reportPaper(state) {
    const sections=reportSections(state).map(section=>{
      // Planned work continues below the scroll viewport in both overview scenes.
      const clipped=section.status==='todo'?' data-layout-allow-occlusion':'';
      const projects=[...new Set(section.tasks.map(task=>task.project))].map(project=>{
        const tasks=section.tasks.filter(task=>task.project===project);
        const items=tasks.map(task=>`<div class="report-item">${reportStatus(task.status)}<p><strong${clipped}>${escape(task.title)}</strong>${task.evidence?`<span class="secondary"${clipped}> · ${escape(task.evidence)}</span>`:''}</p></div>`).join('');
        return `<div class="report-project"><div class="report-project-heading"><h3${clipped}>${escape(project)}</h3><small${clipped}>${statusName[section.status]} ${tasks.length} 项</small></div>${items}</div>`;
      }).join('');
      return `<section class="report-section"><h2${clipped}>${section.title}</h2>${projects||'<p class="secondary">暂无记录。</p>'}</section>`;
    }).join('');
    return `<header class="report-heading"><h1>工作${state.reportPeriod}</h1><div class="report-date">${reportDate(state)}</div></header>${sections}`;
  }
  function reports(state) {
    return `${boardTabs(true)}<div class="report-tools">${optionSelect('报告周期','reportPeriod',['日报','周报','月报'],state.reportPeriod)}<div class="report-date-controls"><input type="date" aria-label="报告日期" data-setting="reportDate" value="${state.reportDate}" max="2026-09-24"><div class="report-navigation">${iconButton('上一周期','chevron','previous-report')}${iconButton('下一周期','chevron','next-report',state.reportDate>='2026-09-24'?'disabled':'')}</div>${state.reportDate==='2026-09-24'?'':button('本期','current-report','plain')}</div><span class="spacer"></span>${button(icon('sidebar')+' 参考任务','report-sources','report-toolbar-button')}${button(icon('share')+' 分享','share-report','report-toolbar-button')}</div><div class="report-scroll"><article class="report-paper">${state.reportHTML||reportPaper(state)}</article></div>`;
  }
  function reportShare(state) {
    const section=reportSections(state).find(item=>item.tasks.length);
    const destinations=[['copy','复制'],['gmail','Gmail'],['notion','Notion'],['feishu','飞书'],['lark','Lark'],['dingtalk','钉钉'],['wechat','微信'],['slack','Slack'],['more','更多']];
    const tileIcon=id=>id==='copy'||id==='more'?icon(id):id==='notion'?'<span class="notion-monogram">N</span>':`<img src="assets/share/${id}.png" alt="">`;
    return `<div class="modal-layer report-share-layer"><section class="app-dialog report-share-dialog" role="dialog" aria-modal="true" aria-label="分享报告"><header class="dialog-header"><strong>分享报告</strong>${iconButton('关闭弹窗','close','close-modal')}</header><div class="report-share-body"><div class="report-share-preview" role="img" aria-label="工作${state.reportPeriod}预览" data-layout-ignore><div class="report-preview-content"><h2>工作${state.reportPeriod}</h2><p class="report-preview-date">${reportDate(state)}</p><hr>${section?`<h3>${section.title}</h3>${section.tasks.slice(0,3).map(task=>`<div class="report-preview-item">${reportStatus(task.status)}<p>${escape(task.title)}</p></div>`).join('')}`:''}</div><img class="report-paperclip" src="assets/macos/paperclip.png" alt=""></div><h3 class="report-share-label">分享到</h3><div class="report-share-grid">${destinations.map(([id,name])=>`<button class="report-share-tile" data-action="${id==='copy'?'copy-report':id==='more'?'report-share-more':'share-destination'}" data-value="${name}"><span class="report-share-icon">${id==='gmail'?'<img class="gmail-mark" src="assets/share/gmail.svg" alt="">':tileIcon(id)}</span><span>${id==='copy'&&state.reportCopied?'已复制':name}</span></button>`).join('')}</div><p class="report-share-hint">报告会带格式复制并打开所选应用，在会话、邮件或文档中粘贴（⌘V）即可。</p></div></section></div>`;
  }
  function backstage(state) {
    return `<div class="page-scroll" id="backstage-scroll"><div class="backstage-page"><header class="section-heading"><h2>整理 Agent</h2><p>只会有一个在工作，切换后对等待中的截图生效</p></header><div class="outline-card">${data.agents.map(a=>`<div class="agent-row"><span class="agent-radio ${state.agent===a.id?'on':''}"></span>${brand(a.id)}<div class="agent-description"><strong>${a.name}</strong>${state.agent===a.id?'<span class="status-chip">● 当前使用</span><span class="status-chip green">● 已连接</span>':''}<p>${a.detail}</p></div>${state.agent===a.id?iconButton(a.name+' 更多','more','agent-menu',`data-id="${a.id}"`):button('连接并使用','connect-agent','',`data-id="${a.id}"`)}</div>`).join('')}<div class="card-footer">${icon('shield')} Agent 以 Full 权限运行，读写文件、运行工具和访问网络都不需要逐次确认；使用各自已有的登录。</div></div><header class="section-heading jobs-heading"><h2>整理记录</h2><p>${state.paused?'已暂停':'等待新的截图'}</p><span class="spacer"></span>${button(icon('moon')+' 整理记忆','organize')}${button('立即整理','organize')}${button(icon(state.paused?'play':'pause')+(state.paused?' 继续':' 暂停'),'pause-jobs','plain')}${segmented(['全部','未完成','已完成'],state.jobFilter,'job-filter','整理记录筛选')}</header><div class="outline-card"><div class="job-list">${state.jobFilter==='未完成'?'<div class="empty-state">没有符合筛选条件的记录。</div>':data.jobs.map((job,i)=>`<button class="job-row" data-action="execution" data-id="${i}">${brand(state.agent||'claude')}<span class="job-description"><strong>${job.count} 条素材</strong><span class="status-chip green">● 已完成</span><small>Token ${job.tokens}</small></span><small>${job.ago}</small>${icon('chevron')}</button>`).join('')}</div><div class="job-bottom"><span>${data.jobs.length} 条记录</span><span>点击一条查看调用过的工具</span></div><details class="batch-disclosure"><summary>整理是怎么分批的</summary><p>按截图时间先后整理，自动整理之间至少间隔 5 分钟。每批最多 8 张图片、32 条 OCR 文本。每天空闲时还会回头整理已有记忆。</p></details></div><section class="usage-panel" id="usage-panel"><header class="section-heading"><h2>Token 用量</h2><p>只统计 Agent 回传的部分</p><span class="spacer"></span>${segmented(['7 天','30 天','全部'],state.usageRange,'usage-range','Token 范围')}${button(state.usageTable?'图表':'表格','usage-table')}</header><div class="outline-card"><div class="usage-stats">${[[state.usageRange==='全部'?'全部 Token':'近 '+state.usageRange+' Token','87.4K','5 次请求'],['平均每次请求','17.5K','已回传请求'],['缓存命中率','72%','读取缓存比重新输入便宜'],['回传完整度','100%','5 / 5 次有用量']].map(([label,value,hint])=>`<div><small>${label}</small><strong>${value}</strong><small>${hint}</small></div>`).join('')}</div>${state.usageTable?`<table class="usage-table"><thead><tr><th>日期</th><th>Agent</th><th>Token</th></tr></thead><tbody>${['22,480','16,380','19,420','29,140'].map((n,i)=>`<tr><td>9月${21+i}日</td><td>Claude Code</td><td>${n}</td></tr>`).join('')}</tbody></table>`:`<div class="usage-chart"><h3>每天用量，按 Agent</h3><div class="usage-bars" role="img" aria-label="最近七天的示例 Token 用量">${[31,54,25,83,62,95,74].map(n=>`<div class="usage-bar" style="height:${n}%"></div>`).join('')}</div><div class="usage-axis">${[18,19,20,21,22,23,24].map(n=>`<span>9/${n}</span>`).join('')}</div><p>● Claude Code　　含截图整理、任务识别和重试。用量为演示数据。</p></div>`}</div></section></div></div>`;
  }
  const settingsRow=(label,subtitle,control)=>`<div class="settings-row"><div><strong>${label}</strong>${subtitle?`<small>${subtitle}</small>`:''}</div>${control}</div>`;
  const settingsSection=(symbol,tint,title,description,content,aside='')=>`<section class="settings-section"><div class="settings-aside"><h2><span class="section-icon ${tint}">${icon(symbol)}</span>${title}</h2><p>${description}</p>${aside}</div><div class="settings-card">${content}</div></section>`;
  function settings(state) {
    const s=state.settings, clients=[['codex','Codex','codex-cli.png'],['claude-cli','Claude Code（命令行）','claude.svg'],['claude-desktop','Claude Desktop（桌面端）','claude.svg'],['cursor','Cursor','cursor.svg'],['opencode','OpenCode','opencode.svg'],['workbuddy','WorkBuddy','workbuddy.png']];
    return `<div class="page-scroll" id="settings-scroll"><div class="settings-page">${settingsSection('camera','', '截图','应用打开后自动采集，退出后停止。MyClip、锁屏和排除的应用不会被记录。', settingsRow('采集范围','全屏仅记录焦点窗口所在的显示器',optionSelect('采集范围','scope',['前台焦点应用窗口','焦点窗口所在的显示器'],s.scope))+settingsRow('鼠标触发','两项可独立勾选',button((s.mouseClick&&s.mouseScroll?'点击与滚动':s.mouseClick?'鼠标点击':s.mouseScroll?'滚动停止':'已关闭')+' '+icon('down'),'mouse-settings'))+settingsRow('键盘触发','忽略长按回车',optionSelect('键盘触发','keyboard',['字母键后再回车','每次回车','已关闭'],s.keyboard)))}${settingsSection('hand','orange','排除应用','这些应用在前台时不截图。密码管理器默认已排除。',`<div class="excluded-apps">${s.excluded.map(name=>`<span class="app-chip">${icon(name==='密码'?'shield':'folder')}${escape(name)}<button data-action="remove-excluded" data-value="${escape(name)}" aria-label="移除 ${escape(name)}">×</button></span>`).join('')}${button(icon('plus')+' 添加正在运行的应用','add-excluded','plain')}</div>`)}${settingsSection('network','green','MCP 记忆访问','让你的 Agent 通过 MCP 搜索和阅读 MyClip 里的记忆。关闭开关即刻暂停查询，连接配置会保留。', settingsRow('启用 MyClip MCP 服务','已完成 12 次查询 · 仅在 Agent 实际读取 Memory 时计数',toggle('启用 MyClip MCP 服务','mcp',s.mcp))+`<div class="mcp-clients">${clients.map(([id,name,asset])=>`<button class="mcp-client" aria-label="${name}" title="${name}" aria-pressed="${s.clients.includes(id)}" data-client="${id}" ${s.mcp?'':'disabled'}><img src="assets/ui/${asset}" alt="">${id.startsWith('claude-')?`<small>${id==='claude-cli'?'>_':'▣'}</small>`:''}</button>`).join('')}</div><div class="settings-footer"><small>${state.mcpConfigured?'已为所选客户端完成演示配置。':'配置完成后，请重启客户端或新建会话。'}</small>${button(s.clients.length?'为 '+s.clients.length+' 个 Agent 一键开启':'一键开启','configure-mcp','primary',s.clients.length&&s.mcp?'':'disabled')}</div>`,button(icon('info')+' 如何让 Agent 使用记忆？','mcp-help','link'))}${settingsSection('drive','gray','存储','Memory 和来源信息独立保存。原图过期后记忆仍可用；等待整理的截图会继续保留。',settingsRow('原始截图保留','原图与识别文本一同到期清理',segmented(['7 天','30 天','90 天','一直保留'],s.retention,'retention','截图保留时间'))+settingsRow('本地资料库','~/Library/Application Support/MyClip/',button(icon('folder')+' 在访达中打开','demo-library'))+settingsRow('搜索索引','搜索结果缺失或异常时重建',button(icon('refresh')+' 重建索引','reindex')))}${settingsSection('clip','pink','关于 MyClip','截图，成为记忆。MyClip 根据你的操作自动截图，并交给已启用的 Agent 整理成可搜索的记忆。',settingsRow('版本','', '<span class="secondary">0.6.13</span>')+`<div class="settings-row">${button('重新打开设置向导','reopen-onboarding')}<span class="spacer"></span>${button(icon('power')+' 退出 MyClip','quit-demo','plain danger')}</div>`)}</div></div>`;
  }
  function onboarding(state) {
    const ready=state.permissions.screen&&state.permissions.access, second=state.onboardingStep===2;
    const permission=(symbol,title,detail,key)=>`<div class="permission-row">${icon(symbol)}<div><strong>${title}</strong><small>${detail}</small></div>${toggle(title,key,state.permissions[key])}</div>`;
    return `<div class="onboarding"><div class="onboarding-chrome">${lights}</div><div class="onboarding-left"><div class="onboarding-form"><div class="onboarding-brand">${icon('clip')}MyClip</div><div class="step-label">第 ${second?2:1} 步，共 2 步</div><h1>${second?'选择整理 Agent':'权限与语言'}</h1><p class="onboarding-intro">${second?'选择 Agent 整理工作记录，也可以稍后设置。':'完成两项授权，开始记录工作中的线索。'}</p><div class="permission-form"><div class="permission-heading"><span>${second?'默认 Agent':'权限设置'}</span>${second?'':`<span>${Number(state.permissions.screen)+Number(state.permissions.access)} / 2 已授权</span>`}</div>${second?`<div class="agent-grid">${data.agents.map(a=>`<button class="agent-tile" data-select-agent="${a.id}" aria-pressed="${state.agent===a.id}">${brand(a.id)}<span><strong>${a.name}</strong><small>${state.agent===a.id?'已连接 · 默认 Agent':'已检测到 · 点击连接'}</small></span>${state.agent===a.id?icon('done'):icon('circle')}</button>`).join('')}</div>`:permission('screen','屏幕录制','读取前台焦点应用窗口的画面','screen')+permission('cursor','辅助功能','识别焦点窗口与截图触发操作','access')+permission('folder','文件访问（推荐）','读取桌面与文档中的文件，帮助首次整理知识库内容；不授权也可继续使用','files')+`<div class="permission-row">${icon('globe')}<div><strong>语言</strong><small>切换后 MyClip 会重新启动</small></div>${optionSelect('语言','language',['简体中文','English','日本語','한국어','Español','Français','Deutsch'],state.language)}</div>`}</div><div class="onboarding-footer">${button(second?'上一步':'退出 MyClip',second?'onboarding-back':'quit-demo',second?'':'plain secondary')}<span class="spacer"></span>${second&&!state.agent?button('稍后设置','onboarding-finish','plain'):''}${button(icon('arrow')+' '+(second?'开始使用':'下一步'),second?'onboarding-finish':'onboarding-next','primary large',ready?'':'disabled')}</div></div></div><div class="onboarding-art"><img src="assets/ui/onboarding-artwork.png" alt="庭院、云朵与水面的引导插画"><p><span>此刻的灵感，</span><span>明日的线索。</span></p></div></div>`;
  }
  function modal(state) {
    if(!state.modal)return '';
    let title='', body='', footer='', cls='', headerExtra='';
    const selectedTask=state.tasks.concat(state.candidates).find(t=>t.id===state.taskID)||state.candidates[0]||state.tasks[0];
    const document=state.documents.find(d=>d.path===state.file)||state.documents[0];
    switch(state.modal) {
      case 'memory-editor':
        title=document.path; cls='editor-dialog'; headerExtra=segmented(['编辑','预览'],state.editorMode,'editor-mode','Markdown 模式');
        body=state.editorMode==='预览'?`<div class="editor-preview markdown">${markdown(state.editorDraft)}</div>`:`<textarea id="markdown-editor" aria-label="Markdown 内容" spellcheck="false">${escape(state.editorDraft)}</textarea>`;
        footer=button('取消','close-modal')+button('保存','save-memory','primary');break;
      case 'file-info':
        title='文件信息';cls='popover-dialog';body=`<div class="dialog-body"><strong>${document.path}</strong><p>文件更新　2026年9月24日 15:45</p><p>版本　　　第 3 版</p><p>整理　　　Claude Code</p><p>来源　　　2 张截图</p></div>`;break;
      case 'capture': {
        const capture=data.captures.find(c=>c.id===state.captureID)||data.captures[0];title=capture.app;cls='capture-dialog';headerExtra=button('完成','close-modal','primary');body=`<div class="capture-detail-meta">${capture.title} · 9月24日 ${capture.time} · ${capture.event}</div><div class="flex-row" style="padding:0 22px 16px">${segmented(['截图','OCR 文本'],state.captureTab,'capture-tab','截图详情')}</div>${state.captureTab==='截图'?`<div class="capture-detail-preview">${miniWindow(capture)}</div>`:`<pre class="ocr-text">MyClip · README 演示计划\n\n从 macOS Dock 启动应用。\n先完成权限与语言设置，再选择整理 Agent。\n\n检查 Timeline、Memory、Kanban 和设置。\n最后通过 Codex 和 Claude 找回同一份记忆。</pre>`}`;break;}
      case 'date-filter':
        title='日期范围';cls='popover-dialog';body=`<div class="dialog-body"><div class="popover-list">${['全部日期','今天'].map(v=>button(v,'timeline-date','',`data-value="${v}"`)).join('')}</div><label class="check-row">开始 <input type="date" value="2026-09-24" aria-label="开始日期"></label><label class="check-row">结束 <input type="date" value="2026-09-24" aria-label="结束日期"></label></div>`;footer=button('应用日期','apply-dates','primary');break;
      case 'task-detail':
        title='任务详情';headerExtra=button('编辑','edit-task');body=`<div class="dialog-body"><h1 class="task-detail-title">${escape(selectedTask.title)}</h1><div class="flex-row"><span>${escape(selectedTask.project)}</span><span class="spacer"></span>${optionSelect('任务状态','taskStatus',['待办','进行中','已完成'],statusName[selectedTask.status])}</div><p class="detail-label">来源依据</p><div class="evidence-box">${escape(selectedTask.evidence||'项目笔记与最近的工作记录确认了这项任务。')}<p><button class="text-link" data-file="Now.md">Now.md · 下一步</button></p></div><p class="detail-label">状态历史</p><p>9月24日 15:45　从近期记忆中发现</p></div>`;break;
      case 'task-editor':
        title=state.newTask?'新建待办':'编辑任务';body=`<form class="dialog-body task-form" id="task-editor"><label>任务名称<input name="title" aria-label="任务名称" value="${state.newTask?'':escape(selectedTask.title)}" required></label><label>项目<input name="project" aria-label="任务项目" value="${state.newTask?'MyClip':escape(selectedTask.project)}"></label><label>说明<textarea name="description" aria-label="任务说明">${state.newTask?'':escape(selectedTask.evidence||'')}</textarea></label></form>`;footer=button('取消','close-modal')+button('保存','save-task','primary');break;
      case 'report-editor':
        title='编辑工作报告';cls='editor-dialog';body=`<textarea id="report-editor" aria-label="报告内容">${escape(state.reportDraft)}</textarea>`;footer=button('取消','close-modal')+button('保存报告','save-report','primary');break;
      case 'share-report':
        return reportShare(state);
      case 'report-sources':
        title='参考任务';body=`<div class="dialog-body"><p class="secondary">查看任务详情、来源依据与状态记录。任务详情显示当前进度。</p><div class="report-source-list">${state.tasks.map(task=>`<button data-task="${task.id}">${reportStatus(task.status)}<span><strong>${escape(task.title)}</strong><small>${escape(task.project)} · ${statusName[task.status]}</small></span>${icon('chevron')}</button>`).join('')}</div></div>`;break;
      case 'report-share-more':
        title='更多分享方式';cls='popover-dialog';body=`<div class="dialog-body popover-list">${['邮件','信息','备忘录','隔空投送'].map(name=>button(name,'share-destination','',`data-value="${name}"`)).join('')}${button('导出 Markdown','export-report')}</div>`;break;
      case 'execution':
        title='整理详情';body=`<div class="dialog-body"><div class="flex-row">${brand(state.agent||'claude')}<strong>整理 4 条工作素材</strong><span class="status-chip green">● 已完成</span></div><p class="detail-label">整理结果</p><p>更新了 Memory.md、Now.md 和 MyClip 项目记录。</p><p class="detail-label">Token 用量</p><p>输入 12,480　输出 5,940　合计 18,420</p><p class="detail-label">调用的工具</p><details class="evidence-box" open><summary>读取工作记录</summary><p>memory_search → memory_get → 整理笔记</p></details><details class="evidence-box"><summary>更新 Markdown</summary><p>补充来源与 Wikilink 关联，保留已有记录。</p></details></div>`;break;
      case 'mouse-settings':
        title='鼠标触发';cls='popover-dialog';body=`<div class="dialog-body"><label class="check-row"><input type="checkbox" data-check="mouseClick" ${state.settings.mouseClick?'checked':''}>鼠标静止后点击</label><label class="check-row"><input type="checkbox" data-check="mouseScroll" ${state.settings.mouseScroll?'checked':''}>滚动停止</label><p class="secondary">两项可以独立勾选。</p></div>`;break;
      case 'scope-settings':
        title='采集范围';cls='popover-dialog';body=`<div class="dialog-body popover-list">${['前台焦点应用窗口','焦点窗口所在的显示器'].map(v=>button(v,'scope-option','',`data-value="${v}"`)).join('')}</div>`;break;
      case 'mcp-help':
        title='让 Agent 读取你的 Memory';body='<div class="dialog-body"><p>勾选你使用的 Agent，再点击“一键开启”。完成后重启客户端或新建会话。</p><div class="evidence-box"><strong>memory_search</strong><p>用问题或关键词搜索记忆，返回命中片段、时间和来源。</p><strong>memory_get</strong><p>按路径阅读一篇记忆，查看原文、Wikilink 和来源截图。</p></div><p>可以这样问：“用 MyClip 看看我上周在做什么，并说明依据。”</p><p class="secondary">工具只读，不会修改记忆，也不会触发截图或 AI 整理。</p></div>';break;
      case 'add-excluded':
        title='添加正在运行的应用';cls='popover-dialog';body=`<div class="dialog-body popover-list">${['Safari浏览器','备忘录','Claude','Codex'].filter(n=>!state.settings.excluded.includes(n)).map(n=>button(n,'exclude-app','',`data-value="${n}"`)).join('')||'所有演示应用均已添加。'}</div>`;break;
      case 'agent-menu':
        title='整理 Agent';cls='popover-dialog';body=`<div class="dialog-body popover-list">${button('重新连接','reconnect-agent')}${button('停用','disable-agent','danger')}</div>`;break;
      case 'library-info':
        title='本地资料库';cls='popover-dialog';body='<div class="dialog-body"><p>~/Library/Application Support/MyClip/</p><div class="evidence-box">Memory/<p>Memory.md　Now.md　Profile.md</p><p>Daily/　Inbox/　Wiki/</p></div></div>';break;
    }
    if(!title)return '';
    return `<div class="modal-layer"><section class="app-dialog ${cls}" role="dialog" aria-modal="true" aria-label="${title}"><header class="dialog-header"><strong>${title}</strong>${headerExtra}${iconButton('关闭弹窗','close','close-modal')}</header>${body}${footer?`<footer class="dialog-footer">${footer}</footer>`:''}</section></div>`;
  }
  window.MyClipViews={escape,icon,brand,button,markdown,sidebar,onboarding,modal,memory,timeline,kanban,reports,backstage,settings,reportPaper};
})();
