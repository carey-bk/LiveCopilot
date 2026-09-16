// A synthetic, local-only product example. It never records audio or calls a model.
const controls = [...document.querySelectorAll('[data-example]')];
const content = document.querySelector('#example-copy');
const title = document.querySelector('#example-title');
controls.forEach(button => button.addEventListener('click', () => {
  controls.forEach(control => control.setAttribute('aria-pressed', String(control === button)));
  title.textContent = button.dataset.title;
  content.textContent = document.querySelector(`#${button.dataset.example}`).content.textContent.trim();
}));
