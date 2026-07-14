# slides-from-video

[English](./README.md) | 中文

从演讲、会议视频里提取 PPT 内容，合成一份干净的 PDF。

给它一个 YouTube 链接（或本地视频文件），告诉它 PPT 在画面里的位置，它就会输出一份去重后的幻灯片 PDF。特别适合那种**画面里同时有讲者摄像头、赞助商 Logo、边框**，PPT 只占部分区域的会议录播。

同时也是一个 [Claude Code](https://claude.com/claude-code) skill —— 装到 `~/.claude/skills/` 下之后，直接对 Claude 说"帮我从这个视频提取 PPT"就能触发。

---

## 特性

- **区域裁剪** —— 只针对 PPT 区域抽帧，忽略讲者摄像头和主办方 Logo。
- **真幻灯片识别** —— 用亮度 + 标准差过滤掉导播切给讲者/观众的镜头。
- **OCR 页码去重** —— 用 Tesseract 读取右下角 `N/M` 页码，深色底自动反相后再识别。
- **感知哈希兜底** —— OCR 识别失败的帧（深底、页码字体特殊等）用 phash 补齐。
- **同页选清晰帧** —— 每个页码只保留最清晰的一帧，避免抓到刚切换过来还没渲染完的模糊画面。
- **无损 PDF** —— 用 `img2pdf`，不重编码，文件小、画质好。
- **视频缓存** —— 相同 URL 相同分辨率会复用缓存；跑完自动清理，除非加 `--keep-cache`。

## 依赖

必需命令行工具：

```
yt-dlp   ffmpeg   ffprobe   tesseract   img2pdf   python3
```

Python：[Pillow](https://pillow.readthedocs.io/)。

macOS 安装：

```bash
brew install yt-dlp ffmpeg tesseract img2pdf
pip3 install Pillow
```

Debian/Ubuntu 安装：

```bash
sudo apt install ffmpeg tesseract-ocr img2pdf python3-pil
pipx install yt-dlp   # apt 版本对 YouTube 常常不够新
```

## 快速开始

```bash
# 1) 先抽一帧看 PPT 在画面里的位置 (t=5min)
scripts/extract_slides.sh probe "https://www.youtube.com/watch?v=XXXXXX" --at 300

# 2) 传入裁剪区域, 提取全部幻灯片
scripts/extract_slides.sh extract "https://www.youtube.com/watch?v=XXXXXX" \
  --crop 1440:795:447:37 \
  -o ~/Downloads/deck.pdf
```

`probe` 会把探针帧写到 `/tmp/slides_probe/probe.jpg` 并用系统默认应用打开。你看一下画面里 PPT 具体在哪个矩形，把这个矩形换算成 `--crop W:H:X:Y` 传给 `extract` —— 语法是 ffmpeg 的 `crop` 参数：`宽:高:左上角X:左上角Y`，单位是源视频的像素（分辨率取决于 `--max-height`，默认 1080）。

## 子命令

### `probe`

```
scripts/extract_slides.sh probe <url_or_file> [--at 300]
```

下载视频（或使用本地文件），在 `--at` 秒处抽一帧（默认 300 = 5 分钟），自动打开。挑一个大概率显示 PPT 的时间点。

### `extract`

```
scripts/extract_slides.sh extract <url_or_file> [选项]
```

| 参数                | 默认                                          | 含义 |
|---------------------|-----------------------------------------------|---|
| `-o FILE`           | `~/Downloads/slides_extract/slides-<ts>.pdf`  | 输出 PDF 路径，父目录会自动创建 |
| `--crop W:H:X:Y`    | *(不传，用整帧)*                              | PPT 区域，ffmpeg `crop` 语法 |
| `--max-height N`    | `1080`                                        | 下载分辨率上限，越高文字越清晰、下载越大 |
| `--sample-interval N` | `1`                                         | 每 N 秒采样一帧；动画多的 PPT 可以调到 `0.5` |
| `--brightness N`    | `110`                                         | 判定为 PPT 帧的平均亮度下限。**深色主题 PPT** 调低到 `~60` |
| `--stddev N`        | `108`                                         | 判定为 PPT 帧的亮度标准差上限 |
| `--dup N`           | `3.0`                                         | 感知哈希去重阈值；调低会保留更多帧（可能包含动画中间步骤） |
| `--keep-cache`      | 关闭                                          | 完成后**不**删除视频缓存，便于反复调 crop |

### `clean`

```
scripts/extract_slides.sh clean
```

删除 `~/.cache/slides_extract/` 和残留的 `/tmp/slides.*` 工作目录。上一次运行被打断或用了 `--keep-cache` 时可以手动清理。

## 调参指南

**抽得太少**：

1. 调低 `--dup`（试 `2.0`，再试 `1.5`）
2. 调低 `--sample-interval` 到 `0.5`
3. 深色主题 PPT：`--brightness 60 --stddev 130`

**同一张 PPT 重复太多**（动画每一步都被抽了）：

1. 调高 `--dup`（试 `5.0`，再试 `8.0`）
2. 调高 `--sample-interval` 到 `2`

**覆盖率上不去**：40 张 PPT 只抽出 28 张通常已是上限。导播频繁切给讲者/观众，那些没在画面上出现过的幻灯片，从视频里就是抽不出来的。

## 工作原理

```
   视频 URL / 文件
        │
        ▼
   yt-dlp (缓存到 ~/.cache/slides_extract/)
        │
        ▼
   ffmpeg 裁剪 → 每秒采样一帧 → ~1000-2000 张候选 JPEG
        │
        ▼
   Python + Pillow:
     · 用 (亮度, 标准差) 过滤讲者/过渡镜头
     · 每帧右下角调 Tesseract 识别 N/M 页码
     · 同一页取尾部最清晰一帧 (主选)
     · OCR 失败的帧用 phash 与已选帧对比, 差异大就补 (兜底)
        │
        ▼
   img2pdf (无损)
        │
        ▼
   PDF
```

## 作为 Claude Code skill 使用

把本仓库放到 `~/.claude/skills/video-slides-to-pdf/`（仓库根目录的 `SKILL.md` 定义了触发短语），Claude Code 就会在你说下面这些话时自动调用：

- "帮我从这个视频提取 PPT: <URL>"
- "把这个演讲变成 PDF"
- "截取这个视频里的每一张幻灯片"

Claude 会自己读取探针帧、推断 `--crop`、然后跑 `extract` —— 你不需要手动量像素。

## 局限

- 只在 macOS (Darwin) + Homebrew 环境下测过。Linux 应该能跑；Windows 建议走 WSL；原生 Windows shell 不支持。
- OCR 页码假设为右下角的 `N/M` 形式。如果页码在别处或者根本没有页码，会退化到只用 phash，可能多截或少截。
- 感知哈希无法区分"同一张 PPT 的动画中间步骤"和"两张长得像的不同 PPT"。请酌情调 `--dup`。
- 讲者摄像头如果**画中画覆盖在 PPT 上**（不是在旁边），裁剪也解决不了 —— PPT 区域里始终有个移动的人。

## 许可证

MIT
