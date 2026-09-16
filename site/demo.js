// A synthetic, local-only product example. It never records audio or calls a model.
const controls = [...document.querySelectorAll('[data-example]')];
const content = document.querySelector('#example-copy');
const title = document.querySelector('#example-title');
controls.forEach(button => button.addEventListener('click', () => {
  controls.forEach(control => control.setAttribute('aria-pressed', String(control === button)));
  title.textContent = button.dataset.title;
  content.textContent = document.querySelector(`#${button.dataset.example}`).content.textContent.trim();
}));

// Deep links reveal the corresponding secondary information. Native details
// remain usable without JavaScript; do not expand them on ordinary page load.
function revealLinkedDetails() {
  const section = document.getElementById(location.hash.slice(1));
  if (section instanceof HTMLDetailsElement) section.open = true;
}
window.addEventListener('hashchange', revealLinkedDetails);
revealLinkedDetails();
document.querySelectorAll('a[href="#install"], a[href="#services"]').forEach(link => {
  link.addEventListener('click', () => {
    const section = document.getElementById(link.hash.slice(1));
    if (section instanceof HTMLDetailsElement) section.open = true;
  });
});
