# LiveCopilot product pages

Chinese lives at `/LiveCopilot/`; English at `/LiveCopilot/en/`. The language
control links between complete HTML pages and works without JavaScript.

## Content and design

The landing page preserves the seven original narrative sections in the supplied Chinese and English
website copy: promise, recall under pressure, personal materials, three-step
preparation, use cases, local knowledge/privacy, and download. Preserve both
languages together in `content.json`. The editorial blockquote in the supplied
brief is layout guidance, not customer-facing text.

Palette: porcelain `#F5F8FC`, white `#FFFFFF`, ink `#1C2D46`, cobalt `#166DED`,
rose `#EC91B7`, and rules `#D6DFEC`. Local SF Pro/PingFang and platform fallbacks
match the native product. Text remains left-aligned, with a centered final desktop
CTA. Headings use balanced wrapping; body text stays within comfortable measures.

The main visual is a synthetic native conversation window paired with prepared
reference sheets. Quiet editorial sections and three sequential steps explain
how preparation returns during a conversation. Review against the copy removed
the previous prominent model table. In V1.4 the user requested an additional, always-visible service guide: three modules explain speech, embeddings and analysis; a dedicated comparison distinguishes semantic Live delegation from local text rules. No service information is hidden in a disclosure.
No repeated feature-card grid, ornamental metrics, or automatic motion.

The supplied privacy promise is accompanied by a visible qualification for cloud
speech/embedding routes. Do not imply every configuration is fully offline.
The examples use a fictional project; no personal documents or recordings appear.
JavaScript only switches scripted suggestions and opens explicitly linked details.
There are no model calls, external fonts, trackers, cookies, or frontend dependencies.

## Build, check, publish

```bash
python3 StealthApp/scripts/build-site.py
python3 -m http.server 18744 --directory _site
```

Edit `content.json`, `template.html`, and `styles.css`. Keep assets consistent with
`assets/brand/`. Page images use the 512px transparent PNG at 29–72 CSS pixels
to keep the icon crisp on high-density displays without browser SVG shadow-filter
rasterization. The vector stays available for the favicon and editable master.
The listening row owns both separators and centers its label/waveform together.
The builder requires matching translation keys and escapes all
content. Only display keys ending in `_rich` support `**strong emphasis**`; other
HTML and Markdown are not interpreted.

Check both languages at desktop and mobile widths, the three demo buttons,
Chinese/English navigation, installation deep links, always-visible services and responsive comparisons, keyboard focus, and download URLs. The GitHub Pages workflow publishes
only `_site/` when site inputs change on `main`. App builds and signatures are
independent of these website-only updates.

## Copy refresh verification — 2026-09-16

- Compared all 37 customer-facing copy blocks in each supplied document with
  generated page text (ignoring emphasis markup and typographic line breaks).
- Browser checked both languages at 1280px desktop and 390px/320px mobile widths;
  no horizontal overflow or missing images.
- Verified language navigation, scripted suggestions, technical disclosure,
  installation deep-link expansion and keyboard toggling.
- Static build checked matching translation keys, unique IDs, local assets and
  language destinations. No native app changes or model requests were needed.
