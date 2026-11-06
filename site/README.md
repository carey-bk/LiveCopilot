# LiveCopilot product pages

Simplified Chinese lives at `/LiveCopilot/`, Traditional Chinese at `/LiveCopilot/zh-Hant/`, and English at `/LiveCopilot/en/`. All three are complete
static HTML pages. The language links, installation instructions, service guide,
use cases, and downloads work without JavaScript; the hero is built in its finished state.

## Build and publish

```sh
python3 StealthApp/scripts/build-site.py
python3 -m http.server 18744 --directory _site
```

Edit `content.json`, `examples.json`, `template.html`, `styles.css`, and `demo.js`. The
Python builder escapes all copy, requires matching keys in every language, and takes the
version, size, SHA-256 and download URLs from `download.json` (`{version}` and `{size}`
placeholders in copy are filled from it). Copy marked `*_phrases` uses `|` between Chinese
phrases so lines break only between them. The site needs no frontend packages, external
fonts, trackers, cookies, audio capture, or model requests. GitHub Pages publishes `_site/`
through `.github/workflows/pages.yml` when website inputs change on `main`.

The Hong Kong OSS mirror is the primary download; GitHub Releases is the labelled fallback.
`updates/appcast.xml` belongs to the app's updater and is copied unchanged.

## Page structure (2.7 refresh, November 2026)

Each section is one heading, a short paragraph and its main demonstration. Whitespace and thin
rules organise the page; borders are kept for real app windows. There are no page-level
disclosures: model comparisons, prices, endpoints, installation, shortcuts and troubleshooting
live in the linked README and `docs/` guides. API keys, charges and cloud data boundaries are
stated in short sentences where they apply.

1. **Hero** — slogan and download on the left, a static LS Graphics MacBook
   (`assets/ls-front-hardware.webp`) on the right (stacked, copy first, below 1024 px). The 2.7 overlay rises from the
   screen's right edge as an enlarged close-up (CSS `zoom` on wide screens); a true-scale copy on the
   screen stays in sync with it. Phones (below 720 px) show the overlay alone, without the laptop.
   The "2.7" pill links to the release notes.
2. **How it works** (`#workflow`) — one screen: speech transcription, finding materials, answering.
   The matching documents light up in turn as step 2 scrolls into view.
3. **Speech transcription** (`#transcript`, dark, one screen) — the three-line fold in a real overlay
   excerpt, transcript translation with a working target-language menu (Apply / Stop as in the app,
   sample sentences in all eight targets), and the speech engines (Zipformer,
   Apple Speech, OpenAI Live) with their language options.
4. **Materials and answers** (`#answers`) — the three knowledge modes as a radio group, synced with
   the overlay's own mode menu, switch the answer card (General has no sources); answer style and
   sentence pairs share one demonstration with a two-option switch. Alternatives share one grid cell,
   so switching never moves the content below; use cases reserve their tallest example the same way.
5. **Use cases** (`#scenarios`) — four tabs sharing one panel, data from `examples.json`.
6. **Overlay and history** (`#overlay`) — the edge-docking demo plays by itself while on screen
   (every 2 s the window slides away, then a pointer at the edge brings it back) and the history window.
7. **Services** (`#services`) — one ruled list of the three steps and a link to `docs/SERVICE_GUIDE.md`.
8. **Privacy** (`#privacy`, dark) — statement, four facts, data route and boundary note.
9. **Download** (`#download`) — button, GitHub fallback, one line of version and requirements, and
   text links to the user guide, requirements and release history.

Past the privacy page the body background and `theme-color` turn light, so browser bars and
overscroll match the footer. Segmented controls get a sliding indicator and swapped content fades in; buttons ease their colour
and settle slightly when pressed. Reduced motion turns these off, keeps the edge demo still and
shows the document highlights without animation.

Anchors from earlier layouts are redirected by `demo.js` to the section that now holds them.

## Demo behavior

`demo.js` runs one finite hero timeline (about 3.5 s), phrase by phrase: the question is
transcribed, marked complete, and answered; it ends on the finished answer with Sources open.
It pauses when the window leaves the viewport or the page is hidden, and the play control can
pause, resume, or replay it. Reduced motion keeps the finished state. If the action row cannot
fit, the whole window scales slightly rather than hiding any button. Nothing is recorded,
submitted, or sent to a model.

## Product accuracy

Overlay strings, icons and states follow the released 2.7.0 sources (`OverlayView.swift`,
`ConversationFlowView.swift`, `Localization.swift`); Traditional Chinese interface strings use
the app's own `Hans-Hant` transform. Conversations, documents and answers are examples.
Schematic visuals (document list, history list, edge demo) are labelled as illustrations.
Claims are limited to the release: screen-share hiding is optional, off by default and must be
tested with the meeting app; translation uses the answer service and its API usage. In-app
updates are not presented as a feature. Default models and endpoints in the answer guide come
from the 2.7.0 source (`AnalysisModelCatalog.swift`, `AnalysisPresets.swift`), which takes
precedence where `docs/SERVICE_GUIDE.md` differs; prices follow `ServiceGuide.checked`.

## Directory map

- `site/`: sole editable website source, trilingual copy, and assets.
- `site/experiments/`: retired implementation references, excluded from publication.
- `site/reference/`: original website copy documents, retained for reference.
- `_site/`: disposable generated output; do not edit.
- `StealthApp/scripts/build-site.py`: dependency-free website builder.
- `docs/`: specifications and dated QA records.
- `dist/website-backups/`: local source backups; not published.
