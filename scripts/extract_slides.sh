#!/usr/bin/env bash
# extract_slides.sh — 从视频中提取 PPT 幻灯片并合并为 PDF
#
# 依赖: yt-dlp, ffmpeg, ffprobe, tesseract, img2pdf, python3 + Pillow
#
# 三种使用姿势:
#
#   1) probe (先探针, 抽 1 帧让你确定 PPT 区域)
#      ./extract_slides.sh probe <url_or_file> [--at 300]
#      # 会在 /tmp/slides_probe/probe.jpg 输出一帧, 请自己看下 PPT 在画面里的位置,
#      # 然后决定 crop 参数 W:H:X:Y (ffmpeg 语法: 宽:高:左上角X:左上角Y)
#
#   2) extract (真正抽取)
#      ./extract_slides.sh extract <url_or_file> [选项]
#        -o, --output FILE            输出 PDF 路径 (默认 ~/Downloads/slides_extract/slides.pdf)
#            --crop W:H:X:Y           PPT 区域, 不传就用整帧
#            --max-height N           下载分辨率上限 (默认 1080)
#            --sample-interval N      每 N 秒采样一帧 (默认 1)
#            --keep-cache             结束后不删除视频缓存 (默认删除)
#            --brightness N           slide 帧亮度下限 (默认 110, 深底 PPT 调低到 60)
#            --stddev N               slide 帧 stddev 上限 (默认 108)
#            --dup N                  phash 兜底去重阈值 (默认 3, 越低越激进, 得到更多帧)
#
#   3) clean (手动清理缓存)
#      ./extract_slides.sh clean

set -euo pipefail

CACHE_DIR="$HOME/.cache/slides_extract"
DEFAULT_OUT_DIR="$HOME/Downloads/slides_extract"

# 供 EXIT trap 使用, 由 extract 子命令填充
WORKDIR=""
KEEP_CACHE=0
IS_URL=0

_cleanup() {
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
  if [[ "$KEEP_CACHE" -eq 0 && "$IS_URL" -eq 1 && -d "$CACHE_DIR" ]]; then
    rm -rf "$CACHE_DIR"
    echo "已清理视频缓存: $CACHE_DIR" >&2
  fi
}


# ---------- 依赖检查 ----------
check_deps() {
  local missing=0
  for cmd in yt-dlp ffmpeg ffprobe tesseract img2pdf python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "缺少依赖: $cmd" >&2; missing=1
    fi
  done
  if ! python3 -c "from PIL import Image" >/dev/null 2>&1; then
    echo "缺少 Python 依赖: Pillow (pip3 install Pillow)" >&2; missing=1
  fi
  if [[ $missing -eq 1 ]]; then
    cat <<'EOF' >&2

安装示例 (macOS + Homebrew):
  brew install yt-dlp ffmpeg tesseract img2pdf
  pip3 install Pillow

EOF
    exit 1
  fi
}

# ---------- 视频下载 (带缓存) ----------
# 用法: fetch_video URL MAX_HEIGHT
# echo 出视频文件路径
fetch_video() {
  local url="$1"; local max_h="$2"
  mkdir -p "$CACHE_DIR"
  local key; key=$(printf "%s|%s" "$url" "$max_h" | shasum -a 1 | awk '{print $1}')
  local out="$CACHE_DIR/$key.mp4"
  if [[ ! -f "$out" ]]; then
    echo "==> 下载视频 (max ${max_h}p) ..." >&2
    yt-dlp --no-update --quiet --progress \
           -f "bv*[height<=${max_h}]+ba/b[height<=${max_h}]/b" \
           --merge-output-format mp4 \
           -o "$out" "$url" >&2
  else
    echo "==> 使用缓存视频: $out" >&2
  fi
  echo "$out"
}

