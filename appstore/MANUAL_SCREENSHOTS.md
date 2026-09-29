# Manual screenshots and framing setup

## Framing

`scripts/release.sh frame` runs `scripts/frame_screenshots.sh` (ImageMagick,
`brew install imagemagick`). HomeClaw's Mac App Store shots are app windows on
a gradient with a tagline, not device bezels, so there is no Framefile or
title.strings:

- the gradient, window width, corner radius, and tagline font/size/position
  are constants at the top of the script
- taglines are keyed by filename stem in `default_tagline()`; override them
  for one run with `HC_TAGLINES_FILE=<tsv>` (`basename<TAB>tagline`)
- a raw window grab gets rounded corners and a drop shadow; a capture that
  already has a dark CleanShot frame is detected by its corners and keyed out
  instead, so it isn't framed twice

Input is `appstore/screenshots/en-US/` (2880 × 1800), output
`appstore/framed/en-US/` under the same names. Both are committed.

## Shots the UI tests can't produce

`HomeClawUITests` captures two of the five screenshots:

| Name | Source |
|---|---|
| `01_Onboarding` | automated |
| `02_Settings_Home` | automated |
| `03_TUI` | **manual** |
| `04_CLI_List` | **manual** |
| `05_CLI_Toggle` | **manual** |

The terminal shots show `homeclaw-cli` in a terminal, which is outside the app
entirely. Capture them with the app in demo mode (`HOMECLAW_DEMO=1`) so no
real home shows, as 2880 × 1800 window grabs (CleanShot's "Background &
shadow" mode is fine; the framer detects it). `03_TUI` needs a source build
(`swift run homeclaw-cli ui`): the App Store CLI is sandboxed, and the TUI is
compiled out of it.

The menu-bar dropdown is `NSMenu` (AppKit), so neither the UI tests nor
SwiftUI's `ImageRenderer` can capture it. If it's wanted, grab it with
`screencapture -x` from the running demo-mode app.

Drop the PNGs into `appstore/screenshots/en-US/` under those names, then run
`scripts/release.sh frame`. `scripts/screenshots.sh` overwrites only the
automated shots, so the manual ones stay put. `upload-screenshots` refuses to
replace the App Store set while any raw shot lacks a framed one.
