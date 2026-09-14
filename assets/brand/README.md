# LiveCopilot identity

The icon depicts an audio conversation becoming a written cue: a rose-pink rear conversation card, a raised blue front card, and a waveform beside “LIVE” lettering with a softly glowing pink recording dot. The white porcelain base and shaded card edges give the macOS icon a restrained physical appearance.

- `LiveCopilot.svg`: editable 1024 × 1024 vector master, including gradients and vector shadow filters. It contains no embedded bitmap, external image, font or linked resource.
- `LiveCopilot-mark.svg`: transparent single-colour vector mark for smaller or flat treatments.
- `LiveCopilot-preview.png`: transparent 512 × 512 preview derived from the master.
- `../../StealthApp/Resources/AppIcon.icns`: all standard macOS icon representations, generated from the master; included in the application bundle.

Palette: porcelain `#F2F5FA`, silver `#AEB9CC`, rose pink `#F5A4CA`, blue `#197CF0`, cobalt `#194ABD`, white `#FFFFFF`. The “LIVE” lettering uses Avenir Next Heavy Italic converted to vector outlines; rendering requires no installed font. The recording dot uses a radial glow and a small specular highlight. Keep the two cards and waveform legible at Dock sizes; reserve softer bevels and shadows for larger sizes.

To regenerate PNG representations and ICNS on macOS, run Node.js with the `sharp` package available:

```bash
node StealthApp/scripts/render-icon.cjs
```

If `sharp` is installed outside the module search path, set `LIVECOPILOT_SHARP_PATH` to its package directory. Rendering outputs in `dist/` are disposable. Blender is not a dependency: the vector source supplies the gradients, highlights and soft shadows directly.

These original LiveCopilot artwork files are provided under this repository's MIT license.