# ---------- 子命令: probe ----------
cmd_probe() {
  local input=""; local at=300
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --at)     at="$2"; shift 2 ;;
      -*)       echo "未知参数: $1" >&2; exit 1 ;;
      *)        input="$1"; shift ;;
    esac
  done
  [[ -z "$input" ]] && { echo "用法: probe <url_or_file> [--at 秒数]" >&2; exit 1; }

  local video
  if [[ "$input" =~ ^https?:// ]]; then
    video=$(fetch_video "$input" 1080)
  else
    video="$input"
  fi

  local dur w h
  read -r w h dur < <(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,duration \
    -of default=noprint_wrappers=1:nokey=1 "$video" | paste -sd' ' -)
  echo "视频分辨率: ${w}x${h}, 时长: ${dur}s" >&2

  mkdir -p /tmp/slides_probe
  local out="/tmp/slides_probe/probe.jpg"
  ffmpeg -hide_banner -loglevel error -ss "$at" -i "$video" \
    -frames:v 1 -q:v 2 "$out"
  echo ""
  echo "已生成探针帧: $out"
  echo "请打开这张图确认 PPT 区域, 然后用 --crop W:H:X:Y 传给 extract 子命令"
  echo "  W=PPT 区域宽, H=高, X/Y=PPT 左上角在画面上的坐标 (0 起算)"
  echo "  可以用预览工具/QuickLook 看像素, 也可以直接目测比例乘以视频分辨率"
  echo ""
  command -v open >/dev/null 2>&1 && open "$out" || true
}

# ---------- 子命令: extract ----------
cmd_extract() {
  local input="" output="" crop=""
  local max_height=1080
  local sample_interval=1
  local keep_cache=0
  local min_bright=110
  local max_stddev=108
  local dup_th=3.0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--output)        output="$2"; shift 2 ;;
      --crop)             crop="$2"; shift 2 ;;
      --max-height)       max_height="$2"; shift 2 ;;
      --sample-interval)  sample_interval="$2"; shift 2 ;;
      --keep-cache)       keep_cache=1; shift ;;
      --brightness)       min_bright="$2"; shift 2 ;;
      --stddev)           max_stddev="$2"; shift 2 ;;
      --dup)              dup_th="$2"; shift 2 ;;
      -*)                 echo "未知参数: $1" >&2; exit 1 ;;
      *)                  input="$1"; shift ;;
    esac
  done
  [[ -z "$input" ]] && { echo "用法: extract <url_or_file> [选项]" >&2; exit 1; }

  # 输出路径处理
  if [[ -z "$output" ]]; then
    mkdir -p "$DEFAULT_OUT_DIR"
    local ts; ts=$(python3 -c "import datetime; print(datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))")
    output="$DEFAULT_OUT_DIR/slides-$ts.pdf"
  else
    mkdir -p "$(dirname "$output")"
  fi

  # 获取视频
  local video
  if [[ "$input" =~ ^https?:// ]]; then
    video=$(fetch_video "$input" "$max_height")
  else
    video="$input"
  fi
  echo "视频文件: $video" >&2

  # 工作目录 (用全局变量以便 EXIT trap 里能访问)
  WORKDIR=$(mktemp -d -t slides.XXXXXX)
  KEEP_CACHE=$keep_cache
  IS_URL=0
  [[ "$input" =~ ^https?:// ]] && IS_URL=1
  trap '_cleanup' EXIT

  mkdir -p "$WORKDIR/frames"

  # 抽帧
  local crop_filter=""
  [[ -n "$crop" ]] && crop_filter="crop=$crop," && echo "==> 裁剪区域: $crop" >&2
  echo "==> 每 ${sample_interval}s 采样一帧" >&2
  ffmpeg -hide_banner -loglevel error \
    -i "$video" \
    -vf "${crop_filter}fps=1/${sample_interval}" \
    -vsync vfr -q:v 2 \
    "$WORKDIR/frames/slide_%05d.jpg"

  local frame_count; frame_count=$(ls "$WORKDIR/frames" | wc -l | tr -d ' ')
  echo "抽到 $frame_count 张候选帧" >&2

  # 幻灯片识别 + 去重
  local keep_dir="$WORKDIR/keep"
  mkdir -p "$keep_dir"

  echo "==> OCR 页码 + phash 去重..." >&2
  local kept_count
  kept_count=$(FRAMES_DIR="$WORKDIR/frames" KEEP_DIR="$keep_dir" \
    MIN_BRIGHT="$min_bright" MAX_STDDEV="$max_stddev" DUP_TH="$dup_th" \
    python3 - <<'PY' 2>&1 | tail -1
import os, re, shutil, glob, subprocess, tempfile, sys
from collections import defaultdict
from PIL import Image, ImageOps, ImageStat

frames_dir = os.environ["FRAMES_DIR"]
keep_dir   = os.environ["KEEP_DIR"]
MIN_BRIGHT = float(os.environ["MIN_BRIGHT"])
MAX_STDDEV = float(os.environ["MAX_STDDEV"])
DUP_TH     = float(os.environ["DUP_TH"])

PAGE_RE = re.compile(r"(\d{1,3})\s*/\s*(\d{1,3})")

def phash(im, size=32):
    return list(im.convert("L").resize((size, size), Image.BILINEAR).getdata())

def diff(a, b):
    return sum(abs(x-y) for x, y in zip(a, b)) / len(a)

def looks_like_slide(im):
    s = ImageStat.Stat(im.convert("L"))
    return s.mean[0] >= MIN_BRIGHT and s.stddev[0] <= MAX_STDDEV

def sharpness(im):
    return ImageStat.Stat(im.convert("L")).stddev[0]

def ocr_page(im):
    w, h = im.size
    c = im.crop((int(w*0.75), int(h*0.85), w, h))
    if ImageStat.Stat(c.convert("L")).mean[0] < 128:
        c = ImageOps.invert(c.convert("RGB"))
    c = c.resize((c.width*4, c.height*4), Image.LANCZOS).convert("L")
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        c.save(tmp.name)
        try:
            out = subprocess.run(
                ["tesseract", tmp.name, "-", "--psm", "7",
                 "-c", "tessedit_char_whitelist=0123456789/"],
                capture_output=True, text=True, timeout=5).stdout
        finally:
            os.unlink(tmp.name)
    m = PAGE_RE.search(out)
    if not m: return None
    p, t = int(m.group(1)), int(m.group(2))
    if not (1 <= p <= t and 5 <= t <= 500): return None
    return p

records = []
for idx, f in enumerate(sorted(glob.glob(os.path.join(frames_dir, "*.jpg")))):
    with Image.open(f) as im:
        im.load()
        if not looks_like_slide(im):
            continue
        h = phash(im)
        s = sharpness(im)
        p = ocr_page(im)
    records.append((idx, f, h, s, p))

# 主选: OCR 命中的按 page 分组, 每页从后 40% 帧里取最清晰
by_page = defaultdict(list)
for r in records:
    if r[4] is not None:
        by_page[r[4]].append(r)

primary = []
for page, entries in by_page.items():
    entries.sort(key=lambda e: e[0])
    tail = entries[max(0, int(len(entries)*0.6)):] or entries
    primary.append(max(tail, key=lambda e: e[3]))

# 兜底: OCR 未命中的帧用低阈值 phash 补
kept_hashes = [r[2] for r in primary]
extra = []
for r in records:
    if r[4] is not None: continue
    h = r[2]
    if any(diff(h, kh) < DUP_TH for kh in kept_hashes):
        continue
    extra.append(r)
    kept_hashes.append(h)

selected = sorted(primary + extra, key=lambda r: r[0])
for i, r in enumerate(selected, 1):
    shutil.copy(r[1], os.path.join(keep_dir, f"slide_{i:04d}.jpg"))

print(f"[stats] slide帧={len(records)} OCR命中页数={len(by_page)} 主选={len(primary)} 兜底={len(extra)}", file=sys.stderr)
print(len(selected))
PY
)

  echo "保留 $kept_count 张幻灯片" >&2

  if [[ "$kept_count" -eq 0 ]]; then
    echo "错误: 没识别到 PPT 帧, 试着放宽 --brightness 或调整 --crop" >&2
    exit 3
  fi

  # 合成 PDF
  echo "==> 生成 PDF: $output" >&2
  img2pdf "$keep_dir"/*.jpg -o "$output"
  echo ""
  echo "完成: $output ($kept_count 页)"
}

# ---------- 子命令: clean ----------
cmd_clean() {
  if [[ -d "$CACHE_DIR" ]]; then
    local sz; sz=$(du -sh "$CACHE_DIR" | awk '{print $1}')
    rm -rf "$CACHE_DIR"
    echo "已清理 $CACHE_DIR ($sz)"
  else
    echo "缓存目录不存在, 无需清理"
  fi
  rm -rf /tmp/slides_probe /tmp/slides.* 2>/dev/null || true
}

# ---------- 入口 ----------
check_deps
sub="${1:-}"; shift || true
case "$sub" in
  probe)    cmd_probe   "$@" ;;
  extract)  cmd_extract "$@" ;;
  clean)    cmd_clean   "$@" ;;
  -h|--help|help|"")
    sed -n '2,30p' "$0"
    ;;
  *)
    echo "未知子命令: $sub" >&2
    echo "用法: $0 {probe|extract|clean|help}" >&2
    exit 1
    ;;
esac
