# Website Phase 3 — implementation and verification

Date: 2026-09-20. Scope: bilingual GitHub Pages website only; no native app or release binary changes.
Source brief: `docs/LiveCopilot_Phase3_Cinematic_Semantic_Color.md` (the Desktop path supplied in the request was absent; the matching project document was used).

## Delivered

- Dark cinematic Hero, quiet blue/pink environment lighting, native Avenir Next heavy italic brand proportions.
- One-shot title reveal (55ms Chinese glyphs), cursor follows typed text, blinks three times and disappears. Explicit narrow-screen line break; wide screens use one line.
- Locally hosted Three.js 0.180.0, procedural low-poly laptop, camera dolly and CSS3D projection of the existing DOM product. The screen returns to ordinary DOM at matching dimensions. No canvas product text or invented native controls.
- Finite 12-second listening → retrieval → organizing → answer sequence, phrase chunks, native Sources disclosures. Document illustrations are outside the product UI. Camera resources release at the desktop handoff, roughly 3.5 seconds; the remaining product story uses DOM.
- Three inputs lead into a larger answer, with full reply and evidence instead of a mostly empty fourth card. Blue/input, pink/context, purple/organizing remain explanatory accents; native product colors remain unchanged.
- Warm-white features, subtle use-case ambience, clean-white service overview, ice-blue local processing, nearly monochrome privacy, white final download section. Updated social preview.
- No scroll lock. Scrolling beyond 250px settles the story; viewport/document visibility and the pause button stop its clock. No automatic replay.
- Static, complete fallback for mobile, reduced motion, Save-Data, low CPU concurrency, module failure/timeout and unavailable/lost WebGL. Mobile/reduced-motion tests made **zero Three.js requests**.

## Backup and source isolation

Pre-edit archive:
`../LiveCopilot-website-backups/website-before-phase3-20260920-162822.tar.gz`

Archive readability and SHA-256 companion were checked. Existing native work on `codex/local-ui-refinements` is preserved. Publication uses a website-only branch from remote main in `/tmp/livecopilot-site-publish`.

## Tests

- Python production build: both language pages pass; identical translation key sets.
- Chrome macOS and Playwright WebKit: Chinese/English × 375, 390, 430, 768, 1024, 1280, 1440, 1728px = **32 layout combinations**, no horizontal overflow or uncaught page errors.
- Sources expansion, four scenario tabs, keyboard arrows/Home/End, mobile menu/Escape, hide/reveal, deep-linked disclosures, no-JavaScript product/links checked.
- Animated Chrome and WebKit runs: all eight product states, stable stage bounds, finite completion, no automatic replay or uncaught errors.
- Explicit blocked scene-module and unavailable-WebGL tests render the complete fallback. Pause stops camera/product changes. Scrolling offscreen removes the WebGL canvas. Reduced motion and mobile do not fetch the vendor runtime.
- axe-core WCAG 2/2.1 A/AA checks: Chinese/English at 390 and 1440px, zero violations.
- Screenshots inspected for laptop, desktop handoff, Hero, mobile Hero, workflow and complete pages. Product fragments continue to use the native-source-aligned Phase 2 implementation.

### Lighthouse (local production build, separate final runs)

| Mode | Performance | Accessibility | Best practices | SEO | LCP | CLS |
|---|---:|---:|---:|---:|---:|---:|
| Desktop | 98 | 100 | 100 | 100 | 1.1s | 0.006 |
| Mobile | 98 | 100 | 100 | 100 | 2.0s | 0 |

These are lab measurements, not field Core Web Vitals. Real-user INP is **not measured**. The small desktop CLS is below the 0.1 budget, but is not claimed to be exactly zero. Third-party telemetry was not added.

### Explicit verification limits

Native Safari WebDriver returned: “You must enable 'Allow remote automation' in the Developer section of Safari Settings.” That setting was not changed. **Native macOS Safari and physical iOS Safari remain unverified.** Playwright WebKit coverage is not represented as those device/browser tests.

The laptop is a lightweight procedural illustration, not a photorealistic Apple CAD asset. The camera enters the embedded desktop area without forcing fullscreen or scrolling. GPU appearance and system-font rendering can vary by device.

Raw scripts, screenshots and results are archived outside the repository at:
`../LiveCopilot-website-backups/phase3-qa-20260920/`.

## Publication

Published website commit: `1465705affd6acb710e8a850d56c251d0a7ec3af` (main Phase 3 implementation: `e1568ce5d49a72f3d36040d6ee65ca8ddeeb3b55`).

GitHub Pages build and deployment succeeded:
https://github.com/carey-bk/LiveCopilot/actions/runs/35507343164

Public URLs: https://carey-bk.github.io/LiveCopilot/ and https://carey-bk.github.io/LiveCopilot/en/ .

All 12 checked public files match the final production build by SHA-256: both HTML pages, base/product/cinematic CSS, demo/cinematic/scene JS, social image, and all three runtime modules. Raw evidence: `live-hashes.json`.

Live Chinese/English mobile checks passed for Sources, edge hide/reveal, scenario switching and width; no uncaught page errors. Live progressive-enhancement checks passed for mobile, reduced motion, unavailable WebGL, leaving the viewport and pause.

Cold-start testing caught a late module appearing after Pause. The final patch propagates playback state to async initialization; a deterministic delayed-import test confirms no scene initializes while paused and Resume initializes it once. The published patch passed the live pause regression.


## Cold-load correction — 2026-09-20 follow-up

A fresh public desktop session reproduced the user's missing MacBook: the page remained in `cinema-loading` until the old 1800ms timeout, then became static `complete`. The published source was correct; the initialization deadline was too short for real network loading. The old global `scrollY > 250` shortcut could also finish the story when scrolling down merely to see the laptop.

Correction: the story clock waits for `hero-ready`; module fetching no longer consumes the camera opening. The 1.8-second eligibility cutoff is removed; a 12-second failure timeout preserves the visible static product. Scrolling completes the story only after the entire demo has left above the viewport. Entry script/style URLs carry a content version to avoid mixed cached assets. A separate 15-second watchdog handles a failed enhancement entry without leaving the demo stuck.

Regression: Chrome and WebKit each passed delayed module loading (3 seconds), pause during delayed loading then resume, mobile, reduced motion, failed import, overflow and uncaught-error checks. The delayed-load test scrolls 300px before the module finishes and verifies the actual 3D scene still appears with its opening listening state. Screenshots were visually inspected. These targeted checks do not constitute a new Lighthouse or native Safari run.
