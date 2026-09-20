// Progressive enhancement: static product content is the default, including without JS.
const hero = document.querySelector(".hero");
const stage = document.querySelector(".cinema-stage");
const reduced = matchMedia("(prefers-reduced-motion: reduce)");
const narrow = matchMedia("(max-width: 900px)");
const desktop = stage.querySelector(".cinema-desktop");
let time = 0,
  scene,
  finished = false,
  suspended = false,
  pendingFactory;
const sizeDesktop = () => {
  stage.style.setProperty("--desktop-scale", String(stage.clientWidth / 1200));
  stage.classList.toggle("desktop-scaled", !narrow.matches);
};
let measuredWidth = -1,
  sizeFrame = 0;
new ResizeObserver((entries) => {
  const width = entries[0].contentRect.width;
  if (Math.abs(width - measuredWidth) < 0.5) return;
  measuredWidth = width;
  cancelAnimationFrame(sizeFrame);
  sizeFrame = requestAnimationFrame(sizeDesktop);
}).observe(stage);
sizeDesktop();
const fallback = () => {
  finished = true;
  pendingFactory = undefined;
  scene?.dispose();
  scene = undefined;
  stage.classList.remove("cinema-loading", "is-spatial");
  if (desktop.parentElement !== stage) stage.append(desktop);
  desktop.removeAttribute("style");
  stage.querySelectorAll("canvas,.cinema-space").forEach((e) => e.remove());
  document.dispatchEvent(new Event("hero-fallback"));
};
// Reserve the final title geometry; only glyph visibility changes.
if (!reduced.matches) {
  const letters = [...document.querySelectorAll(".title-character")];
  hero.classList.add("typing");
  let count = 0;
  const cursor = document.querySelector(".title-cursor");
  const placeCursor = () => {
    const glyph =
      letters[
        Math.max(0, Math.min(count - 1, letters.length - 1))
      ].getBoundingClientRect();
    const heading = document
      .querySelector("#hero-heading")
      .getBoundingClientRect();
    cursor.style.transform = `translate(${(count ? glyph.right : glyph.left) - heading.left + 5}px, ${glyph.top - heading.top + glyph.height * 0.15}px)`;
  };
  placeCursor();
  const interval = setInterval(() => {
    if (reduced.matches || document.hidden) count = letters.length;
    else count += document.documentElement.lang === "en" ? 3 : 1;
    letters.slice(0, count).forEach((c) => c.classList.add("revealed"));
    placeCursor();
    if (count >= letters.length) {
      clearInterval(interval);
      hero.classList.remove("typing");
      hero.classList.add("typed");
    }
  }, 55);
}
document.addEventListener("hero-playback", (event) => {
  suspended = event.detail.suspended;
});
document.addEventListener("hero-clock", (event) => {
  time = event.detail.time;
  if (time >= 12000) finished = true;
  if (pendingFactory && !suspended && !finished) {
    try {
      scene = pendingFactory(stage);
    } catch {
      fallback();
    }
    pendingFactory = undefined;
  }
  scene?.render(time);
});
// No continuous WebGL loop: the finite product clock owns rendering.
const observer = new IntersectionObserver(
  async (entries) => {
    if (!entries[0].isIntersecting) return;
    observer.disconnect();
    if (
      reduced.matches ||
      narrow.matches ||
      navigator.connection?.saveData ||
      (navigator.hardwareConcurrency && navigator.hardwareConcurrency < 4)
    )
      return fallback();
    stage.classList.add("cinema-loading");
    const timeout = setTimeout(fallback, 1800);
    try {
      const { createScene } = await import("./cinematic-scene.js");
      if (finished || reduced.matches || narrow.matches || time > 1800)
        return fallback();
      if (suspended) pendingFactory = createScene;
      else {
        scene = createScene(stage);
        scene.render(time);
      }
      stage.classList.remove("cinema-loading");
    } catch {
      fallback();
    } finally {
      clearTimeout(timeout);
    }
  },
  { rootMargin: "100px" },
);
observer.observe(stage);
reduced.addEventListener("change", () => {
  if (reduced.matches) fallback();
});
narrow.addEventListener("change", () => {
  if (narrow.matches) fallback();
});
window.addEventListener("pagehide", () => scene?.dispose(), { once: true });
