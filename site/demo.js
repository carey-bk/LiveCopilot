// Website-only demonstrations. No microphone, model, or provider requests.
(() => {
  "use strict";
  document.documentElement.classList.add("js");
  const reduced = matchMedia("(prefers-reduced-motion: reduce)");
  const english = document.documentElement.lang === "en";
  const menu = document.querySelector(".menu-toggle");
  const links = document.querySelector(".nav-links");
  const closeMenu = () => {
    links.classList.remove("open");
    menu.setAttribute("aria-expanded", "false");
  };
  menu.addEventListener("click", () =>
    menu.setAttribute("aria-expanded", String(links.classList.toggle("open"))),
  );
  links.addEventListener("click", (event) => {
    if (event.target.closest("a")) closeMenu();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && links.classList.contains("open")) {
      closeMenu();
      menu.focus();
    }
  });
  const header = document.querySelector(".site-header");
  const updateHeader = () => header.classList.toggle("scrolled", scrollY > 20);
  window.addEventListener("scroll", updateHeader, { passive: true });
  updateHeader();
  const part = (root, name) => root.querySelector(`[data-part="${name}"]`);
  const text = (node, value) => {
    if (node.textContent !== value) node.textContent = value;
  };
  // Chunk boundaries follow phrases, never individual characters.
  function chunks(value) {
    if (/[\u3400-\u9fff]/.test(value))
      return value.match(/[^，。！？；]+[，。！？；]?/g) || [value];
    return value.match(/(?:\S+\s*){1,5}/g) || [value];
  }
  function stream(node, parts, progress) {
    text(
      node,
      parts
        .slice(0, Math.ceil(Math.max(0, Math.min(1, progress)) * parts.length))
        .join("") || "\u00a0",
    );
  }
  const demo = document.querySelector("#hero-demo");
  const product = document.querySelector('[data-product="hero"]');
  const transcript = part(product, "transcript");
  const answer = part(product, "answer");
  const phaseText = part(product, "phase");
  const status = document.querySelector("#demo-status");
  const toggle = document.querySelector(".demo-toggle");
  const fullQuestion = transcript.textContent;
  const fullAnswer = answer.textContent;
  const questionChunks = chunks(fullQuestion);
  const answerChunks = chunks(fullAnswer);
  const timeline = [
    { at: 0, state: "listening" },
    { at: 500, state: "transcribing" },
    { at: 3000, state: "understanding" },
    { at: 3600, state: "retrieving" },
    { at: 5200, state: "organizing" },
    { at: 6000, state: "answering" },
    { at: 9000, state: "sources" },
    { at: 9500, state: "complete" },
  ];
  const duration = 12000;
  let heroTime = 0,
    heroVisible = false,
    paused = false;
  const heroClock = { previous: 0, frame: 0 };
  function stateAt(time) {
    return [...timeline].reverse().find((item) => time >= item.at).state;
  }
  function renderHero(time) {
    document.dispatchEvent(
      new CustomEvent("hero-clock", {
        detail: { time, running: heroVisible && !paused && !document.hidden },
      }),
    );
    time = Math.max(0, time - 2500);
    const state = stateAt(time);
    demo.dataset.state = state;
    stream(transcript, questionChunks, (time - 500) / 2500);
    stream(answer, answerChunks, (time - 6000) / 3000);
    part(product, "empty").hidden = time >= 3000;
    part(product, "question").hidden = time < 3000;
    part(product, "loading").hidden = time < 3000 || time >= 6000;
    part(product, "response").hidden = time < 6000;
    part(product, "evidence").hidden = time < 9000;
    part(product, "sources").hidden = time < 9000;
    text(
      phaseText,
      time < 3000
        ? english
          ? "Listening"
          : "正在监听"
        : time < 9000
          ? english
            ? "Assistance in progress"
            : "正在生成建议"
          : english
            ? "Question ready"
            : "问题已完整",
    );
    const key = ["complete", "sources", "resetting"].includes(state)
      ? "complete"
      : state === "transcribing"
        ? "listening"
        : state;
    text(status, demo.dataset[key]);
  }
  function finalHero() {
    renderHero(12000);
    text(transcript, fullQuestion);
    text(answer, fullAnswer);
  }
  function tickHero(now) {
    if (heroClock.previous)
      heroTime = Math.min(duration, heroTime + now - heroClock.previous);
    heroClock.previous = now;
    renderHero(heroTime);
    if (heroTime < duration) heroClock.frame = requestAnimationFrame(tickHero);
    else {
      heroClock.frame = 0;
      toggle.hidden = true;
      finalHero();
    }
  }
  function syncHero() {
    cancelAnimationFrame(heroClock.frame);
    heroClock.frame = 0;
    heroClock.previous = 0;
    const sourcesOpen = [...product.querySelectorAll("details")].some(
      (item) => item.open,
    );
    document.dispatchEvent(
      new CustomEvent("hero-playback", {
        detail: {
          suspended: paused || sourcesOpen || document.hidden || !heroVisible,
        },
      }),
    );
    if (reduced.matches || matchMedia("(max-width: 900px)").matches) {
      heroTime = duration;
      finalHero();
    } else if (
      heroTime < duration &&
      heroVisible &&
      !document.hidden &&
      !paused &&
      !sourcesOpen
    )
      heroClock.frame = requestAnimationFrame(tickHero);
    toggle.hidden = reduced.matches || heroTime >= duration;
    toggle.textContent = paused ? "▶" : "Ⅱ";
    toggle.setAttribute(
      "aria-label",
      paused ? toggle.dataset.play : toggle.dataset.pause,
    );
  }
  toggle.addEventListener("click", () => {
    paused = !paused;
    syncHero();
  });
  product
    .querySelectorAll("details")
    .forEach((item) => item.addEventListener("toggle", syncHero));
  product.querySelector("input").addEventListener("focus", () => {
    paused = true;
    heroTime = 12000;
    finalHero();
    syncHero();
  });
  new IntersectionObserver(
    (entries) => {
      heroVisible = entries[0].isIntersecting;
      syncHero();
    },
    { threshold: 0 },
  ).observe(demo);
  document.addEventListener("hero-fallback", () => {
    heroTime = duration;
    finalHero();
    syncHero();
  });
  window.addEventListener(
    "scroll",
    () => {
      if (scrollY > 250 && heroTime < duration) {
        heroTime = duration;
        finalHero();
        syncHero();
      }
    },
    { passive: true },
  );
  document.addEventListener("visibilitychange", syncHero);
  reduced.addEventListener("change", syncHero);
  // Native Copy has a real browser action; the remaining native chrome is a labeled visual replica.
  document.querySelectorAll(".product-copy").forEach((button) =>
    button.addEventListener("click", async () => {
      const value = part(
        button.closest("[data-product]"),
        "answer",
      ).textContent;
      try {
        await navigator.clipboard.writeText(value);
        button.textContent = button.dataset.copied;
      } catch {
        button.textContent = button.dataset.label;
      }
    }),
  );
  // Workflow: one six-second sequence, paused offscreen, final state retained.
  const workflow = document.querySelector(".workflow");
  const nodes = [...workflow.children];
  const workflowTranscript = document.querySelector(
    "[data-workflow-transcript]",
  );
  let workflowTime = 0,
    workflowVisible = false,
    workflowStarted = false,
    workflowPrevious = 0,
    workflowFrame = 0;
  if (!reduced.matches) workflow.classList.add("pending");
  function tickWorkflow(now) {
    if (workflowPrevious) workflowTime += now - workflowPrevious;
    workflowPrevious = now;
    nodes.forEach((node, index) =>
      node.classList.toggle("active", workflowTime >= index * 1500),
    );
    stream(workflowTranscript, questionChunks, workflowTime / 1300);
    if (workflowTime < 6000)
      workflowFrame = requestAnimationFrame(tickWorkflow);
    else {
      workflow.classList.remove("pending");
      workflowFrame = 0;
    }
  }
  function syncWorkflow() {
    cancelAnimationFrame(workflowFrame);
    workflowFrame = 0;
    workflowPrevious = 0;
    if (reduced.matches) {
      workflowTime = 6000;
      workflow.classList.remove("pending");
      text(workflowTranscript, fullQuestion);
    } else if (
      workflowVisible &&
      workflowStarted &&
      !document.hidden &&
      workflowTime < 6000
    )
      workflowFrame = requestAnimationFrame(tickWorkflow);
  }
  new IntersectionObserver(
    (entries) => {
      workflowVisible = entries[0].isIntersecting;
      if (entries[0].intersectionRatio >= 0.45) workflowStarted = true;
      syncWorkflow();
    },
    { threshold: [0, 0.45] },
  ).observe(workflow);
  document.addEventListener("visibilitychange", syncWorkflow);
  reduced.addEventListener("change", syncWorkflow);
  // The real OverlayWindow fades out completely. It leaves no persistent handle.
  const desktop = document.querySelector(".desktop-preview");
  const edgeButton = document.querySelector(".edge-toggle");
  const edgeNote = document.querySelector(".edge-note");
  const edgeSlot = document.querySelector(".edge-product-slot");
  function tuck(value) {
    desktop.classList.toggle("tucked", value);
    edgeSlot.inert = value;
    edgeButton.setAttribute("aria-pressed", String(value));
    edgeButton.textContent = value
      ? edgeButton.dataset.reveal
      : edgeButton.dataset.hide;
    edgeNote.textContent = value
      ? edgeNote.dataset.hidden
      : edgeNote.dataset.visible;
  }
  edgeButton.addEventListener("click", () =>
    tuck(!desktop.classList.contains("tucked")),
  );
  const zone = document.querySelector(".edge-reveal-zone");
  zone.addEventListener("pointerenter", (event) => {
    if (event.pointerType === "mouse") tuck(false);
  });
  zone.addEventListener("click", () => tuck(false));
  // Responsive scaling changes only the miniature desktop demonstration, not the Hero.
  let edgeWidth = -1,
    edgeResizeFrame = 0;
  new ResizeObserver((entries) => {
    const width = entries[0].contentRect.width;
    if (Math.abs(width - edgeWidth) < 1) return;
    edgeWidth = width;
    cancelAnimationFrame(edgeResizeFrame);
    edgeResizeFrame = requestAnimationFrame(() => {
      const scale = Math.min(1, (width - 24) / 400);
      edgeSlot.style.transform = `scale(${scale})`;
      desktop.style.height = `${Math.ceil(240 * scale + 30)}px`;
    });
  }).observe(desktop);
  // One finite caption example, using the same transcript fragment as the Hero.
  const captionRoot = document.querySelector('[data-product="transcript"]');
  const caption = part(captionRoot, "transcript");
  let captionTime = 0,
    captionLast = 0,
    captionFrame = 0,
    captionVisible = false;
  function tickCaption(now) {
    if (captionLast) captionTime += now - captionLast;
    captionLast = now;
    stream(caption, questionChunks, captionTime / 3000);
    if (captionTime < 3000) captionFrame = requestAnimationFrame(tickCaption);
    else captionFrame = 0;
  }
  function syncCaption() {
    cancelAnimationFrame(captionFrame);
    captionFrame = 0;
    captionLast = 0;
    if (reduced.matches) {
      text(caption, fullQuestion);
      captionTime = 3000;
    } else if (captionVisible && !document.hidden && captionTime < 3000)
      captionFrame = requestAnimationFrame(tickCaption);
  }
  new IntersectionObserver(
    (entries) => {
      captionVisible = entries[0].isIntersecting;
      syncCaption();
    },
    { threshold: 0.4 },
  ).observe(captionRoot);
  document.addEventListener("visibilitychange", syncCaption);
  reduced.addEventListener("change", syncCaption);
  const ambient = [
    ...document.querySelectorAll(".architecture,.privacy-route"),
  ];
  const ambientObserver = new IntersectionObserver(
    (entries) =>
      entries.forEach((entry) => {
        if (entry.isIntersecting && !reduced.matches)
          entry.target.classList.add("flow-shown");
      }),
    { threshold: 0.4 },
  );
  ambient.forEach((node) => ambientObserver.observe(node));
  // Native disclosures work without JS. Deep links additionally open them.
  function revealDetails() {
    const target = document.getElementById(location.hash.slice(1));
    if (target instanceof HTMLDetailsElement) target.open = true;
  }
  window.addEventListener("hashchange", revealDetails);
  revealDetails();
  document.querySelectorAll('a[href^="#"]').forEach((link) =>
    link.addEventListener("click", () => {
      const target = document.getElementById(link.hash.slice(1));
      if (target instanceof HTMLDetailsElement) target.open = true;
    }),
  );
  const examples = {
    zh: {
      interview: {
        question: "为什么选择 early-exit 架构？",
        documents: ["Project Report.pdf", "README.md"],
        passage:
          "简单样本在浅层完成预测，难例继续进入深层；退出阈值用于权衡准确率与推理成本。",
        answer:
          "我希望让计算量跟着样本难度走。简单样本尽早输出，复杂样本继续计算；再用验证集调整退出阈值，比较准确率与推理成本，决定这个取舍是否合适。",
        source: "Project Report.pdf · p. 6",
      },
      meeting: {
        question: "如果只能先上线一个功能，你会怎么判断优先级？",
        documents: ["Product Strategy.md", "Roadmap.docx"],
        passage: "优先考虑用户覆盖范围、实现成本和是否阻塞后续能力。",
        answer:
          "我会先看三个因素：用户覆盖范围、实现成本，以及它是否会阻塞后续能力。如果一个功能覆盖更多用户，同时又是后续能力的基础，我会优先上线它。",
        source: "Product Strategy.md · § 4",
      },
      defense: {
        question: "为什么这里使用 ubRMSE？",
        documents: ["Thesis.pdf", "Experiment Results.pdf"],
        passage:
          "ubRMSE 去除平均偏差的影响，用于观察随机误差；与 Bias、RMSE 一起报告。",
        answer:
          "因为我想把系统性偏差和随机误差分开看。ubRMSE 去除了平均偏差的影响，但不能单独说明整体表现，所以我同时报告 Bias 和 RMSE，让比较更完整。",
        source: "Thesis.pdf · p. 18",
      },
      manual: {
        question: "帮我总结一下这个项目最值得讲的三个点。",
        documents: ["Project Overview.md", "Review Notes.txt"],
        passage:
          "项目复盘：明确实际问题，解释技术取舍，使用可复现的实验检查结果。",
        answer:
          "我会讲三个点：先说清楚项目解决了什么实际问题；再解释为什么选择这条技术路线；最后展示可以复现的验证结果，以及目前还存在的局限。",
        source: "Project Overview.md · § 2",
      },
    },
    en: {
      interview: {
        question: "Why did you choose an early-exit architecture?",
        documents: ["Project Report.pdf", "README.md"],
        passage:
          "Easy samples exit at shallow layers; difficult samples continue deeper. Exit thresholds trade accuracy against inference cost.",
        answer:
          "I wanted the compute budget to follow the difficulty of each sample. Easy inputs exit early; harder ones keep going. I would tune the exit threshold on a validation set and compare accuracy with inference cost before choosing the trade-off.",
        source: "Project Report.pdf · p. 6",
      },
      meeting: {
        question:
          "If you could ship only one feature first, how would you prioritize it?",
        documents: ["Product Strategy.md", "Roadmap.docx"],
        passage:
          "Prioritize user reach, implementation cost, and dependencies for future work.",
        answer:
          "I would weigh three things: user impact, development cost, and whether it unlocks future work. If a feature reaches more users and gives us a foundation to build on, I would ship it first.",
        source: "Product Strategy.md · § 4",
      },
      defense: {
        question: "Why use ubRMSE here?",
        documents: ["Thesis.pdf", "Experiment Results.pdf"],
        passage:
          "ubRMSE removes mean bias to examine random error. Report it alongside Bias and RMSE.",
        answer:
          "I wanted to separate systematic bias from random error. ubRMSE removes the effect of mean bias, but it cannot describe overall performance on its own. I report Bias and RMSE alongside it for a fuller comparison.",
        source: "Thesis.pdf · p. 18",
      },
      manual: {
        question:
          "Summarize the three most useful points to discuss about this project.",
        documents: ["Project Overview.md", "Review Notes.txt"],
        passage:
          "Project review: define the practical problem, explain technical choices, and verify the outcome with reproducible experiments.",
        answer:
          "I would focus on three things: the practical problem the project addresses, the reasons behind the technical choices, and reproducible results—along with the limitations that still remain.",
        source: "Project Overview.md · § 2",
      },
    },
  };
  const cases = examples[english ? "en" : "zh"];
  const tabs = [...document.querySelectorAll("[data-case]")];
  const panel = document.querySelector("#case-panel");
  const caseProduct = document.querySelector('[data-product="case"]');
  let panelAnimation;
  function selectCase(tab) {
    tabs.forEach((button) => {
      button.setAttribute("aria-selected", String(button === tab));
      button.tabIndex = button === tab ? 0 : -1;
    });
    const example = cases[tab.dataset.case];
    panel.setAttribute("aria-labelledby", tab.id);
    document.querySelector("#case-question").textContent = example.question;
    document.querySelector("#case-passage").textContent = example.passage;
    part(caseProduct, "answer").textContent = example.answer;
    part(caseProduct, "question").textContent = example.question;
    part(caseProduct, "source-label").textContent =
      "[S1] " + example.documents[0] + " · " + (english ? "chunk 1" : "片段 1");
    part(caseProduct, "source-passage").textContent = example.passage;
    caseProduct
      .querySelectorAll("details")
      .forEach((item) => (item.open = false));
    document.querySelector("#case-documents").replaceChildren(
      ...example.documents.map((name) => {
        const span = document.createElement("span");
        span.textContent = name;
        return span;
      }),
    );
    panelAnimation?.cancel();
    if (!reduced.matches)
      panelAnimation = panel.animate([{ opacity: 0.6 }, { opacity: 1 }], {
        duration: 250,
        easing: "ease-out",
      });
  }
  tabs.forEach((tab, index) => {
    tab.addEventListener("click", () => selectCase(tab));
    tab.addEventListener("keydown", (event) => {
      let next;
      if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
      if (event.key === "ArrowLeft")
        next = (index + tabs.length - 1) % tabs.length;
      if (event.key === "Home") next = 0;
      if (event.key === "End") next = tabs.length - 1;
      if (next !== undefined) {
        event.preventDefault();
        tabs[next].focus();
        selectCase(tabs[next]);
      }
    });
  });
})();
