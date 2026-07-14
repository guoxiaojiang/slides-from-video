# slides-from-video

Extract slide/presentation content from a lecture or conference video into a clean PDF.

Give it a YouTube URL (or local video file), tell it where the slides live in the frame, and it produces a de-duplicated PDF of the deck. Designed for talks where slides only occupy part of the frame — with speaker cams, sponsor logos, or crop bars around them.

Also packaged as a [Claude Code](https://claude.com/claude-code) skill so you can just say "extract the slides from this video" in Claude and it does the right thing.

---

## Features

- **Cropping** — target only the slide region; ignores speaker cam / branding.
- **Real slide detection** — brightness/stddev heuristic drops director cuts to speaker or audience shots.
- **OCR-based page dedup** — reads bottom-right `N/M` page indicators via Tesseract, auto-inverts on dark themes.
- **Perceptual-hash fallback** — recovers frames where OCR fails (deep-color slides, unusual page-number fonts).
- **Sharpest-frame selection** — for each detected page, keeps the tail frame with best focus, so post-transition renders are captured.
- **No re-encoding PDF** — uses `img2pdf` for smallest file size and pixel-perfect output.
- **Video cache** — first run downloads, later runs on the same URL reuse the cache. Cleaned automatically at the end unless `--keep-cache`.

## Dependencies

Required binaries:

```
yt-dlp   ffmpeg   ffprobe   tesseract   img2pdf   python3
```

Python: [Pillow](https://pillow.readthedocs.io/).

Install on macOS:

```bash
brew install yt-dlp ffmpeg tesseract img2pdf
pip3 install Pillow
```

Install on Debian/Ubuntu:

```bash
sudo apt install ffmpeg tesseract-ocr img2pdf python3-pil
pipx install yt-dlp   # apt version is often too old for YouTube
```

## Quickstart

```bash
# 1) Grab a sample frame at t=5min to see the slide region
scripts/extract_slides.sh probe "https://www.youtube.com/watch?v=XXXXXX" --at 300

# 2) Extract, passing the slide region as ffmpeg crop (W:H:X:Y)
scripts/extract_slides.sh extract "https://www.youtube.com/watch?v=XXXXXX" \
  --crop 1440:795:447:37 \
  -o ~/Downloads/deck.pdf
```

The probe frame is written to `/tmp/slides_probe/probe.jpg` and opened with the OS default viewer. Look at where the slides live in that frame, then translate that into the `--crop W:H:X:Y` (ffmpeg syntax: `width:height:left:top` in pixels of the source video, at whatever `--max-height` you're using — default 1080p).

## Commands

### `probe`

```
scripts/extract_slides.sh probe <url_or_file> [--at 300]
```

Downloads the video (or uses the given local file), extracts one frame at `--at` seconds (default 300 = 5 min in), and opens it. Pick a timestamp when slides are known to be on-screen.

### `extract`

```
scripts/extract_slides.sh extract <url_or_file> [options]
```

| flag                | default                                       | meaning |
|---------------------|-----------------------------------------------|---|
| `-o FILE`           | `~/Downloads/slides_extract/slides-<ts>.pdf`  | Output path. Parent dir is created if missing. |
| `--crop W:H:X:Y`    | *(none — use full frame)*                     | Slide region in ffmpeg `crop` syntax. |
| `--max-height N`    | `1080`                                        | Cap the download resolution. Higher = crisper slide text, bigger download. |
| `--sample-interval N` | `1`                                         | Seconds per sampled frame. Drop to `0.5` for animation-heavy decks. |
| `--brightness N`    | `110`                                         | Minimum mean luma to classify a frame as a slide. Lower to `~60` for dark-themed decks. |
| `--stddev N`        | `108`                                         | Maximum luma stddev for a slide frame. |
| `--dup N`           | `3.0`                                         | Perceptual-hash difference below which two frames are treated as duplicates. Lower → keep more slides (may include animation steps). |
| `--keep-cache`      | off                                           | Do not delete the video cache after finishing. Useful when iterating on `--crop`. |

### `clean`

```
scripts/extract_slides.sh clean
```

Removes `~/.cache/slides_extract/` and any stray `/tmp/slides.*` working directories. Use this if a previous run was interrupted or you used `--keep-cache`.

## Tuning

If you get **too few slides**:

1. Lower `--dup` (try `2.0`, then `1.5`).
2. Lower `--sample-interval` to `0.5`.
3. If the deck is dark-themed: lower `--brightness` to `60` and raise `--stddev` to `130`.

If you get **too many near-duplicates** (animation steps blowing up the deck):

1. Raise `--dup` (try `5.0`, then `8.0`).
2. Raise `--sample-interval` to `2`.

If the deck is **not full-coverage** (say only 28/40 slides come out): that's usually the ceiling. Talks routinely cut to speaker or audience; slides that never appear on-screen cannot be recovered from the video.

## How it works

```
   video URL / file
        │
        ▼
   yt-dlp (cache under ~/.cache/slides_extract/)
        │
        ▼
   ffmpeg crop → sample @ 1 fps → ~1000-2000 candidate JPEGs
        │
        ▼
   Python + Pillow:
     • drop frames outside (brightness, stddev) window          → cutaway filter
     • per-frame Tesseract OCR on the bottom-right N/M          → page groups
     • pick sharpest tail frame per page                         → primary picks
     • for OCR-miss frames, phash-diff against picked frames    → fallback picks
        │
        ▼
   img2pdf (no re-encoding)
        │
        ▼
   PDF output
```

## Use as a Claude Code skill

If you install this repo under `~/.claude/skills/video-slides-to-pdf/` (the top-level `SKILL.md` in this repo describes the trigger phrases), Claude Code will invoke it automatically when you say things like:

- "Extract the slides from this video: <URL>"
- "Turn this talk into a PDF."
- "Screenshot every slide in this deck."

Claude reads the probe image itself, proposes a `--crop`, and runs `extract` — no need to hand-copy pixel coordinates.

## Limitations

- Only tested on macOS (Darwin) with Homebrew. Linux should work; Windows via WSL should work; native Windows shell is not supported.
- The OCR page-number pass assumes indicators like `12/40` in the bottom-right. Slides with page numbers elsewhere, or without page numbers at all, fall back to phash-only and may over- or under-count.
- Perceptual hashing can't distinguish rapid animation steps of the same slide from truly different slides that happen to look similar. Tune `--dup` as needed.
- If the talk overlays the speaker cam directly on top of the slides (picture-in-picture), the slide region will always contain a moving human and no crop can fix it.

## License

MIT.
