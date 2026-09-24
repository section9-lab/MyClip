/* Client UI is an illustration; every tool result comes from scripts/recall.py. */
document.addEventListener("DOMContentLoaded", () => {
  const data = window.MYCLIP_RECALL;
  const search = data.replies[0].result.structuredContent;
  const decision = data.replies[1].result.structuredContent;
  const focus = data.replies[2].result.structuredContent;
  const prompt =
    "我上次为 MyClip 演示定了什么方向？接下来要做什么？请从 MyClip 记忆中找依据。";
  const escape = (text) =>
    text.replace(
      /[&<>\"]/g,
      (char) =>
        ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[char],
    );
  const icon = (name) =>
    `<img class="ui-icon" src="assets/macos/${name}.png" alt="" />`;
  const decisionText = decision.content.split("\n\n")[1];
  const next = focus.content.split("## 下一步")[1].split("##")[0].trim();
  const todos = focus.content
    .split("\n")
    .filter((line) => line.startsWith("- "))
    .map((line) => line.slice(2));
  const clients = ["codex", "claude"].map((name) => {
    const root = document.querySelector(`#${name}-window`);
    const isClaude = name === "claude";
    root.innerHTML = `
      <aside class="client-sidebar">
        <div class="client-chrome"><i></i><i></i><i></i><span>${icon("sidebar.left")}</span></div>
        ${isClaude ? '<div class="mode-tabs"><b>Chat and Cowork</b><span>Code</span></div>' : '<div class="client-brand">Codex</div>'}
        <div class="sidebar-link primary">${icon("square.and.pencil")}<span>${isClaude ? "New" : "新任务"}</span><small>⌘ N</small></div>
        ${isClaude ? `<div class="sidebar-link">${icon("command")}<span>Quick task</span></div><div class="sidebar-link">${icon("folder")}<span>Projects</span></div><div class="sidebar-link">${icon("doc.text")}<span>Artifacts</span></div><div class="sidebar-link">${icon("gearshape")}<span>Customize</span></div>` : `<div class="sidebar-link">${icon("magnifyingglass")}<span>搜索任务</span></div><div class="sidebar-link">${icon("folder")}<span>项目</span></div>`}
        <div class="sidebar-section">${isClaude ? "Chats" : "MyClip"}</div>
        <div class="sidebar-selected">演示方向与下一步</div>
        <div class="sidebar-foot"><span class="account-avatar">M</span><span>MyClip Demo<small>演示工作区</small></span>${icon("chevron.down")}</div>
      </aside>
      <div class="client-main">
        <header class="client-toolbar"><span>演示方向与下一步</span><span class="toolbar-tools">${icon("ellipsis")}</span></header>
        <div class="conversation">
          <div class="client-empty"><img src="assets/macos/${name}.png" alt="" /><h1>${isClaude ? "让工作接着往下走" : "继续你的工作"}</h1><p>从 MyClip 找回之前的上下文</p></div>
          <div class="user-message">${prompt}</div>
          <div class="assistant-thread">
            <div class="assistant-intro">我先查一下 MyClip 中保存的决定和当前关注。</div>
            <div class="tool-stack">
              <details class="tool-call search-call">
                <summary><span class="tool-chevron">›</span><img class="tool-app" src="assets/myclip.png" alt="" /><span class="tool-name">MyClip <span>memory_search</span></span><small class="search-status">正在搜索</small></summary>
                <div class="tool-body"><div class="tool-query">搜索 <code>演示</code></div><div class="search-results">${search.results.map((result) => `<div><span>${icon("doc.text")}<b>${escape(result.title)}</b><code>${escape(result.path)}</code></span><p>${escape(result.snippet.split("\n")[0])}</p></div>`).join("")}</div></div>
              </details>
              <details class="tool-call read-call">
                <summary><span class="tool-chevron">›</span><img class="tool-app" src="assets/myclip.png" alt="" /><span class="tool-name">MyClip <span>memory_get</span></span><small class="read-status">读取 2 份记忆</small></summary>
                <div class="tool-body"><div class="read-file">${icon("doc.text")}<code>Memory.md#最近的决定</code><span>已读取</span></div><blockquote>${escape(decisionText)}</blockquote><div class="read-file">${icon("doc.text")}<code>Now.md</code><span>已读取</span></div><blockquote>${escape(next)}</blockquote></div>
              </details>
            </div>
            <article class="recall-answer">
              <p class="answer-lead">找到了。你上次确定的方向是：</p>
              <p class="decision-text">${escape(decisionText)}</p>
              <div class="answer-next"><p><strong>接下来，完成 README 使用演示。</strong> 具体还要：</p><ul>${todos.map((item) => `<li>${escape(item)}</li>`).join("")}</ul></div>
              <div class="source-links"><span>记忆来源</span><button data-source="decision">${icon("doc.text")}Memory.md <small>最近的决定</small></button><button data-source="focus">${icon("doc.text")}Now.md <small>当前关注</small></button></div>
            </article>
          </div>
        </div>
        <div class="composer"><div class="composer-text"></div><div class="composer-bottom"><span>${icon("plus")}${isClaude ? "<b>Chat</b><span>Cowork</span>" : "<span>MyClip</span>"}</span><span>${isClaude ? "Opus 5.5 <small>Medium</small>" : "本地"}${icon("chevron.down")}<span class="send-arrow">${icon("arrow.up")}</span></span></div></div>
        <p class="client-footnote">${isClaude ? "Claude" : "Codex"} 桌面端交互示意 · MyClip 示例记忆</p>
      </div>
      <aside class="source-popover" hidden><header><strong></strong><button aria-label="关闭记忆来源">×</button></header><pre></pre><footer>MyClip · memory_get 实际返回</footer></aside>`;
    const popover = root.querySelector(".source-popover");
    root.addEventListener("pointerdown", () => {
      if (window.parent !== window) window.parent.postMessage({type: "demo-interact"}, window.location.origin);
    });
    root.addEventListener("keydown", event => {
      if (event.key === "Escape") popover.hidden = true;
    });
    root.querySelectorAll("[data-source]").forEach((button) =>
      button.addEventListener("click", () => {
        const source = button.dataset.source === "decision" ? decision : focus;
        popover.querySelector("strong").textContent = source.path;
        popover.querySelector("pre").textContent = source.content;
        popover.hidden = false;
      }),
    );
    popover.querySelector("button").addEventListener("click", () => {
      popover.hidden = true;
    });
    const timing = Object.fromEntries(["question", "search", "read", "answer"].map(stage =>
      [stage, window.MYCLIP_DEMO.scenes.find(scene => scene.id === `${name}-${stage}`).time],
    ));
    return { root, timing, stage: null, popover };
  });
  window.renderRecall = (time) =>
    clients.forEach((client) => {
      const timing = client.timing;
      const t = time - timing.question;
      const stage =
        time >= timing.answer
          ? "answer"
          : time >= timing.read
            ? "read"
            : time >= timing.search
              ? "search"
              : time >= timing.search - 0.4
                ? "sent"
                : "compose";
      const root = client.root;
      if (stage !== client.stage) {
        client.stage = stage;
        root.dataset.stage = stage;
        root.querySelector(".search-call").open = stage === "search";
        root.querySelector(".read-call").open = stage === "read";
        client.popover.hidden = true;
        root.querySelector(".conversation").scrollTop = 0;
      }
      const typed = prompt.slice(
        0,
        Math.floor((Math.max(0, t) / (timing.search - timing.question - 0.6)) * prompt.length),
      );
      const composer = root.querySelector(".composer-text");
      composer.textContent =
        stage === "compose"
          ? typed ||
            (root.classList.contains("claude")
              ? "How can I help you today?"
              : "向 Codex 提问")
          : "继续提问…";
      composer.classList.toggle("placeholder", stage !== "compose" || !typed);
      root.querySelector(".search-status").textContent =
        time < timing.search + 0.2 ? "正在搜索" : `${search.results.length} 条结果`;
      root.querySelector(".read-status").textContent =
        time < timing.read + 0.25 ? "读取 2 份记忆" : "已读取 2 份记忆";
      root.querySelector(".search-results").style.opacity = time < timing.search + 0.2 ? 0 : 1;
      root.querySelector(".answer-next").style.opacity = time < timing.answer + 0.8 ? 0 : 1;
      root.querySelector(".source-links").style.opacity = time < timing.answer + 1.4 ? 0 : 1;
    });
});
