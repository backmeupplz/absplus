# Promo video

A 40-second, 1920×1080 60 fps promo for ABS+, built from code so it can be re-rendered whenever the app changes.

- `index.html` is the video: ten scenes, each a function of time. Open it in a browser to preview (space plays, ←/→ seek, shift for 0.1 s, `index.html?t=12.5` opens at a time).
- `music.py` synthesizes the soundtrack into `out/music.wav` (120 BPM, so one bar is 2 s; every scene starts on a bar).
- `render.mjs` renders every frame in headless Chromium and muxes the music: `out/absplus-promo.mp4` (full quality, for uploading elsewhere), plus the copy on absplus.app, `docs/video/absplus-promo.mp4` and its poster `docs/img/promo-poster.webp`.

## Render

Needs Node 22+, Python 3 with numpy and scipy, Chromium and ffmpeg.

```sh
node promo/render.mjs              # full video, runs music.py first (~10 min on a 20-thread laptop)
node promo/render.mjs 12.5 30      # just these frames, to out/stills/
python3 promo/music.py             # just the music, e.g. for the browser preview
```

`CHROME=/path/to/chrome` picks another browser, `JOBS=4` changes the number of parallel renderers.

## Updating it

- **Screenshots** are read straight from `play/screenshots` (Android) and `appstore/screenshots` (iPhone), so refreshing the store screenshots and re-rendering updates the video. Which screen goes where is in the `data-shot` attributes and the `LIBRARY` list (scene 7) in `index.html`.
- **Text** lives in the scene markup in `index.html`, one commented block per scene.
- **Timing**: scenes and their transitions are at fixed times that match the music. To add or drop a scene, shift the later scenes in `index.html` (`scene(...)` windows, `transitions()`) and the bars in `music.py` (`CHORDS`, `GROOVE`, `DROPS`, `WHOOSHES`, ...) together.
- **Facts from the demo server** are written in: Alice in Wonderland's 2:58:51 and 12 files, the 0:52:14 / 1:42:07 positions, `img/alice.jpg` (its cover), and "~4 MB" (the APK size).

The font is Bricolage Grotesque (SIL Open Font License, `fonts/OFL.txt`).
