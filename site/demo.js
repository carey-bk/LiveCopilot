// Website-only demonstrations. No microphone, model, or provider requests.
(() => {
  "use strict";
  const $ = id => document.getElementById(id);
  const data = JSON.parse($("demo-examples").textContent);
  const english = document.documentElement.lang === "en";
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const UP = "M2.5 7.5 6 4l3.5 3.5", DOWN = "M2.5 4.5 6 8l3.5-3.5";

  // Navigation menu (phone).
  const nav = document.querySelector(".nav"), menu = document.querySelector(".menu-toggle");
  const setMenu = open => {
    nav.classList.toggle("open", open);
    menu.setAttribute("aria-expanded", open);
    menu.setAttribute("aria-label", open ? menu.dataset.close : menu.dataset.open);
  };
  menu.addEventListener("click", () => setMenu(!nav.classList.contains("open")));
  $("nav-links").addEventListener("click", e => { if (e.target.closest("a")) setMenu(false); });
  document.addEventListener("keydown", e => { if (e.key === "Escape" && nav.classList.contains("open")) { setMenu(false); menu.focus(); } });

  // Direct links to a disclosure (guides, installation, troubleshooting) open it.
  // Anchors from the previous page layout land on the section that now holds their content.
  const moved = { new: "transcript", translation: "transcript", languages: "transcript", features: "answers", files: "answers", shortcuts: "overlay", "service-overview": "services", "speech-guide": "services", "index-guide": "services", "answer-guide": "services", install: "download", troubleshooting: "download" };
  const openTarget = () => {
    const id = location.hash.slice(1);
    if (moved[id]) { history.replaceState(null, "", "#" + moved[id]); document.getElementById(moved[id]).scrollIntoView(); return; }
    const target = id && document.getElementById(id);
    if (target && target.tagName === "DETAILS") target.open = true;
  };
  addEventListener("hashchange", openTarget);
  openTarget();

  // Transcript fold: both states share rows; only the viewport height changes and it follows the latest line.
  function bindFold(button, panel, labels, changed) {
    const label = button.querySelector("span"), icon = button.querySelector("path");
    button.addEventListener("click", () => {
      const expanded = !panel.classList.contains("expanded");
      panel.classList.toggle("expanded", expanded);
      button.setAttribute("aria-expanded", expanded);
      label.textContent = expanded ? labels.collapse : labels.expand;
      icon.setAttribute("d", expanded ? UP : DOWN);
      if (changed) changed();
    });
  }
  document.querySelectorAll(".tr-window .fold").forEach(button =>
    bindFold(button, button.closest(".p"), { expand: button.dataset.expand, collapse: button.dataset.collapse }));

  // Edge docking demo: the window slides past the right edge and leaves no handle behind.
  const desk = document.querySelector(".desk"), edgeToggle = document.querySelector(".edge-toggle"), edgeNote = document.querySelector(".edge-note");
  if (desk) {
    const setHidden = hidden => {
      desk.dataset.hidden = hidden;
      edgeToggle.setAttribute("aria-pressed", hidden);
      edgeToggle.textContent = hidden ? edgeToggle.dataset.reveal : edgeToggle.dataset.hide;
      edgeNote.textContent = hidden ? edgeNote.dataset.hidden : edgeNote.dataset.visible;
    };
    edgeToggle.addEventListener("click", () => setHidden(desk.dataset.hidden !== "true"));
    desk.querySelector(".desk-edge").addEventListener("pointerenter", () => setHidden(false));
    desk.querySelector(".desk-edge").addEventListener("click", () => setHidden(false));
  }

  // Segmented controls: a pill slides to the selected option; swapped content fades in.
  const pills = [...document.querySelectorAll(".switcher, .case-tabs")].map(list => {
    const pill = document.createElement("span");
    pill.className = "pill-bg"; pill.setAttribute("aria-hidden", "true");
    list.classList.add("js-pill"); list.prepend(pill);
    const place = () => {
      const on = list.querySelector("[aria-selected=true]");
      pill.style.width = on.offsetWidth + "px"; pill.style.height = on.offsetHeight + "px";
      pill.style.transform = `translate(${on.offsetLeft}px, ${on.offsetTop}px)`;
    };
    place();
    new ResizeObserver(place).observe(list);
    return place;
  });
  const movePills = () => pills.forEach(place => place());
  const fadeIn = el => { el.classList.remove("swap-in"); void el.offsetWidth; el.classList.add("swap-in"); };

  // Answer preferences: two settings share one demonstration area.
  const switches = [...document.querySelectorAll(".switcher [role=tab]")];
  const showSwitch = (tab, focus) => {
    switches.forEach(t => {
      const on = t === tab;
      t.setAttribute("aria-selected", on); t.tabIndex = on ? 0 : -1;
      $(t.getAttribute("aria-controls")).hidden = !on;
    });
    fadeIn($(tab.getAttribute("aria-controls"))); movePills();
    if (focus) tab.focus();
  };
  switches.forEach((tab, i) => {
    tab.addEventListener("click", () => showSwitch(tab));
    tab.addEventListener("keydown", e => {
      if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
      e.preventDefault();
      showSwitch(switches[(i + 1) % switches.length], true);
    });
  });

  // Use cases share one panel; arrow keys, Home and End move between tabs.
  const tabs = [...document.querySelectorAll(".case-tabs [role=tab]")], panel = $("case-panel");
  const escape = text => text.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  function selectCase(tab, focus) {
    const item = data[tab.dataset.case];
    tabs.forEach(t => { const on = t === tab; t.setAttribute("aria-selected", on); t.tabIndex = on ? 0 : -1; });
    panel.setAttribute("aria-labelledby", tab.id);
    $("case-question").textContent = item.question;
    $("case-card-question").textContent = item.question;
    $("case-kind").textContent = tab.dataset.case === "manual" ? panel.dataset.manual : panel.dataset.auto;
    $("case-documents").innerHTML = item.documents.map(d => `<span>${escape(d)}</span>`).join("");
    $("case-passage").textContent = item.passage;
    $("case-answer").textContent = item.answer;
    $("case-sources").innerHTML = item.sources.map(s => `<p>${escape(s)}</p>`).join("");
    fadeIn(panel); movePills();
    if (focus) tab.focus();
  }
  tabs.forEach((tab, i) => {
    tab.addEventListener("click", () => selectCase(tab));
    tab.addEventListener("keydown", e => {
      const next = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1 }[e.key];
      if (next === undefined) return;
      e.preventDefault();
      selectCase(tabs[(next + tabs.length) % tabs.length], true);
    });
  });

  // ---------- Hero: one finite timeline, phrase by phrase, ending on the finished answer ----------
  const L = data.hero, stage = $("stage"), product = document.querySelector(".product"), mini = $("mini");
  const p = $("p"), lines = $("lines"), viewport = $("viewport"), card = $("card"), answer = $("answer");
  const atext = card.querySelector(".p-text"), ast = card.querySelector(".ast"), src = card.querySelector(".src"), copy = card.querySelector(".copy");
  const them = lines.querySelector(".p-line b").textContent;
  const fold = $("fold");

  function follow() {
    requestAnimationFrame(() => {
      const overflow = Math.max(0, lines.scrollHeight - viewport.clientHeight);
      lines.style.transform = `translateY(${-overflow}px)`;
    });
  }
  bindFold(fold, p, L, () => { follow(); setTimeout(follow, 360); syncSoon(); });
  copy.addEventListener("click", () => { copy.textContent = L.copied; setTimeout(() => copy.textContent = L.copy, 1400); });
  $("info").addEventListener("click", () => {
    const info = $("demo-info"), open = info.hidden;
    info.hidden = !open; $("info").setAttribute("aria-expanded", open);
  });

  // Keep the true-scale copy on the laptop screen identical to the close-up.
  function sync() {
    const twin = p.cloneNode(true);
    ["id", "role", "aria-label"].forEach(name => twin.removeAttribute(name));
    twin.querySelectorAll("[id]").forEach(el => el.removeAttribute("id"));
    twin.querySelectorAll("button").forEach(el => el.tabIndex = -1);
    twin.style.width = p.offsetWidth + "px"; twin.style.zoom = "";
    mini.replaceChildren(twin);
    mini.style.setProperty("--mini-scale", mini.offsetWidth / p.offsetWidth);
    mini.style.height = p.offsetHeight * mini.offsetWidth / p.offsetWidth + "px";
  }
  function syncSoon() { sync(); setTimeout(sync, 380); }

  let live;
  function setThem(text, partial) {
    const u = document.createElement("div");
    u.className = "p-utt" + (partial ? " partial" : "");
    u.innerHTML = `<div class="p-line them"><b>${escape(them)}</b><span>${escape(text)}</span></div>`;
    if (live) live.replaceWith(u); else lines.replaceChildren(u);
    live = u; follow();
  }
  function reset() {
    lines.innerHTML = `<p class="p-empty">${escape(L.empty)}</p>`;
    live = null;
    $("qstate").textContent = L.wait;
    card.className = "p-card"; atext.textContent = ""; ast.textContent = L.generating;
    src.className = "src"; src.open = false;
    follow(); syncSoon();
  }
  function addAnswer(part) {
    const s = document.createElement("span"); s.className = "ph"; s.textContent = (atext.textContent && english ? " " : "") + part;
    atext.append(s);
  }
  function complete() { card.classList.add("done"); ast.textContent = L.completed; src.classList.add("show"); src.open = true; }

  const steps = [], at = (t, fn) => steps.push([t, fn]);
  {
    const join = english ? " " : "", q = L.question;
    let t = 150;
    q.forEach((_, i) => { const text = q.slice(0, i + 1).join(join); at(t, () => setThem(text, true)); t += 420; });
    at(t, () => { setThem(q.join(join), false); $("qstate").textContent = L.ready; }); t += 320;
    at(t, () => card.classList.add("show")); t += 320;
    L.answer.forEach(part => { at(t, () => addAnswer(part)); t += 420; });
    at(t, complete);
  }

  // Reserve the finished answer's height so the window never grows while the demo runs.
  function reserve() {
    const ghost = card.cloneNode(true);
    ghost.removeAttribute("id");
    ghost.className = "p-card show done";
    ghost.querySelector(".p-text").innerHTML = L.answer.map(a => `<span class="ph">${escape(a)}</span>`).join(english ? " " : "");
    ghost.querySelector(".src").open = true;
    ghost.style.cssText = "position:absolute;inset:0 0 auto;visibility:hidden";
    answer.style.minHeight = "";
    answer.append(ghost);
    answer.style.minHeight = ghost.offsetHeight + "px";
    ghost.remove();
  }
  // On screens too narrow for the real action row, scale the whole window down slightly
  // instead of hiding or squeezing any of its buttons.
  function fit() {
    p.style.zoom = ""; p.style.width = "";
    const row = $("actions"), extra = row.scrollWidth - row.clientWidth;
    if (extra > 0) { const w = p.offsetWidth; p.style.width = w + extra + "px"; p.style.zoom = w / (w + extra); }
  }
  addEventListener("resize", fit);
  let width = 0;
  new ResizeObserver(() => {
    if (p.offsetWidth !== width) { width = p.offsetWidth; reserve(); }
    // Rendered height, so the stage also fits a close-up enlarged with CSS zoom.
    const h = p.getBoundingClientRect().height;
    stage.style.setProperty("--ph", h + "px");
    if (!p.classList.contains("expanded")) stage.style.setProperty("--ph0", h + "px");
    sync();
  }).observe(p);

  let elapsed = 0, index = 0, last = 0, playing = true, visible = true, raf = 0;
  const toggle = $("toggle"), icon = $("toggle-icon");
  function updateToggle() {
    if (index >= steps.length) { icon.innerHTML = '<path d="M7 2.2a4.8 4.8 0 1 1-4.5 3.2" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/><path d="M1.6 2.4 2.6 5.6 5.6 4.4" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>'; toggle.setAttribute("aria-label", L.replay); }
    else if (playing) { icon.innerHTML = '<path d="M4 2.5h2v9H4zM8 2.5h2v9H8z"/>'; toggle.setAttribute("aria-label", L.pause); }
    else { icon.innerHTML = '<path d="M4 2.5v9l7.5-4.5z"/>'; toggle.setAttribute("aria-label", L.play); }
  }
  function tick(now) {
    if (last) elapsed += now - last;
    last = now;
    let ran = false;
    while (index < steps.length && steps[index][0] <= elapsed) { steps[index++][1](); ran = true; }
    if (ran) syncSoon();
    if (index < steps.length && playing && visible && !document.hidden) raf = requestAnimationFrame(tick);
    else { last = 0; raf = 0; updateToggle(); }
  }
  function run() { if (!raf && index < steps.length && playing && visible && !document.hidden) raf = requestAnimationFrame(tick); updateToggle(); }
  function restart() {
    cancelAnimationFrame(raf); raf = 0; last = 0;
    reset(); elapsed = 0; index = 0; playing = true; run();
  }
  toggle.addEventListener("click", () => {
    if (index >= steps.length) restart();
    else { playing = !playing; run(); }
  });

  fit(); reserve();
  // Reduced motion keeps the finished state the page was built with.
  if (reduced) { index = steps.length; updateToggle(); syncSoon(); }
  else {
    new IntersectionObserver(([e]) => { visible = e.isIntersecting; run(); }, { threshold: .25 }).observe(product);
    document.addEventListener("visibilitychange", run);
    restart();
  }
  toggle.hidden = false;
})();
