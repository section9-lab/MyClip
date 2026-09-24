/* Native-scale cursor motion adapted from the oversized-cursor registry primitive. */
document.addEventListener("DOMContentLoaded", () => {
  const { scenes } = window.MYCLIP_DEMO;
  const startOf = id => scenes.find(scene => scene.id === id).time;
  const codexAt = startOf("codex-launch"), claudeAt = startOf("claude-launch");
  const myclipAt = 1.76, clientWindowDelay = 1.04;
  const appName = document.querySelector("#active-app");
  let time = 0;
  function playFrom(value) {
    window.seekDemo(value);
    if (window.parent !== window)
      window.parent.postMessage(
        { type: "demo-play", time: value },
        window.location.origin,
      );
  }
  document
    .querySelector("#dock-myclip")
    .addEventListener("click", () => playFrom(time < startOf("onboarding") ? startOf("dock-launch") : startOf("memory")));
  document
    .querySelector("#dock-codex")
    .addEventListener("click", () => playFrom(codexAt));
  document
    .querySelector("#dock-claude")
    .addEventListener("click", () => playFrom(claudeAt));
  window.renderDemo = (value) => {
    time = value;
    window.renderApp(time);
    window.renderRecall(time);
    const scene =
      [...scenes].reverse().find((item) => item.time <= time) || scenes[0];
    document.querySelector("#macos-desktop").dataset.scene = scene.id;
    appName.textContent =
      time < myclipAt
        ? "Finder"
        : time < codexAt + clientWindowDelay
          ? "MyClip"
          : time < claudeAt + clientWindowDelay
            ? "Codex"
            : "Claude";
    document.querySelector("#menu-myclip").style.opacity = time < myclipAt ? 0 : 1;
    ["myclip", "codex", "claude"].forEach((client, i) => {
      document
        .querySelector(`#dock-${client}`)
        .classList.toggle("running", time >= [myclipAt, codexAt + clientWindowDelay, claudeAt + clientWindowDelay][i]);
    });
  };
  window.buildDesktopMotion = (tl) => {
    const pointer = "#demo-pointer";
    tl.set(
      pointer,
      { x: 985, y: 620, xPercent: -21, yPercent: -14, autoAlpha: 1 },
      0,
    );
    tl.to(pointer, { x: 753, y: 941, duration: 0.42, ease: "power2.inOut" }, 0.24);
    const click = (at) => {
      tl.to(pointer, { scale: 0.83, duration: 0.07, ease: "power2.out" }, at);
      tl.to(pointer, { scale: 1, duration: 0.11, ease: "power2.out" }, at + 0.07);
    };
    click(0.72);
    // The same two hops at 2.5×; both land before the window opens.
    tl.to("#dock-myclip > img", { y: -30, duration: 0.152, ease: "power2.out" }, 0.82);
    tl.to("#dock-myclip > img", { y: 0, duration: 0.152, ease: "power2.in" }, 0.972);
    tl.to("#dock-myclip > img", { y: -22, duration: 0.128, ease: "power2.out" }, 1.2);
    tl.to("#dock-myclip > img", { y: 0, duration: 0.128, ease: "power2.in" }, 1.328);
    tl.fromTo(
      "#myclip-window",
      { autoAlpha: 0, y: 38, scale: 0.92 },
      { autoAlpha: 1, y: 0, scale: 1, duration: 0.22, ease: "power2.out" },
      myclipAt,
    );
    tl.to(pointer, { autoAlpha: 0, duration: 0.1 }, 2.1);
    tl.set(pointer, { x: 1100, y: 690, autoAlpha: 1 }, 2.5);
    tl.to(pointer, { x: 665, y: 435, duration: 0.6, ease: "power2.inOut" }, 2.5);
    click(3.25);
    tl.to(pointer, { x: 665, y: 508, duration: 0.45, ease: "power2.inOut" }, 3.55);
    click(4.08);
    tl.to(pointer, { autoAlpha: 0, duration: 0.1 }, 4.35);
    tl.set(pointer, { x: 740, y: 704, autoAlpha: 1 }, 4.55);
    tl.to(pointer, { x: 655, y: 755, duration: 0.4, ease: "power2.inOut" }, 4.55);
    click(5.02);
    tl.to(pointer, { autoAlpha: 0, duration: 0.1 }, 5.2);
    tl.set(pointer, { x: 740, y: 704, autoAlpha: 1 }, 7.2);
    tl.to(pointer, { x: 648, y: 692, duration: 0.4, ease: "power2.inOut" }, 7.2);
    click(7.7);
    tl.to(pointer, { autoAlpha: 0, duration: 0.1 }, 8.0);
    for (const [client, at, x, previous] of [
      ["codex", codexAt, 827, "myclip"],
      ["claude", claudeAt, 901, "codex"],
    ]) {
      tl.set(pointer, { x: 1260, y: 718, autoAlpha: 1 }, at);
      tl.to(pointer, { x, y: 941, duration: 0.36, ease: "power2.inOut" }, at);
      click(at + 0.4);
      tl.to(
        `#dock-${client} > img`,
        { y: -23, duration: 0.14, ease: "power2.out" },
        at + 0.5,
      );
      tl.to(
        `#dock-${client} > img`,
        { y: 0, duration: 0.14, ease: "power2.in" },
        at + 0.64,
      );
      tl.to(
        `#${previous}-window`,
        {
          autoAlpha: 0,
          y: 12,
          scale: 0.985,
          duration: 0.1,
          ease: "power2.in",
        },
        at + 0.94,
      );
      tl.fromTo(
        `#${client}-window`,
        { autoAlpha: 0, y: 28, scale: 0.95 },
        { autoAlpha: 1, y: 0, scale: 1, duration: 0.192, ease: "power2.out" },
        at + clientWindowDelay,
      );
      tl.to(pointer, { autoAlpha: 0, duration: 0.08 }, at + 1.32);
    }
  };
});
