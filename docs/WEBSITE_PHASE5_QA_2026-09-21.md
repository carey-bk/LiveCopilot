# Phase 5 verification — 2026-09-21

## Scope
- Replaced the production Three.js Hero with a stationary local transparent PNG shell.
- Preserved the shared native-style HTML product component and finite software sequence.
- Desktop uses a 60/40 split; the laptop extends outside the left edge. Mobile places copy first.
- Four workflow titles and visual blocks share a desktop baseline, with a wider Answer column.
- Reduced motion shows the complete product and title immediately.

## Organization and recovery
- Editable source: `site/`; generated disposable output: `_site/`.
- Original copy documents moved from `Intro page/` to `site/reference/`.
- Retired production 3D code: `site/experiments/phase4-3d/`, excluded from builds.
- Local pre-edit backup: `dist/website-backups/phase5-resume-source-20260921.tar.gz`.
- Adjacent Phase 4 prototype backed up as `dist/website-backups/phase4-prototype-source-20260921.tar.gz`.
- Prototype assets with local-only permission remain local; they are not published.
- The adjacent Git worktree is retained for recovery. It is not an active website input.

## Local checks
- Python bilingual build succeeded. JS syntax and Git whitespace checks passed.
- Chromium and WebKit: Chinese and English, widths 375, 390, 768, 1024, 1440, 1920.
- All 24 combinations: no horizontal overflow, no cropped product panel, reduced-motion final state, no canvas, no JavaScript errors.
- Desktop workflow headings and card tops aligned in all checked desktop widths.
- Both engines: title typing completion, pause/resume, final answer, source expansion, dark-to-light navbar checked.
- Production output contains no cinematic runtime, Three.js vendor, or archived prototype files.
- Visual screenshots reviewed for desktop Hero, mobile Hero and workflow.

The animation is a browser-only example. No microphone, provider, model or real product service is exercised.
