// Entirely scripted, browser-local examples. Never records or calls a service.
(() => {
  "use strict";
  document.documentElement.classList.add("js");
  const reduced = matchMedia("(prefers-reduced-motion: reduce)");
  const header = document.querySelector(".site-header");
  const menu = document.querySelector(".menu-toggle");
  const links = document.querySelector(".nav-links");
  const closeMenu = () => {
    links.classList.remove("open");
    menu.setAttribute("aria-expanded", "false");
  };
  menu.addEventListener("click", () => {
    const open = links.classList.toggle("open");
    menu.setAttribute("aria-expanded", String(open));
  });
  links.addEventListener("click", (event) => {
    if (event.target.closest("a")) closeMenu();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && links.classList.contains("open")) {
      closeMenu();
      menu.focus();
    }
  });
  const updateHeader = () => header.classList.toggle("scrolled", scrollY > 20);
  window.addEventListener("scroll", updateHeader, { passive: true });
  updateHeader();
  const demo = document.querySelector("#hero-demo");
  const transcript = document.querySelector("#transcript");
  const answer = document.querySelector("#demo-answer");
  const status = document.querySelector("#demo-status");
  const source = document.querySelector("#demo-sources");
  const toggle = document.querySelector(".demo-toggle");
  const fullQuestion = transcript.textContent;
  const fullAnswer = answer.textContent;
  // One declarative timeline; elapsed time only advances in a visible viewport.
  const timeline = [
    { at: 0, state: "listening" },
    { at: 500, state: "transcribing" },
    { at: 3000, state: "understanding" },
    { at: 3600, state: "retrieving" },
    { at: 5300, state: "organizing" },
    { at: 6200, state: "answering" },
    { at: 9500, state: "sources" },
    { at: 10500, state: "complete" },
    { at: 13000, state: "resetting" },
  ];
  const cycle = 14000;
  const answerChunks = fullAnswer.match(
    /[^，。！？,.;!?]+[，。！？,.;!?]?\s*/g,
  ) || [fullAnswer];
  let elapsed = 0,
    previous = 0,
    lastPaint = -Infinity,
    frame = 0,
    visible = false,
    paused = false;
  let currentState = "";
  function setText(element, value) {
    if (element.textContent !== value) element.textContent = value;
  }
  function render(time) {
    const state = [...timeline]
      .reverse()
      .find((phase) => time >= phase.at).state;
    if (state !== currentState) {
      currentState = state;
      demo.dataset.state = state;
    }
    const questionProgress = Math.max(0, Math.min(1, (time - 500) / 2500));
    const answerProgress = Math.max(0, Math.min(1, (time - 6200) / 3300));
    setText(
      transcript,
      fullQuestion.slice(
        0,
        Math.ceil(fullQuestion.length * questionProgress),
      ) || "\u00a0",
    );
    setText(
      answer,
      answerChunks
        .slice(0, Math.ceil(answerChunks.length * answerProgress))
        .join("") || "\u00a0",
    );
    const statusKey = ["sources", "complete", "resetting"].includes(state)
      ? "complete"
      : state === "transcribing"
        ? "listening"
        : state;
    setText(status, demo.dataset[statusKey]);
    source.style.visibility = time >= 9500 ? "visible" : "hidden";
    // Opacity preserves layout through the whole sequence.
    demo.querySelector(".context-tags").style.visibility =
      time >= 5300 ? "visible" : "hidden";
  }
  function showFinal() {
    currentState = "complete";
    demo.dataset.state = "complete";
    setText(transcript, fullQuestion);
    setText(answer, fullAnswer);
    setText(status, demo.dataset.complete);
    source.style.visibility = "visible";
    demo.querySelector(".context-tags").style.visibility = "visible";
  }
  function tick(now) {
    if (previous) elapsed = (elapsed + now - previous) % cycle;
    previous = now;
    if (now - lastPaint > 80) {
      render(elapsed);
      lastPaint = now;
    }
    frame = requestAnimationFrame(tick);
  }
  function sync() {
    cancelAnimationFrame(frame);
    frame = 0;
    previous = 0;
    const running =
      visible &&
      !document.hidden &&
      !reduced.matches &&
      !paused &&
      !source.open;
    demo.classList.toggle("motion-active", running);
    if (running) frame = requestAnimationFrame(tick);
    if (reduced.matches) showFinal();
    toggle.textContent = paused || reduced.matches ? "▶" : "Ⅱ";
    toggle.setAttribute(
      "aria-label",
      paused || reduced.matches ? toggle.dataset.play : toggle.dataset.pause,
    );
    toggle.hidden = reduced.matches;
  }
  toggle.addEventListener("click", () => {
    paused = !paused;
    sync();
  });
  source.addEventListener("toggle", sync);
  // Keep typing and source inspection stable rather than resetting under focus.
  demo.querySelector("input").addEventListener("focus", () => {
    paused = true;
    showFinal();
    sync();
  });
  new IntersectionObserver(
    (entries) => {
      visible = entries[0].isIntersecting;
      sync();
    },
    { threshold: 0 },
  ).observe(demo);
  document.addEventListener("visibilitychange", sync);
  reduced.addEventListener("change", sync);
  // One visible-time animation for the workflow; retain the final state.
  const workflow = document.querySelector(".workflow");
  const nodes = [...workflow.children];
  let workflowStarted = false,
    workflowElapsed = 0,
    workflowPrevious = 0,
    workflowFrame = 0,
    workflowVisible = false;
  if (!reduced.matches) workflow.classList.add("pending");
  function workflowTick(now) {
    if (workflowPrevious) workflowElapsed += now - workflowPrevious;
    workflowPrevious = now;
    nodes.forEach((node, index) =>
      node.classList.toggle("active", workflowElapsed >= index * 1600),
    );
    if (workflowElapsed < 5600)
      workflowFrame = requestAnimationFrame(workflowTick);
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
      workflowElapsed = 5600;
      workflow.classList.remove("pending");
      return;
    }
    if (
      workflowStarted &&
      workflowVisible &&
      !document.hidden &&
      workflowElapsed < 5600
    )
      workflowFrame = requestAnimationFrame(workflowTick);
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
  const cards = document.querySelectorAll(".feature-card");
  const cardObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) =>
        entry.target.classList.toggle("in-view", entry.isIntersecting),
      );
      syncCards();
    },
    { threshold: 0.2 },
  );
  cards.forEach((card) => cardObserver.observe(card));
  function syncCards() {
    cards.forEach((card) =>
      card.classList.toggle(
        "motion-active",
        !document.hidden &&
          !reduced.matches &&
          card.classList.contains("in-view"),
      ),
    );
  }
  document.addEventListener("visibilitychange", syncCards);
  reduced.addEventListener("change", syncCards);
  const floating = document.querySelector(".floating-preview");
  document
    .querySelector(".edge-toggle")
    .addEventListener("click", () =>
      tuck(!floating.classList.contains("tucked")),
    );
  function tuck(value) {
    floating.classList.toggle("tucked", value);
    floating.setAttribute("aria-pressed", String(value));
    document
      .querySelector(".edge-toggle")
      .setAttribute("aria-pressed", String(value));
  }
  floating.addEventListener("click", () =>
    tuck(!floating.classList.contains("tucked")),
  );
  floating
    .closest(".desktop-preview")
    .addEventListener("pointerenter", (event) => {
      if (event.pointerType === "mouse") tuck(false);
    });
  floating
    .closest(".desktop-preview")
    .addEventListener("pointerleave", (event) => {
      if (event.pointerType === "mouse") tuck(true);
    });
  function revealLinkedDetails() {
    const target = document.getElementById(location.hash.slice(1));
    if (target instanceof HTMLDetailsElement) target.open = true;
  }
  window.addEventListener("hashchange", revealLinkedDetails);
  revealLinkedDetails();
  document.querySelectorAll('a[href^="#"]').forEach((link) =>
    link.addEventListener("click", () => {
      const target = document.getElementById(link.hash.slice(1));
      if (target instanceof HTMLDetailsElement) target.open = true;
    }),
  );

  // A single, three-second caption demonstration in the first feature card.
  const caption = document.querySelector(".mini-transcript p");
  const captionFull = caption.textContent;
  let captionTime = 0,
    captionLast = 0,
    captionFrame = 0,
    captionVisible = false;
  function captionTick(now) {
    if (captionLast) captionTime += now - captionLast;
    captionLast = now;
    setText(
      caption,
      captionFull.slice(
        0,
        Math.max(
          1,
          Math.ceil(captionFull.length * Math.min(1, captionTime / 3000)),
        ),
      ),
    );
    if (captionTime < 3000) captionFrame = requestAnimationFrame(captionTick);
    else captionFrame = 0;
  }
  function syncCaption() {
    cancelAnimationFrame(captionFrame);
    captionFrame = 0;
    captionLast = 0;
    if (reduced.matches) {
      setText(caption, captionFull);
      captionTime = 3000;
    } else if (captionVisible && !document.hidden && captionTime < 3000)
      captionFrame = requestAnimationFrame(captionTick);
  }
  new IntersectionObserver(
    (entries) => {
      captionVisible = entries[0].isIntersecting;
      syncCaption();
    },
    { threshold: 0.4 },
  ).observe(caption.closest(".feature-card"));
  document.addEventListener("visibilitychange", syncCaption);
  reduced.addEventListener("change", syncCaption);
  const architecture = document.querySelector(".architecture");
  new IntersectionObserver(
    (entries) => {
      if (entries[0].isIntersecting && !reduced.matches)
        architecture.classList.add("flow-shown");
    },
    { threshold: 0.4 },
  ).observe(architecture);

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
  const cases = examples[document.documentElement.lang === "en" ? "en" : "zh"];
  const tabs = [...document.querySelectorAll("[data-case]")];
  const panel = document.querySelector("#case-panel");
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
    document.querySelector("#case-answer").textContent = example.answer;
    document.querySelector("#case-source").textContent = example.source;
    document.querySelector("#case-documents").replaceChildren(
      ...example.documents.map((name) => {
        const span = document.createElement("span");
        span.textContent = name;
        return span;
      }),
    );
    panelAnimation?.cancel();
    if (!reduced.matches)
      panelAnimation = panel.animate(
        [
          { opacity: 0.5, transform: "translateY(3px)" },
          { opacity: 1, transform: "translateY(0)" },
        ],
        { duration: 280, easing: "cubic-bezier(.22,1,.36,1)" },
      );
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
