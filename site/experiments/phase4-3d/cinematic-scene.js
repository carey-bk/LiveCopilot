import * as THREE from "./assets/vendor/three.module.min.js";
import { CSS3DRenderer, CSS3DObject } from "./assets/vendor/CSS3DRenderer.js";
// A deliberately light, procedural laptop. Product text never enters a texture.
export function createScene(stage) {
  const desktop = stage.querySelector(".cinema-desktop");
  const renderer = new THREE.WebGLRenderer({
    alpha: true,
    antialias: true,
    powerPreference: "low-power",
  });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 1.5));
  renderer.setClearColor(0, 0);
  const css = new CSS3DRenderer();
  css.domElement.className = "cinema-space";
  const world = new THREE.Scene(),
    domWorld = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(38, 1.6, 0.1, 100);
  const metal = new THREE.MeshStandardMaterial({
    color: 0x30343c,
    metalness: 0.72,
    roughness: 0.38,
  });
  const black = new THREE.MeshStandardMaterial({
    color: 0x0b0d12,
    metalness: 0.2,
    roughness: 0.6,
  });
  const silver = new THREE.MeshStandardMaterial({
    color: 0x535864,
    metalness: 0.65,
    roughness: 0.42,
  });
  function box(w, h, d, x, y, z, mat = metal) {
    const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat);
    m.position.set(x, y, z);
    world.add(m);
    return m;
  }
  function rounded(w, h, d, r, mat) {
    const x = -w / 2,
      y = -h / 2,
      s = new THREE.Shape();
    s.moveTo(x + r, y);
    s.lineTo(x + w - r, y);
    s.quadraticCurveTo(x + w, y, x + w, y + r);
    s.lineTo(x + w, y + h - r);
    s.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    s.lineTo(x + r, y + h);
    s.quadraticCurveTo(x, y + h, x, y + h - r);
    s.lineTo(x, y + r);
    s.quadraticCurveTo(x, y, x + r, y);
    const g = new THREE.ExtrudeGeometry(s, {
      depth: d,
      bevelEnabled: true,
      bevelSize: 0.018,
      bevelThickness: 0.012,
      bevelSegments: 2,
      steps: 1,
      curveSegments: 5,
    });
    const m = new THREE.Mesh(g, mat);
    world.add(m);
    return m;
  }
  const lid = rounded(8.35, 5.34, 0.12, 0.16, metal);
  lid.position.z = -0.15;
  box(8.13, 5.13, 0.025, 0, 0, -0.002, black);
  // Lid, deck, keyboard and trackpad use a small number of shared materials.
  const deck = rounded(8.5, 4.5, 0.13, 0.2, metal);
  deck.rotation.x = -Math.PI / 2 + 0.07;
  deck.position.set(0, -2.75, 2.04);
  const keyboard = box(7.3, 0.025, 2.0, 0, -2.49, 1.25, black);
  keyboard.rotation.x = 0.07;
  const keys = new THREE.InstancedMesh(
    new THREE.BoxGeometry(0.43, 0.025, 0.31),
    silver,
    60,
  );
  const matrix = new THREE.Matrix4();
  for (let i = 0; i < 60; i++) {
    matrix.makeTranslation(
      ((i % 15) - 7) * 0.47,
      -2.45,
      Math.floor(i / 15) * 0.39 + 0.6,
    );
    keys.setMatrixAt(i, matrix);
  }
  world.add(keys);
  box(2.65, 0.022, 1.25, 0, -2.52, 3.2, silver);
  world.add(new THREE.HemisphereLight(0xd5e1ff, 0x1b1522, 2));
  const pink = new THREE.DirectionalLight(0xf19bc2, 2);
  pink.position.set(-6, 4, 4);
  world.add(pink);
  const blue = new THREE.DirectionalLight(0x78a7ff, 2.5);
  blue.position.set(6, 5, 2);
  world.add(blue);
  const screen = new CSS3DObject(desktop);
  screen.scale.setScalar(8 / 1200);
  screen.position.z = 0.02;
  domWorld.add(screen);
  stage.append(renderer.domElement, css.domElement);
  stage.classList.add("is-spatial");
  let lastTime = 0,
    disposed = false;
  const smooth = (t) => {
    t = THREE.MathUtils.clamp(t, 0, 1);
    return t * t * (3 - 2 * t);
  };
  function render(t) {
    if (disposed) return;
    lastTime = t;
    if (t >= 3500) {
      dispose();
      return;
    }
    const p = smooth((t - 900) / 2600);
    const endZ = 2.5 / Math.tan(THREE.MathUtils.degToRad(19));
    camera.position.set(
      THREE.MathUtils.lerp(-0.8, 0, p),
      THREE.MathUtils.lerp(2.9, 0, p),
      THREE.MathUtils.lerp(15.8, endZ + 0.02, p),
    );
    camera.lookAt(0, THREE.MathUtils.lerp(-2.5, 0, p), 0);
    camera.updateMatrixWorld();
    renderer.domElement.style.opacity = String(1 - smooth((t - 3100) / 400));
    renderer.render(world, camera);
    css.render(domWorld, camera);
  }
  function resize() {
    if (disposed) return;
    const w = stage.clientWidth,
      h = stage.clientHeight;
    renderer.setSize(w, h);
    css.setSize(w, h);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    render(lastTime);
  }
  function dispose() {
    if (disposed) return;
    disposed = true;
    ro.disconnect();
    stage.append(desktop);
    desktop.removeAttribute("style");
    stage.classList.remove("is-spatial");
    renderer.domElement.remove();
    css.domElement.remove();
    world.traverse((o) => {
      if (o.geometry) o.geometry.dispose();
    });
    metal.dispose();
    black.dispose();
    silver.dispose();
    renderer.dispose();
  }
  renderer.domElement.addEventListener("webglcontextlost", (event) => {
    event.preventDefault();
    dispose();
    document.dispatchEvent(new Event("hero-fallback"));
  });
  let resizeFrame = 0;
  const ro = new ResizeObserver(() => {
    cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(resize);
  });
  ro.observe(stage);
  resize();
  return { render, dispose };
}
