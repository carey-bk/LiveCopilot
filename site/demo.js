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

  // Edge docking demo plays by itself while on screen: every 2 s the window slides past the
  // right edge, then a pointer reaches the edge and brings it back.
  const desk = document.querySelector(".desk"), edgeNote = document.querySelector(".edge-note");
  if (desk && !reduced) {
    let timer = 0, onScreen = false;
    const flip = () => {
      const hidden = desk.dataset.hidden !== "true";
      desk.dataset.hidden = hidden;
      edgeNote.textContent = hidden ? edgeNote.dataset.hidden : edgeNote.dataset.visible;
    };
    const loop = () => { clearInterval(timer); timer = onScreen && !document.hidden ? setInterval(flip, 2000) : 0; };
    new IntersectionObserver(([e]) => { onScreen = e.isIntersecting; loop(); }, { threshold: .4 }).observe(desk);
    document.addEventListener("visibilitychange", loop);
  }

  // Workflow step 2: the matching documents light up in turn each time the step comes into view.
  const docsStep = document.querySelector(".docs")?.closest(".step-visual");
  if (docsStep && !reduced) {
    docsStep.classList.add("armed");
    new IntersectionObserver(([e]) => {
      if (e.intersectionRatio >= .6) docsStep.classList.add("in");
      else if (!e.isIntersecting) docsStep.classList.remove("in");
    }, { threshold: [0, .6] }).observe(docsStep);
  }

  // Below the last dark page the page background turns light, so the browser's own bars and
  // overscroll match the light footer instead of showing a dark band.
  const privacy = $("privacy"), themeColor = document.querySelector("meta[name=theme-color]");
  let light = null;
  const tint = () => {
    const now = privacy.getBoundingClientRect().bottom < innerHeight / 2;
    if (now === light) return;
    light = now;
    document.documentElement.classList.toggle("end", now);
    themeColor.content = now ? "#F4F5F7" : "#07080B";
  };
  addEventListener("scroll", tint, { passive: true });
  addEventListener("resize", tint);
  tint();

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

  // Pop-up menus inside the demonstration windows; one is open at a time.
  let openMenu = null;
  const closeMenu = focus => {
    if (!openMenu) return;
    const [button, list] = openMenu;
    list.hidden = true; button.setAttribute("aria-expanded", false); openMenu = null;
    if (focus) button.focus();
  };
  function popup(button, choose) {
    const list = button.nextElementSibling, items = [...list.querySelectorAll("[role=menuitemradio]")];
    const check = value => items.forEach(item => item.setAttribute("aria-checked", item.dataset.value === value));
    button.addEventListener("click", () => {
      const wasOpen = openMenu && openMenu[1] === list;
      closeMenu();
      if (wasOpen) return;
      list.hidden = false; button.setAttribute("aria-expanded", true); openMenu = [button, list];
      (items.find(item => item.getAttribute("aria-checked") === "true") || items[0]).focus({ preventScroll: true });
    });
    items.forEach((item, i) => {
      item.tabIndex = -1;
      item.addEventListener("click", () => { check(item.dataset.value); choose(item.dataset.value); closeMenu(true); });
      item.addEventListener("keydown", e => {
        const next = { ArrowDown: i + 1, ArrowUp: i - 1, Home: 0, End: items.length - 1 }[e.key];
        if (next !== undefined) { e.preventDefault(); items[(next + items.length) % items.length].focus(); }
        else if (e.key === "Tab") closeMenu();
      });
    });
    return check;
  }
  document.addEventListener("click", e => { if (openMenu && !openMenu[0].parentNode.contains(e.target)) closeMenu(); });
  document.addEventListener("keydown", e => { if (e.key === "Escape") closeMenu(true); });

  // Transcript translation: as in the app, the menu picks a language and "Apply" switches the
  // translated lines to it; "Stop translation" hides them. Sample sentences only, no service calls.
  const TRANSLATIONS = {
    "简体中文": ["我们先从第三季度的数据说起。", "留存提升了，但新用户上手仍然偏慢。", "你会先上线什么？为什么？"],
    "繁體中文": ["我們先從第三季的數據說起。", "留存提升了，但新用戶上手仍然偏慢。", "你會先上線什麼？為什麼？"],
    "English": ["Let's start with the Q3 numbers.", "Retention is up, but onboarding is still slow.", "What would you ship first, and why?"],
    "日本語": ["まず第3四半期の数字から始めましょう。", "定着率は上がっていますが、オンボーディングはまだ時間がかかっています。", "最初に何をリリースしますか？その理由は？"],
    "한국어": ["3분기 수치부터 시작하죠.", "리텐션은 올랐지만 온보딩은 여전히 느립니다.", "무엇을 먼저 출시하시겠어요? 이유는요?"],
    "Français": ["Commençons par les chiffres du T3.", "La rétention progresse, mais l'onboarding reste lent.", "Que livreriez-vous en premier, et pourquoi ?"],
    "Deutsch": ["Fangen wir mit den Zahlen für Q3 an.", "Die Bindung steigt, aber das Onboarding ist noch langsam.", "Was würden Sie zuerst ausliefern, und warum?"],
    "Español": ["Empecemos por las cifras del T3.", "La retención ha subido, pero la incorporación sigue siendo lenta.", "¿Qué lanzarías primero y por qué?"]
  };
  const trPop = $("tr-pop");
  if (trPop) {
    const trWindow = document.querySelector(".tr-window"), label = $("tr-label"), labelText = label.querySelector("span");
    const target = $("tr-target"), apply = $("tr-apply"), stop = $("tr-stop");
    const translated = [...trWindow.querySelectorAll(".p-line.tr span")];
    let picked = target.textContent, applied = picked;
    popup(trPop.querySelector(".select"), value => { picked = value; target.textContent = value; })(picked);
    const render = () => {
      trWindow.classList.toggle("tr-off", !applied);
      label.classList.toggle("on", !!applied);
      labelText.textContent = applied || label.dataset.off;
      apply.textContent = applied ? apply.dataset.apply : apply.dataset.enable;
      stop.hidden = !applied;
    };
    apply.addEventListener("click", () => {
      applied = picked;
      TRANSLATIONS[applied].forEach((text, i) => translated[i].textContent = text);
      render(); fadeIn(trWindow.querySelector(".p-lines"));
    });
    stop.addEventListener("click", () => { applied = null; render(); apply.focus(); });
  }

  // Knowledge modes: the radio list and the overlay's own mode menu choose the same answer.
  const modeDemo = document.querySelector(".mode-demo");
  if (modeDemo) {
    const radios = [...document.querySelectorAll(".mode-list [role=radio]")];
    const cards = [...modeDemo.querySelectorAll(".mode-answers > .p-card")];
    let checkMenu = () => {};
    const setMode = (mode, focus) => {
      radios.forEach(r => {
        const on = r.dataset.mode === mode;
        r.setAttribute("aria-checked", on); r.tabIndex = on ? 0 : -1;
        if (on && focus) r.focus();
      });
      cards.forEach(c => { c.hidden = c.dataset.mode !== mode; if (!c.hidden) fadeIn(c); });
      $("mode-label").textContent = radios.find(r => r.dataset.mode === mode).querySelector("b").textContent;
      checkMenu(mode);
    };
    checkMenu = popup(modeDemo.querySelector(".mode-menu"), mode => setMode(mode));
    radios.forEach((radio, i) => {
      radio.addEventListener("click", () => setMode(radio.dataset.mode));
      radio.addEventListener("keydown", e => {
        const next = { ArrowDown: i + 1, ArrowRight: i + 1, ArrowUp: i - 1, ArrowLeft: i - 1 }[e.key];
        if (next === undefined) return;
        e.preventDefault();
        setMode(radios[(next + radios.length) % radios.length].dataset.mode, true);
      });
    });
  }

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
  function reserveCases() {
    const current = tabs.find(t => t.getAttribute("aria-selected") === "true");
    panel.style.minHeight = "";
    let tallest = 0;
    tabs.forEach(t => { selectCase(t); tallest = Math.max(tallest, panel.offsetHeight); });
    selectCase(current);
    panel.style.minHeight = tallest + "px";
  }
  let caseWidth = 0;
  new ResizeObserver(() => { if (panel.offsetWidth !== caseWidth) { caseWidth = panel.offsetWidth; reserveCases(); } }).observe(panel);
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

for (const link of document.querySelectorAll('a[data-download-mirror]')) {
  let pending = false;
  link.addEventListener('click', async event => {
    if (!link.dataset.downloadMirror || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    if (pending) return;
    pending = true;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    let destination = link.href;
    try {
      // GitHub release redirects are cross-origin. HEAD probes the route without fetching the installer.
      await fetch(destination, { method: 'HEAD', mode: 'no-cors', credentials: 'omit', cache: 'no-store', signal: controller.signal });
    } catch {
      destination = link.dataset.downloadMirror;
    } finally {
      clearTimeout(timeout);
      pending = false;
    }
    window.location.assign(destination);
  });
}
