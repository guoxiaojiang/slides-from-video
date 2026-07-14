---
name: video-slides-to-pdf
description: Extract slide/presentation content from a lecture or conference video into a PDF. Downloads the video (YouTube or local), lets the user identify the slide region on-screen, then samples frames, detects real slide frames vs. speaker cutaways, deduplicates via OCR page numbers and perceptual hashing, and outputs a clean PDF. Use whenever the user asks to "extract PPT / slides / deck / presentation from a video" or "turn a talk into a PDF".
---

# video-slides-to-pdf

## What this skill does

Given a video (YouTube URL or local file) of a talk where slides occupy part of the frame, extract the slide content into a PDF.

The pipeline:

1. **Download** (or reuse local file). Cached under `~/.cache/slides_extract/` and deleted at the end unless `--keep-cache`.
2. **Probe** — grab one representative frame so the user can identify where slides live in the frame (talks often have a speaker cam, sponsor logos, etc. beside/around the slides).
3. **Crop + sample** — apply the crop and sample one frame every N seconds.
4. **Classify** — brightness + stddev heuristic drops speaker/cutaway frames.
5. **Deduplicate** — two-path:
   - OCR the bottom-right corner for `N/M` page numbers via `tesseract` (with auto-invert for dark slides); one frame per page number, pick the sharpest tail frame so post-transition renders are captured.
   - For frames where OCR fails, fall back to low-threshold perceptual hash (`phash`) diff against already-kept frames.
6. **Merge** — `img2pdf` with no re-encoding (best fidelity, smallest size).

Output defaults to `~/Downloads/slides_extract/slides-YYYYMMDD-HHMMSS.pdf`.

## Dependencies

Required binaries: `yt-dlp`, `ffmpeg`, `ffprobe`, `tesseract`, `img2pdf`, `python3` with `Pillow`.

The script auto-checks and prints install instructions if anything is missing:

```
brew install yt-dlp ffmpeg tesseract img2pdf
pip3 install Pillow
```

## Usage

The script lives at `scripts/extract_slides.sh` inside this skill. It has three subcommands.

### Step 1 — probe (mandatory unless slides fill the whole frame)

```
scripts/extract_slides.sh probe <url_or_file> [--at 300]
```

Grabs one frame at `--at` seconds (default 300, i.e. 5 min in — pick a time when slides are known to be showing) into `/tmp/slides_probe/probe.jpg` and opens it with the OS default viewer. Also prints the video resolution.

**Show the probe image to the user.** Then ask them (or estimate yourself) what the slide region is in `W:H:X:Y` (ffmpeg crop syntax: width, height, top-left X, top-left Y in pixels). You can use the Read tool on the probe image to inspect it directly.

Common layouts:
- Slides fill the right 3/4 of a 1920×1080 frame with a speaker-cam sidebar on the left → `crop=1440:1080:480:0` (approx)
- Slides centered with black bars → `crop=1600:900:160:90`
- Slides fill the whole frame → skip `--crop` entirely

### Step 2 — extract

```
scripts/extract_slides.sh extract <url_or_file> --crop W:H:X:Y [options]
```

Options:

| flag | default | meaning |
|---|---|---|
| `-o FILE` | `~/Downloads/slides_extract/slides-<ts>.pdf` | output path |
| `--crop W:H:X:Y` | (none, use full frame) | slide region |
| `--max-height N` | `1080` | download resolution cap; higher = sharper text but bigger download |
| `--sample-interval N` | `1` | seconds per sampled frame; 0.5 for animation-heavy decks |
| `--keep-cache` | off | keep the video cache after finishing |
| `--brightness N` | `110` | min mean luma to be considered a slide (drop to `60` for dark-themed decks) |
| `--stddev N` | `108` | max luma stddev to be considered a slide |
| `--dup N` | `3.0` | phash difference below which two frames are considered duplicates; lower = more slides kept |

### Step 3 — clean (only if you used `--keep-cache` or the script was interrupted)

```
scripts/extract_slides.sh clean
```

## When to invoke this skill

Any of:
- "Extract the slides / PPT / deck / presentation from this video"
- "Turn this talk into a PDF"
- "I want the slide deck from https://youtube.com/..."
- "Screenshot every slide in this video and put them into a PDF"

Do NOT invoke for:
- Downloading videos (use `yt-dlp` directly)
- Transcribing audio (this doesn't touch audio)
- Screen-recording a live app (this is for pre-recorded videos)

## Recommended workflow when invoked

1. Confirm the input (URL or path). If it's a URL, mention roughly how big the download is going to be.
2. Run `probe` at a time when slides are likely on-screen (default 300s is fine for most 15-30min talks; for very short videos use `--at` = duration/2).
3. Read the probe image with the Read tool. Describe what you see to the user and propose a `--crop` value. Ask for confirmation only if the layout is ambiguous.
4. Run `extract` with the confirmed crop.
5. Report the output path and page count. Suggest they open it. If the deck is known to be dark-themed and few slides were extracted, offer to re-run with `--brightness 60`.
6. If they say the coverage is too low: try lowering `--dup` (e.g. 2.0, 1.5) and/or `--sample-interval 0.5`. Coverage above ~70% of the true slide count is often the ceiling because talks rarely show every slide on-screen (director cuts to speaker/audience).
7. If they say there's too many near-duplicates (animation steps of the same slide bloating the deck): raise `--dup` (5.0, 8.0).

## Expectations to set with the user

- **100% coverage is often impossible.** Talks routinely cut away from slides to the speaker or audience. Slides never on-screen cannot be recovered from the video.
- **1080p is usually the sweet spot.** 4K is rarely available on conference recordings and doesn't help slide text much beyond 1080p.
- **First run downloads the video** (can be 50-300 MB depending on length and resolution). Subsequent runs on the same URL+resolution reuse the cache.
- **The video cache is deleted at the end** unless `--keep-cache`. If iterating on crop/thresholds, pass `--keep-cache` on all but the final run to avoid re-downloading.
