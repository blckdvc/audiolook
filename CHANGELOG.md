# Changelog

All notable changes to **audiolook**.

## 1.1.2 — 2026-10-24
- **Much sharper waveform** — redrawn as a smooth, anti-aliased **min/max envelope**
  at up to ~1 point per sample (capped), so it stays crisp when zoomed.
- **Space bar** toggles play/pause once the player has keyboard focus (click the
  window). The player follows the Finder **without stealing focus**, so arrow-key
  browsing in the Finder keeps working.
- Removed the inoperative **⌘Q** shortcut shown next to "Quit" in the menu.

## 1.1.0 — 2026-10-24
- **Waveform zoom** — mouse wheel or trackpad pinch; **pan** with a two-finger
  horizontal scroll or **Shift + wheel** (zoom and pan around the cursor).
- **Higher-resolution waveform** — detail scales with the file length, so zooming in
  stays sharp instead of blocky.
- **Export by dragging the waveform** straight into any DAW (or the Finder). The
  exported WAV (24-bit) carries the applied **pitch and tempo** (unless Bypass is
  on). The separate drag chip and the **Render** button were removed.
- **Automatic A/B-region export** — when the loop isn't the whole file, only the
  segment between the A and B markers is exported (no checkbox); the bounds follow
  the markers shown on the waveform.
- **More precise BPM detection** — sub-lag (parabolic) interpolation removes the
  ~1 BPM rounding bias.
- **Two-column layout** (Volume / Pitch · Tempo / Grid) with a cleaner footer.
- **Window size and position remembered** between launches.
- **Tempo resets to each sample's own detected BPM** (no longer carried over).
- **Space bar** toggles play / pause.
- **Attack preserved** at the loop start (the first kick stays punchy).
- **About** window now shows a clickable **"buy me tokens"** badge (→ PayPal).
- Interface **follows the system language** (English / French).
- Wider A/B handle grab zone.

## 1.0 — 2026-10
- Renamed **LoopLook → audiolook**, new Finder-inspired icon.
- **BPM** detection and tempo matching (replacing the old "%").
- **Magnetic grid** (1/16, 1/8, 1/4, bar) and a **move bar** to slide the A/B region.
- **Click-free** playback (crossfades); playback stops when the window is closed.
- Adjustable window transparency, hidden title bar, keyboard-editable values.
- Export: drag-and-drop the processed WAV (24-bit) into any DAW.

## 0.1
- Initial release (as **LoopLook**): floating / menu-bar audio loop player with
  A/B looping and high-quality time-stretch / transposition (Signalsmith Stretch).

---

## Support the project
Free and open-source 🙂 — if you feel like it, buy me a few tokens:

[![Buy me tokens](https://raw.githubusercontent.com/blckdvc/audiolook/main/docs/buy-me-tokens.png)](https://paypal.me/lbenh)
