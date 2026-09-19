# LiveCopilot product pages

Chinese lives at `/LiveCopilot/`; English at `/LiveCopilot/en/`. Both are complete
static HTML pages. The language links, installation instructions, service guide,
source disclosure, and downloads work without JavaScript.

## Build and publish

```sh
python3 StealthApp/scripts/build-site.py
python3 -m http.server 18744 --directory _site
```

Edit `content.json`, `template.html`, `styles.css`, and `demo.js`. The existing
Python builder escapes translated copy and requires matching translation keys.
The site has no frontend dependencies, external fonts, trackers, cookies, audio
capture, or model requests. GitHub Pages publishes `_site/` through
`.github/workflows/pages.yml` when website inputs change on `main`.

## Design and behavior

The September 2026 redesign follows the supplied v1.1 visual specification:
cool gray `#F6F7F9`, secondary gray `#F1F3F6`, ink `#111318`, quiet glass product
windows, native system typography, and a dark `#090A0C` privacy section. The
product window is the main visual, with transcript, knowledge retrieval, answer,
and associated sources. No internal reasoning is displayed.

`demo.js` owns one 14-second hero timeline. It stops advancing when the window
leaves the viewport, the document is hidden, the user pauses, or Sources opens.
Focusing the mock input pauses the preview and shows its complete answer. No
text is submitted. Reduced motion shows the complete answer immediately.

The workflow plays once after 45% becomes visible and retains its final state.
Its text stays readable in inactive stages; state is conveyed by position and
borders rather than reducing text contrast. Bento cards demonstrate listening,
retrieval, edge hiding, and a speakable answer. Caption motion runs once; other
small decorative animations have finite iterations. The edge demo supports a
visible button and keyboard, in addition to pointer interaction.

Four use cases share one panel and a bilingual data object in `demo.js`.
Arrow keys, Home, and End operate the tab list. Containers reserve space to
avoid movement between examples. All examples use fictional material.

The original service/cost guide remains in a native disclosure at `#services`;
installation and signing instructions remain at `#install`. Direct links open
both disclosures. Their content is preserved from the previous site, rather
than replacing service-specific caveats with a generic privacy promise.

## Product boundaries

Current document imports support PDF, DOCX, Markdown, and TXT. The specification's
XLSX example is represented as an exported PDF. Markdown sources use section
references rather than invented PDF page numbers. Local speech and BGE-M3 can
keep audio processing and indexing on the Mac; cloud speech/embeddings send the
corresponding data to their services. Answer generation sends the question,
relevant conversation, and retrieved passages to the selected analysis service.
API keys use macOS Keychain. There is no LiveCopilot account/backend.

Download remains the signed, notarized v1.4.1 Universal DMG. Apple Speech's
macOS 26 requirement remains in the service guide; the app supports macOS 14+
through its other speech routes.

`assets/social-preview.png` is a 1200×630 composition of the existing brand icon,
headline, and HTML product preview. `assets/logo.png` and the original SVG remain
unchanged. The build includes Open Graph, Twitter card, language alternate,
canonical, and sitemap metadata.

## Verification

See `docs/WEBSITE_REDESIGN_QA_2026-09-19.md` for browser, interaction, accessibility,
performance, backup, and deployment evidence. Browser QA tools are development
utilities, not site dependencies. Native app changes and native app releases
are independent of this website deployment.
