# LiveCopilot product pages

Chinese lives at `/LiveCopilot/`; English at `/LiveCopilot/en/`. Both are complete
static HTML pages. The language links, installation instructions, service guide,
source disclosure, and downloads work without JavaScript.

## Build and publish

```sh
python3 StealthApp/scripts/build-site.py
python3 -m http.server 18744 --directory _site
```

Edit `content.json`, `template.html`, `styles.css`, `phase5.css`, `product.css`, `components/*.html`, and `demo.js`. The existing
Python builder escapes translated copy and requires matching translation keys.
The site needs no frontend package installation. The Hero uses a static PNG hardware shell; there are no external fonts, trackers, cookies, audio capture, or model requests. GitHub Pages publishes `_site/` through
`.github/workflows/pages.yml` when website inputs change on `main`.

## Design and behavior

The September 2026 redesign follows the supplied v1.1 visual specification:
cool gray `#F6F7F9`, secondary gray `#F1F3F6`, ink `#111318`, quiet glass product
windows, native system typography, and a dark `#090A0C` privacy section. The
product window is the main visual, with transcript, knowledge retrieval, answer,
and associated sources. No internal reasoning is displayed.

`demo.js` owns one finite 12-second hero timeline. It stops advancing when the window
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
XLSX example is represented as an exported PDF. Native Markdown sources use chunk references; the external document illustration may also name a section. PDF sources use pages and chunks. Local speech and BGE-M3 can
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

See `docs/WEBSITE_PHASE2_QA_2026-09-20.md` for browser, interaction, accessibility,
performance, backup, and deployment evidence. Browser QA tools are development
utilities, not site dependencies. Native app changes and native app releases
are independent of this website deployment.

## Phase 2: product accuracy

The website frame remains designed for the web. Product UI is now separate:
`components/product-ui.html` contains the real single-column overlay hierarchy;
`product-transcript.html` and `product-answer.html` are shared fragments used by
Hero, feature cards, the workflow, and use cases. The Python builder renders
these before substituting the page template. `product.css` has independent
material, radius, padding, and typography tokens derived from `OverlayView.swift`.

Reference sources are `OverlayView.swift`, `OverlayWindow.swift`,
`OverlayLayout.swift`, `WindowBackgroundView.swift`, `AppBrandTitle.swift`,
`SuggestionMode.swift`, `Localization.swift`, and current repository screenshots.
A data-only native fixture renders the unchanged SwiftUI view for comparison;
this is a source-rendered reference, not a screenshot of a production session.

The overlay has no macOS traffic-light titlebar or document sidebar. It shows
native header controls, automatic suggestions, transcript/follow state, actions,
question, answer sections, individual `[S1]` / `[S2]` disclosures, manual input,
recent-context checkbox, scenario, copy, shortcut, and resize glyph. Header
controls and toggles are visual replicas rather than simulated app settings.
Sources and Copy work; typing does not send a request. Answer and transcript
updates occur by phrase, not by character.

Document cards, the retrieval connection, phase labels, and playback controls
are explicitly outside the product layer. The edge demo uses the actual idle
state and fades the window completely out. The app has no persistent handle:
`OverlayWindow.tuckAway` calls `orderOut`, while right-edge dwell calls `reveal`.
A separate, labeled website button makes the demonstration usable with touch
and keyboard. The website does not reproduce every native preference or action.

Sources stay in the answer's scroll region; opening them cannot resize the Hero.
A 24px minimum disclosure target is a web accessibility adaptation. Mobile
product panes reflow within the available width; the desktop-miniature card
scales its native idle window independently. Reduced motion shows final results.

Services now have a visible Hear / Retrieve / Respond overview leading to the
existing detailed guide. Privacy remains a dark section. Social preview art uses
the same product component and no longer shows the previous conceptual UI.

## Phase 5: static hardware, live software

`phase5.css` owns a fixed 60/40 desktop composition. The right half of the
MacBook extends beyond the left viewport edge. `assets/hero-macbook-shell.png`
is a local transparent hardware illustration, with a live HTML product window
above a CSS desktop background. The hardware fades in once without movement.
`demo.js` animates only the title and the finite software demonstration.
Mobile reflows the copy above the hardware. Reduced motion shows the final state.

The workflow has four aligned desktop columns; Answer receives 1.45 shares.
Phase 4/4.1 runtime and vendor assets are preserved in `experiments/phase4-3d/`.
They are excluded from the clean build and are never loaded in production.

## Directory map

- `site/`: sole editable website source, bilingual copy, shared native UI and assets.
- `site/experiments/`: retired implementation references, excluded from publication.
- `site/reference/`: original website copy documents, retained for reference.
- `_site/`: disposable generated output; do not edit.
- `StealthApp/scripts/build-site.py`: dependency-free website builder.
- `docs/`: specifications and dated QA records.
- `dist/website-backups/`: local source backups; not published.
- Root `assets/`, `output/`, and `小红书图/`: app/promotion material, not website source.
