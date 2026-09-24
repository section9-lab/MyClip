/* The review clock stays outside the deterministic composition. */
(() => {
  const { scenes, chapters, duration, width } = window.MYCLIP_DEMO;
  const frame = document.querySelector("#demo-frame");
  const viewport = document.querySelector("#window-viewport");
  const play = document.querySelector("#play");
  const progress = document.querySelector("#progress");
  const speed = document.querySelector("#speed");
  const picker = document.querySelector("#scene-picker");
  picker.innerHTML = scenes
    .map((scene) => `<option value="${scene.time}">${scene.title}</option>`)
    .join("");
  let time = 0,
    playing = false,
    previous = null;
  const format = (t) =>
    `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, "0")}`;
  document.querySelector("#duration").textContent = format(duration);
  progress.max = duration;
  document.querySelector("#chapters").innerHTML = chapters
    .map(
      (chapter, i) =>
        `<button data-time="${chapter.time}"><span>${String(i + 1).padStart(2, "0")}</span>${chapter.title}</button>`,
    )
    .join("");
  const chapterButtons = [...document.querySelectorAll("[data-time]")];
  function fit() {
    frame.style.transform = `scale(${viewport.clientWidth / width})`;
  }
  new ResizeObserver(fit).observe(viewport);
  function update() {
    const scene =
      [...scenes].reverse().find((s) => time >= s.time) || scenes[0];
    const chapter =
      [...chapters].reverse().find((c) => time >= c.time) || chapters[0];
    frame.contentWindow?.seekDemo?.(time);
    progress.value = time;
    document.querySelector("#elapsed").textContent = format(time);
    picker.value = scene.time;
    document.querySelector("#description").textContent = scene.description;
    chapterButtons.forEach((button) => {
      const active = Number(button.dataset.time) === chapter.time;
      button.classList.toggle("active", active);
      button.setAttribute("aria-current", String(active));
    });
  }
  function setPlaying(value) {
    playing = value;
    previous = null;
    play.setAttribute("aria-label", value ? "暂停" : "播放");
    document
      .querySelector("#play-shape")
      .setAttribute(
        "d",
        value ? "M6 5h4v14H6zM14 5h4v14h-4z" : "M8 5l12 7-12 7z",
      );
  }
  function seek(value) {
    time = Math.max(0, Math.min(duration, value));
    update();
  }
  play.addEventListener("click", () => {
    if (time >= duration) seek(0);
    setPlaying(!playing);
  });
  document.querySelector("#restart").addEventListener("click", () => {
    frame.contentWindow?.resetAppDemo?.();
    seek(0);
    setPlaying(true);
  });
  progress.addEventListener("input", () => {
    setPlaying(false);
    seek(Number(progress.value));
  });
  picker.addEventListener("change", () => {
    setPlaying(false);
    seek(Number(picker.value));
  });
  chapterButtons.forEach((button) =>
    button.addEventListener("click", () => {
      setPlaying(false);
      seek(Number(button.dataset.time));
    }),
  );
  window.addEventListener("message", (event) => {
    if (
      event.source === frame.contentWindow &&
      ["demo-jump", "demo-play", "demo-interact"].includes(event.data?.type)
    ) {
      if (event.data.type !== "demo-interact") seek(event.data.time);
      setPlaying(event.data.type === "demo-play");
    }
  });
  window.addEventListener("keydown", (event) => {
    if (/INPUT|SELECT|TEXTAREA/.test(event.target.tagName)) return;
    if (event.code === "Space") {
      event.preventDefault();
      setPlaying(!playing);
    } else if (event.code === "ArrowRight" || event.code === "ArrowLeft") {
      event.preventDefault();
      setPlaying(false);
      seek(time + (event.code === "ArrowRight" ? 4 : -4));
    }
  });
  document.querySelector("#fullscreen").addEventListener("click", () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.querySelector("#presentation").requestFullscreen();
  });
  frame.addEventListener("load", () => {
    fit();
    update();
  });
  function tick(timestamp) {
    if (playing && previous !== null) {
      time = Math.min(
        duration,
        time + ((timestamp - previous) / 1000) * Number(speed.value),
      );
      update();
      if (time >= duration) setPlaying(false);
    }
    previous = timestamp;
    requestAnimationFrame(tick);
  }
  update();
  requestAnimationFrame(tick);
})();
