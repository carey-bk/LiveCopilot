# LiveCopilot product pages

The Chinese page is `/LiveCopilot/`; English is `/LiveCopilot/en/`.
The language control is a normal link between complete HTML pages, so it also works without JavaScript.
JavaScript is used only for the explicitly scripted product example; it never requests audio or model access.

Design: porcelain `#F5F8FC`, white `#FFFFFF`, ink `#1C2D46`, cobalt `#166DED`, rose `#EC91B7`, and rules `#D6DFEC`.
Local SF Pro/PingFang and platform fallbacks match the native product. The hero pairs a direct headline with a synthetic floating window; the rest uses quiet text, a service comparison table and a data-flow explanation. No external fonts, trackers, cookies or runtime dependencies.

Build and preview from the repository root:

```bash
python3 StealthApp/scripts/build-site.py
python3 -m http.server 18744 --directory _site
```

Edit `content.json` for both languages, `template.html` for structure and `styles.css` for appearance. Keep the copied assets consistent with `assets/brand/`. The builder requires matching translation keys and escapes content before rendering.
The GitHub Pages workflow publishes only `_site/` when site inputs change on `main`.
