# T1.8 AetherEngine 集成验证（播放引擎 Spike）

> **验证环境**：macOS 27.0（Build 26A425）· arm64 · Swift 6.4 · Xcode SDK macOS 27.0
> **被测库**：AetherEngine `7.44.0`（exact pin，已预解析在 `.spike/engine/.build/`）
> **spike 工程**：`.spike/engine/`（SPM，已被 `.gitignore` 忽略）
> **执行日期**：2026-10-21

## 总览

| # | 验证项 | 结论 | 状态 |
|---|--------|------|------|
| 1 | 真实 MKV 文件播放（含 seek 精度） | **通过**。起播 92–151ms，seek 误差 0.000s | ✅ 成功 |
| 2 | 外挂 ASS 字幕 | **部分通过**。`\pos`/`\an`/颜色/粗体正确；`\fad` 被丢弃；样式级 Alignment 不映射 | ⚠️ 有缺口 |
| 3 | 音轨切换 | **未达预期**。切换会触发 `.loading` 重建，且 `clock.sourceTime` 瞬时归零 ~86ms | ⚠️ 需产品决策 |
| 4 | PiP 在 macOS 可用性 | **可用**。`isPictureInPictureSupported() == true`，`isPossible` 0.2s 后转 true | ✅ 成功 |
| 5 | AirPlay 在 macOS 可用性 | **部分可用**。`allowsExternalPlayback == true`，`AVRoutePickerView` 可构造；实际投送无法验证 | ⚠️ 部分无法验证 |
| 6 | Swift 6 严格并发 | **通过**。Prism 侧 0 warning；AetherEngine 内部因 `-suppress-warnings` 无法判断 | ✅ 成功（有限定） |
| 7 | 体积实测 | **已实测**。arm64 框架 10.65 MB + 可执行 10.66 MB；压缩后 ~8.1 MB | ✅ 成功 |

### 三条最需要注意的结论

1. **音轨切换不是无缝的**（项 3）。引擎会走一次完整的 `.loading`，并且 `clock.sourceTime` 会在切换瞬间**归零约 86ms** 再弹回。UI 必须处理这个归零，否则进度条会闪一下 0。
2. **`\fad` 不被解析**（项 2）。ASS 的淡入淡出被直接丢弃，`\pos`/`\an`/颜色/粗体则正确解析。这是"富文本部分支持"，不是"完全支持"。
3. **`setSoftwareSubtitleDelay` 不影响 `$subtitleCues`**（项 2）。它只作用于 software PiP 合成；Prism 若在窗口内绘制字幕，必须自己用 `clock.sourceTime` 施加偏移。

---

## 1. 真实文件播放（最重要）

### 结论

**通过。** MKV（AVPlayer 原生不支持的容器）经 demuxer + 本地 HLS-fMP4 loopback 路径正常播放，seek 落点精确到 0.000s 误差。

### 素材

用 `curl`（纯 HTTPS，不碰 git/钥匙串）下载：

```bash
curl -sSL --max-time 120 -o bbb_720_10s_1MB.mkv \
  "https://test-videos.co.uk/vids/bigbuckbunny/mkv/720/Big_Buck_Bunny_720_10s_1MB.mkv"
# http=200 size=939281
```

`ffprobe` 确认：

```
stream|index=0|codec_name=h264|codec_type=video
format|duration=10.000000
```

> **注意**：这个样本**没有任何音轨**（见项 3 的处理）。

### 渲染层

命令行程式没有窗口。按任务要求先尝试直接 load，同时预先 `bind` 一个离屏 `AetherPlayerView`：

```swift
let view = AetherPlayerView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
player.bind(view: view)   // window=nil，不需要上屏
```

**结果：`load` 没有因为缺少渲染层而失败**，一次成功。不需要重试路径。

### 原始命令

```bash
cd .spike/engine && source /Users/fuunylmz/Prism/scripts/env.sh && \
  .build/out/Products/Debug/PlaybackSpike
```

### 原始输出

```
=== PlaybackSpike (T1.8 项 1 / 项 3) ===
macOS: Version 27.0 (Build 26A425)
媒体: /Users/fuunylmz/Prism/.spike/engine/media/bbb_720_10s_1MB.mkv
文件存在: true
AetherEngine 构造成功, maxSupportedRate=2.0
已 bind 离屏 AetherPlayerView 1280x720 (window=nil)

[1] load(url:) ...
load() 返回耗时: 0.087s, probe=有
  duration=10.000s video=h264 1280x720 format=sdr
  duration(engine)=0.000 videoRoute=loopback backend=native
  duration 变非零耗时 0.061s -> 10.000
  errorInfo=nil

[1] play() ...
起播耗时 (play() -> .playing): 0.000s
时钟推进: t0=0.000 t+1s=0.900 t+3s=2.900  (Δ1s=0.900 Δ3s=2.900)

[1] seek(to: 5) 前 sourceTime=2.900, canSeek=true
A) 播放中 seek(to: 5)
   seek 返回耗时: 0.033s
   返回瞬间 sourceTime=5.000 误差=0.000s
   再等 0.5s 后 sourceTime=5.501 (期间时钟继续推进，故不是误差)
   bufferedPosition=10.000
B) 暂停中 seek(to: 2.5)
   暂停时 sourceTime=5.511 -> seek 耗时 0.007s
   seek 后 sourceTime=2.500, 目标=2.500, 误差=0.000s
seek 后继续播放 1s -> sourceTime=3.800 state=playing

--- 项 1 state 完整迁移序列 ---
  t+ 0.000s  idle
  t+ 0.002s  loading
  t+ 0.151s  playing
  t+ 3.161s  seeking
  t+ 3.194s  playing
  t+ 3.704s  paused
  t+ 4.025s  seeking
  t+ 4.032s  paused
  t+ 4.352s  playing

stop() 后 state=idle
```

### 关键数据

| 指标 | 值 |
|------|-----|
| `load()` 耗时 | 0.087s（另一次运行 0.151s） |
| `idle → loading` | t+0.002s |
| `loading → playing` | t+0.092 ~ 0.151s（**即起播时间**） |
| 路由 | `videoRoute=loopback`，`playbackBackend=native` |
| seek 耗时 | 0.033s（播放中）/ 0.007s（暂停中） |
| **seek 落点误差** | **0.000s**（5.000 目标命中 5.000；2.500 命中 2.500） |
| 时钟推进 | 3s 墙钟推进 2.900s（~3% 落后，属正常 AVPlayer 时钟特性） |

### 附带发现（对 UI 有影响）

- `player.duration` 在 `load()` 返回的**那一刻仍是 0**，0.061s 后才变成 10.000。若 UI 在 `load` 返回后立刻渲染总时长，会短暂显示 `00:00`。建议观察 `$duration` 而非在 load 后直接读。
- 播放到结尾后 `state` 变为 `.ended`（终端态），不是 `.idle`。

---

## 2. 外挂 ASS 字幕

### 结论

**部分通过 —— ASS 富文本是"部分解析"，不是完整解析。**

| 特性 | 是否解析 | 证据 |
|------|---------|------|
| `\pos(x,y)` 定位 | ✅ 正确 | `\pos(960,120)` → `(0.5000, 0.1111)` = 960/1920, 120/1080 |
| `\an` 对齐 | ✅ 正确 | `\an7` → `alignment=7` |
| 行内颜色 `\c&H0000FF&` | ✅ 正确 | → `#FF0000`（BGR→RGB 转换正确） |
| 行内 `\b1` 粗体 | ✅ 正确 | → `bold=true` |
| **`\fad(300,300)` 淡入淡出** | ❌ **被丢弃** | 标签不泄漏进文本，但也**没有产生任何淡入淡出信息** |
| **样式级 `Alignment=8`** | ❌ **不映射** | 只有行内 `\an`/`\pos` 进 `placement`；Style 行里的 Alignment 不生效 |
| 描边/阴影/字体（Style 行） | ❌ 不暴露 | `SubtitleCue` 无对应字段 |

### 素材

手写 `.spike/engine/media/spike-test.ass`，`PlayResX/Y = 1920x1080`，含两个 Style 和 4 条 Dialogue，分别覆盖：

```ass
Dialogue: 0,0:00:00.20,0:00:02.00,Default,,0,0,0,,{\fad(300,300)}Cue A: fade only, no other overrides.
Dialogue: 0,0:00:02.10,0:00:04.00,TopRed,,0,0,0,,{\pos(960,120)\fad(200,200)}Cue B: top-positioned red style.
Dialogue: 0,0:00:04.10,0:00:06.00,Default,,0,0,0,,Cue C: inline {\c&H0000FF&}red{\c} and {\b1}bold{\b0} runs.
Dialogue: 0,0:00:06.10,0:00:08.00,Default,,0,0,0,,{\an7\pos(100,100)}Cue D: anchored top-left.
```

### 原始命令

```bash
cd .spike/engine && source /Users/fuunylmz/Prism/scripts/env.sh && \
  .build/out/Products/Debug/SubtitleSpike
```

### 原始输出

```
=== SubtitleSpike (T1.8 项 2) ===
ASS 文件: /Users/fuunylmz/Prism/.spike/engine/media/spike-test.ass
load 完成, state=playing
内嵌 subtitleTracks=0

addExternalSubtitleTrack -> TrackInfo(id=100000, name=Spike ASS, codec=ass, isExternal=true)
subtitleTracks 现在有 1 条:
  id=100000 name=Spike ASS codec=ass external=true lang=eng

selectSubtitleTrack(100000) -> activeSubtitleTrackIndex=100000
播放中 sourceTime=0.300
播到 sourceTime=10.001 state=ended

--- $subtitleCues 产出 ---
共 4 条 cue:
  id=0 [0.200 – 2.000]
      body: .text("Cue A: fade only, no other overrides.")
      placement: nil
  id=1 [2.100 – 4.000]
      body: .text("Cue B: top-positioned red style.")
      placement: alignment=nil position=(0.5000, 0.1111)
  id=2 [4.100 – 6.000]
      body: .richText(["Cue C: inline "[plain], "red"[color=#FF0000], " and "[plain], "bold"[bold], " runs."[plain]])
      placement: nil
  id=3 [6.100 – 8.000]
      body: .text("Cue D: anchored top-left.")
      placement: alignment=7 position=(0.0521, 0.0926)

--- ASS 富文本解析判定 ---
\fad(300,300) 覆盖标签是否泄漏进文本: 否（已被丢弃）
  Cue A 文本: "Cue A: fade only, no other overrides."
  Cue A placement: nil（样式里的 Alignment=8 没有被映射成 placement）
\pos(960,120) -> placement: alignment=nil pos=(0.5000,0.1111)
  (PlayRes 1920x1080 => 期望 (0.5000, 0.1111))
行内颜色/粗体 -> .richText, 5 个 run:
    "Cue C: inline " color=nil bold=false
    "red" color=#FF0000 bold=false
    " and " color=nil bold=false
    "bold" color=nil bold=true
    " runs." color=nil bold=false
\an7\pos(100,100) -> alignment=7 pos=(0.0521,0.0926)

--- setSoftwareSubtitleDelay(0.5) ---
调用前 delay=0.0, cue 时间轴: 0.200–2.000, 2.100–4.000, 4.100–6.000, 6.100–8.000
调用后 delay=0.5, cue 时间轴: 0.200–2.000, 2.100–4.000, 4.100–6.000, 6.100–8.000
cue 时间轴是否偏移: 否（cue 仍是媒体时间，未加 0.5s）
说明: 该 API 的文档写明它只作用于 software PiP 合成；host overlay 需自行对 clock.sourceTime 施加同一偏移。
```

### 验证点逐项

- **轨道出现在 `subtitleTracks`** ✅ — `id=100000`（= `externalSubtitleTrackIDBase` + 序号），`codec=ass`，`isExternal=true`，`lang=eng`
- **`$subtitleCues` 产出 cue** ✅ — 4 条全部产出，时间轴与 ASS 文件完全一致（0.200/2.100/4.100/6.100 起始）
- **`setSoftwareSubtitleDelay(0.5)` 后时间轴偏移** ❌ — **没有偏移**。源码注释确认这是设计如此：*"Timing adjustment for subtitles composited into software PiP frames… Host overlays must apply the same value against `clock.sourceTime`. Native AVPlayer renditions are not affected."*
  → **Prism 若在窗口内自绘字幕，必须自己实现延迟**，不能依赖这个 API。

### 源码层面的佐证

`Sources/AetherEngine/Subtitles/SubtitleRectText.swift` 的 `applyOverrides` 只处理 `\r \c \1c \b \i \u \s \an \fn \fs \pos`，**没有 `\fad` / `\fade` / `\move` / `\blur` 分支**。这与实测一致。

---

## 3. 音轨切换

### 结论

**未达"不重建、不中断"的预期。** 切换到另一条音轨会触发一次完整的 `.loading`（约 143ms），并且 `clock.sourceTime` 在切换瞬间**归零约 86ms** 后弹回。

### 素材问题与处理

第一个样本 `bbb_720_10s_1MB.mkv` **只有视频、没有音轨**（`audioTracks.count = 0`）。按任务要求，先如实记录该情况：

```
[3] 音轨切换
audioTracks.count = 0
结论: 本样本只有 0 条音轨，无法验证「切换后不重建」。
      selectAudioTrack(index:) 仍会调用一次（同索引），预期无变化且不报错：
      before=nil after=nil state playing -> playing
```
→ **单音轨时 `selectAudioTrack(index:)` 无变化、不报错、不重建** ✅

为了真正验证多音轨，用本机 `ffmpeg` 从 BBB 视频流**无损复制**并合成两条音轨（H.264 保持 `copy`，这是 Emby 最常见的形状）：

```bash
ffmpeg -y -i bbb_720_10s_1MB.mkv \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=10" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=10" \
  -map 0:v:0 -map 1:a:0 -map 2:a:0 \
  -c:v copy -c:a:0 aac -b:a:0 128k -c:a:1 ac3 -b:a:1 192k \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title="English AAC" \
  -metadata:s:a:1 language=jpn -metadata:s:a:1 title="Japanese AC3" \
  bbb_2audio.mkv
```

```
stream|index=0|codec_name=h264|codec_type=video
stream|index=1|codec_name=aac|channels=1|tag:language=eng|tag:title=English AAC
stream|index=2|codec_name=ac3|channels=1|tag:language=jpn|tag:title=Japanese AC3
format|duration=10.021000|size=1344024
```

> 尝试过 `samples.ffmpeg.org/Matroska/multiple_tracks.mkv`（12.4 MB），但它只有 **mpeg4 (MPEG-4 Part 2)** 视频，走 software 路径而非 Emby 主流的 H.264 native 路径，代表性差，故改用上面的合成样本。

### 原始命令

```bash
cd .spike/engine && source /Users/fuunylmz/Prism/scripts/env.sh && \
  .build/out/Products/Debug/PlaybackSpike bbb_2audio.mkv
```

### 原始输出（关键段落）

```
[3] 音轨切换
audioTracks.count = 2
  id=1 name=English AAC codec=aac lang=eng  default=true
  id=2 name=Japanese AC3 codec=ac3 lang=jpn  default=false
切换前: 时间=3.700 state=playing duration=10.021
从 id=1(aac/eng) 切到 id=2(ac3/jpn)
切换后 5.150s: state=playing 时间推进=4.873s
  期间是否出现 .loading（管线重建）: 是
  期间是否出现 .error: 否
  duration 是否变化: 10.021 -> 10.021
  时钟是否单调不回退（播放未中断）: 否
  最大停顿（墙钟-媒体时间差）: 3.810s
    采样#0: 墙钟+0.110s 媒体+-3.700s 差=3.810s
    采样#2: 墙钟+0.102s 媒体+0.000s 差=0.102s
    采样#4: 墙钟+0.101s 媒体+0.073s 差=0.028s
  播放覆盖率: 94.6% (4.873s / 5.150s)
  切换期间 state 事件: t+5.675s loading, t+5.818s playing
```

`t+5.675s loading → t+5.818s playing` = **切换耗时 143ms**。

### 归零现象：高频探针确认

`clock.sourceTime` 在切换瞬间会归零。用 ~10ms 间隔的高频探针（切回 aac）确认：

```
[3b] 高频探针：再次切换，每 ~10ms 读一次 clock.sourceTime
  切换前 sourceTime=9.073 -> 切回 id=1(aac)
    t+0.034s  sourceTime=9.073  loading
    t+0.048s  sourceTime=9.101  loading
    t+0.069s  sourceTime=0.000  loading     ← 归零
    t+0.080s  sourceTime=0.000  loading
    t+0.101s  sourceTime=0.000  playing
    t+0.112s  sourceTime=0.000  playing
    t+0.123s  sourceTime=0.000  playing
    t+0.134s  sourceTime=0.000  playing
    t+0.145s  sourceTime=0.000  playing
    t+0.155s  sourceTime=9.072  playing     ← 弹回
    t+0.166s  sourceTime=9.072  playing
   ...
  探针窗口内最小 sourceTime = 0.000
  是否出现归零/回退: 是 —— 最小 0.000，低于切换前的 9.073
```

**归零窗口：t+0.069s ~ t+0.145s ≈ 86ms**（其中 ~66ms 处于 `.playing` 状态）。

### 结论与影响

| 预期 | 实际 |
|------|------|
| `$state` 不重建 | ❌ 出现 `.loading`（143ms） |
| 播放不中断 | ⚠️ 媒体时间未丢（9.073 → 9.072），但时钟有 86ms 归零 |
| 不报错 | ✅ 无 error |
| duration 不变 | ✅ 10.021 保持 |
| 播放覆盖率 | 94.6%（5.15s 内推进 4.873s） |

**对 Prism 的直接影响**：若进度条直接绑定 `player.clock.sourceTime`，切换音轨时会闪一下 0。建议 UI 层在 `state == .loading` 期间冻结进度条显示（保持上一个非零值），或用 `player.duration` 无关的独立 UI 时钟。**这是需要产品/UX 决策的点，不是纯技术 bug。**

> **诚实说明**：这是引擎的既有行为（native 路径的 in-place item swap 需要重建 HLS-fMP4 会话）。我**没有**修改引擎，也没有验证是否有其他 API（如 `LoadOptions` 的某个开关）能规避 —— 该问题超出本次验证范围。

---

## 4. PiP 在 macOS 上是否真的可用

### 结论

**可用。** 编译期可构造、运行期 `isPictureInPictureSupported() == true`、`isPictureInPicturePossible` 在 0.2s 内转为 `true`。

### 原始命令

```bash
cd .spike/engine && source /Users/fuunylmz/Prism/scripts/env.sh && \
  .build/out/Products/Debug/PlatformProbe
```

### 原始输出（项 4 部分）

```
=== PlatformProbe (T1.8 项 4 / 项 5) ===
macOS: 27.0.0  arch=arm64
Swift/AVFoundation 编译 SDK: macOS SDK Version 27.0 (Build 26A425)

[编译期探针] 以下符号在本文件里被引用并成功编译：
  AVPictureInPictureController
  AVPictureInPictureController.ContentSource(playerLayer:)
  AVPictureInPictureController.isPictureInPictureSupported()
  AVRoutePickerView
  AVPlayer.allowsExternalPlayback
  (AVPlayer.usesExternalPlaybackWhileExternalScreenIsActive 在 macOS 上**不存在**，编译期已排除)

[项 4] AVPictureInPictureController.isPictureInPictureSupported() = true
load 之前 nativePlayerLayer = nil
state=playing videoRoute=loopback backend=native

[项 4] nativePlayerLayer 取得成功: AVPlayerLayer
       player = 存在
[项 4] AVPictureInPictureController.ContentSource(playerLayer:) 构造成功
[项 4] AVPictureInPictureController 构造成功 (非 Optional init): AVPictureInPictureController
       isPictureInPicturePossible = false
       isPictureInPictureActive   = false
       delegate = nil
       canStartPictureInPictureAutomaticallyFromInline = <macOS 上不可用，编译期即报错>

[项 4a] 无窗口（离屏 NSView，未加入任何 NSWindow）时轮询 isPictureInPicturePossible:
   t+0.2s  possible=true
   t+0.4s  possible=true
   t+0.6s  possible=true
   t+0.8s  possible=true
   t+1.0s  possible=true
   t+1.2s  possible=true
   t+1.4s  possible=true
   t+1.6s  possible=true
   t+1.8s  possible=true
   t+2.0s  possible=true

[项 4b] 把 AetherPlayerView 放进一个不显示的 NSWindow 后再看:
   window.isVisible = false  (故意不 orderFront，不打扰用户)
   t+0.6s  possible=true
   t+1.2s  possible=true
   t+1.8s  possible=true
   结论: possible=true
   说明: 4a 阶段（完全无窗口）时它就已经在 t+0.2s 变成 true 了 ——
         初始的 false 只是 AVFoundation 还没算完，不是「不可用」。

       (按纪律不调用 startPictureInPicture()，PiP 窗口未弹出)
```

### 验证点

| 检查 | 结果 |
|------|------|
| API 可编译 | ✅ 全部符号编译通过 |
| `isPictureInPictureSupported()` | ✅ `true` |
| `ContentSource(playerLayer:)` 可构造 | ✅ 成功 |
| `AVPictureInPictureController(contentSource:)` 可构造 | ✅ 成功，且**返回非 Optional**（macOS 与 iOS 的 `init?` 不同） |
| `isPictureInPicturePossible` | ✅ 0.2s 后 `true`（初始 `false` 只是尚未异步就绪） |
| 是否需要窗口 | **不需要**。完全离屏（未加入任何 NSWindow）也能转 `true` |
| 是否真的弹窗 | ❌ **未弹出**（按纪律未调用 `startPictureInPicture()`） |

### 重要：macOS 与 iOS 的 API 差异

任务背景里列出的"macOS 上不存在"清单是准确的，实测又补充了两条**同样在 macOS 上不存在**的符号：

- `AVPlayer.usesExternalPlaybackWhileExternalScreenIsActive` → 编译期 `error: unavailable in macOS`
- `AVPictureInPictureController.canStartPictureInPictureAutomaticallyFromInline` → 编译期 `error: unavailable in macOS`

**因此 Prism 的 macOS 分支不能复用 iOS 的 PiP 代码**，必须用 `#if os(iOS)` 门控这两个符号。

### 【无法在本环境验证】

**PiP 窗口真的能否弹出、能否承载视频画面** —— 需要真实 GUI 会话，且按纪律不允许实际弹出窗口。验证方法：在有窗口的 Prism app 里调用 `pip.startPictureInPicture()`，确认系统 PiP 浮窗出现且画面跟随。

---

## 5. AirPlay 在 macOS 上是否可用

### 结论

**部分可用。** `AVPlayer` 的外部播放开关为 `true`，`AVRoutePickerView` 可构造；但**实际投送到 Apple TV / AirPlay 设备无法在无 GUI 环境验证**。

### 原始输出（项 5 部分）

```
[项 5] AirPlay / 外部播放
       allowsExternalPlayback = true
       isExternalPlaybackActive = false
       usesExternalPlaybackWhileExternalScreenIsActive = <macOS 上不可用，编译期即报错>
       audioOutputDeviceUniqueID = nil
       AVRoutePickerView 构造成功: AVRoutePickerView
       picker.isRoutePickerButtonBordered = true

[平台事实] macOS 上不存在 AVAudioSession（编译期即不可用），
           AetherEngine 的 audioNowPlayingSession / videoNowPlayingSession 也全部被
           #if os(tvOS) || os(iOS) 门控。
```

### 验证点

| 检查 | 结果 |
|------|------|
| `player.nativePlayerLayer?.player?.allowsExternalPlayback` | ✅ `true` |
| `isExternalPlaybackActive` | `false`（未在投送，符合预期） |
| `usesExternalPlaybackWhileExternalScreenIsActive` | ❌ **macOS 上不存在**（编译期报错） |
| `AVRoutePickerView` 可构造 | ✅ 成功 |
| `AVAudioSession` | ❌ macOS 上不存在（引擎的 Now Playing 会话全部被 `#if os(tvOS) || os(iOS)` 门控） |

### 【无法在本环境验证】

**AirPlay 投送是否真的工作**（能否在路由选择器里看到 Apple TV、投送后画面/声音是否到达）。原因：需要真实 AirPlay 接收设备 + GUI 会话 + 用户交互点击路由选择器。

验证方法：
1. 在有 GUI 的 Prism app 里放置 `AVRoutePickerView`，点击后确认弹出设备列表；
2. 选择一台 Apple TV，确认 `isExternalPlaybackActive` 变 `true`；
3. 确认画面在 Apple TV 上出现、本地窗口按系统行为变黑/显示占位。

**注意**：即使 `allowsExternalPlayback == true`，也只能说明 AVPlayer 允许外部播放，**不等于**投送链路已通。Emby 的 HLS-fMP4 loopback 源能否被 AirPlay 接收端正确解码，需要真机验证。

---

## 6. Swift 6 严格并发

### 结论

**通过（针对 Prism 侧的调用代码）。** 整个依赖图在 Swift 6 语言模式 + `-strict-concurrency=complete` 下 **0 error**，且 **Prism 侧 4 个 target 0 warning**。

> ⚠️ **重要限定**：AetherEngine 自身模块的编译命令行里带着 `-suppress-warnings`（SwiftPM 给依赖包注入的），所以**它的 warning 被吞掉了，不能据此断言"AetherEngine 内部零并发警告"**。这一点下面单独说明。

### 配置

`Package.swift`：

```swift
// swift-tools-version: 6.1
let shared: [SwiftSetting] = [
    .unsafeFlags(["-disable-sandbox", "-strict-concurrency=complete"])
]

let package = Package(
    name: "EngineSpike",
    platforms: [.macOS(.v15)],
    ...
    swiftLanguageModes: [.v6]
)
```

### 原始命令

```bash
cd .spike/engine && source /Users/fuunylmz/Prism/scripts/env.sh && \
  rm -rf .build/out && \
  swift build --disable-sandbox --cache-path "$PWD/.build/cache" \
    -Xswiftc -strict-concurrency=complete
```

> `rm -rf .build/out` 是必要的：否则 SwiftPM 的增量构建会复用上一次（非严格模式）的产物，**看不到任何诊断**，会得到假的"0 warning"。

### 原始输出（完整）

```
EXIT=0
=== 诊断行统计 ===
0
=== 所有 warning/error ===
=== 结尾 ===
[246 / 259] AetherEngine
[251 / 259] SubtitleSpike-product
Build complete! (32.74秒)
```

**诊断输出为空 —— 一条 warning 都没有。** 完整日志在 `/tmp/strict-build.log`（0 行匹配 `warning:|error:`）。

### 但必须说清楚：`-suppress-warnings` 掩盖了依赖包

把 `-v` 打开看真实编译命令行，会发现 AetherEngine 模块与我的 target 拿到的 flag **不一样**：

```bash
swift build --disable-sandbox --cache-path "$PWD/.build/cache" -v \
  -Xswiftc -strict-concurrency=complete 2>&1 | grep "module-name AetherEngine "
```

AetherEngine 模块的命令行里（截取）：

```
-strict-concurrency=complete
-enable-testing
-suppress-warnings        ← 关键
-swift-version 6
```

而我的 target（`PlaybackSpike`）里：

```
-strict-concurrency=complete
-swift-version 6
（没有 -suppress-warnings）
```

`-suppress-warnings` 不是 AetherEngine 自己在 `Package.swift` 里写的（我 grep 过整个 checkout，`suppress-warnings` 零命中），是 **SwiftPM 给非 root 依赖包自动注入的**。

**因此本项的准确结论是：**

| 范围 | 结论 |
|------|------|
| **Prism 侧调用代码**（SpikeKit / PlaybackSpike / SubtitleSpike / PlatformProbe） | ✅ **真实 0 warning**，未被抑制 |
| **AetherEngine 内部** | ⚠️ **无法从本次构建判断** —— warning 被 `-suppress-warnings` 吞掉 |
| **是否存在编译错误** | ✅ 0 error（error 不会被 suppress） |

**这对 Prism 意味着什么**：Prism 自己写的所有 `AetherEngine` 调用代码（`@MainActor` 上下文、Combine 订阅、`AVMetadataItem` 传递等）在 Swift 6 严格并发下是干净的 —— 这是实际集成时最要紧的部分。AetherEngine 内部是否干净，需要在它的 checkout 里单独跑 `swift build`（不带依赖注入的 suppress）才能确认，**本次未做**。

### 负向对照：证明严格检查确实生效

"0 warning" 有两种可能：真的干净，或者检查根本没开。为排除后者，插入一段**必然违规**的代码：

```swift
final class NotSendable { var x = 0 }

func negativeControl(_ v: NotSendable) async {
    Task.detached { _ = v.x }   // 期望：non-Sendable 捕获
}
```

结果：

```
error: passing closure as a 'sending' parameter risks causing data races between code in
the current isolation context and concurrent execution of the closure
[#RegionIsolation::SendingClosureRisksDataRace]
error: Build failed
```

→ **严格并发检查确实开启**，且这个错误来自 `SpikeKit`（我的 target，未被 suppress），证明我这边报告的"0 warning"不是假象。该文件已删除。

### 重点检查项

下表说的"无诊断"都指 **Prism 侧调用代码**（未被 suppress）：

| 关注点 | 结果 |
|--------|------|
| `@Published` 的 Combine 桥接 | ✅ 我的 target 无诊断。注意 `sink` 闭包在 Swift 6 下**不能**直接捕获 `@MainActor` 局部变量，需用 `@unchecked Sendable` 容器（spike 里用 `NSLock` 包装） |
| `AVMetadataItem` 传递 | ✅ 我的 target 无诊断（`AVMetadataItem` 本身是 `@unchecked Sendable`） |
| **`OpaquePointer`** | ✅ **公开 API 中出现 0 次**（`grep` 统计含 `public` 的行 = 0） |

`OpaquePointer` 确实存在于引擎内部（FFmpeg 的 `AVIOContext`/`SwsContext` 等，如 `Video/MP4SegmentMuxer.swift:619`、`Decoder/SoftwareVideoDecoder.swift:15`），但**全部是 internal，未泄漏到公开 API**。这与任务预期的"应该没有"一致。

---

## 7. 体积实测

### 结论

**已完整实测。** arm64 单架构下：可执行 10.66 MB + 9 个框架 10.65 MB + 资源 0.19 MB = **约 21.5 MB 未压缩**；deflate 压缩后 **约 8.1 MB**。

### 原始命令

```bash
cd .spike/engine && source /Users/fuunylmz/Prism/scripts/env.sh && \
  swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache"
# Build complete! (65.82秒)
```

### release 可执行文件

| 目标 | 字节 | MB | 架构 |
|------|------|-----|------|
| `PlaybackSpike` | 11,179,408 | 10.66 | arm64 |
| `SubtitleSpike` | 11,143,440 | 10.62 | arm64 |
| `PlatformProbe` | 11,134,080 | 10.61 | arm64 |
| `EngineSpike`（最小） | 11,079,896 | 10.56 | arm64 |

> 四个可执行文件体积几乎相同（10.56–10.66 MB），说明**体积几乎全部来自静态链接进可执行文件的 AetherEngine Swift 代码**，与 spike 自身的代码量无关。

### `@rpath` 动态框架清单（`otool -L`）

`otool -L` 显示 9 个 `@rpath` 依赖：

```
@rpath/AetherLibavcodec.framework/Versions/A/AetherLibavcodec     (62.28.103)
@rpath/AetherLibavformat.framework/Versions/A/AetherLibavformat   (62.12.103)
@rpath/AetherLibavutil.framework/Versions/A/AetherLibavutil       (60.26.103)
@rpath/AetherLibswresample.framework/Versions/A/AetherLibswresample (6.3.103)
@rpath/AetherLibswscale.framework/Versions/A/AetherLibswscale     (9.5.103)
@rpath/AetherLibavfilter.framework/Versions/A/AetherLibavfilter   (11.14.103)
@rpath/AetherLibdav1d.framework/Versions/A/AetherLibdav1d         (7.0.0)
@rpath/AetherLibzimg.framework/Versions/A/AetherLibzimg           (3.0.0)
@rpath/AetherLibzvbi.framework/Versions/A/AetherLibzvbi           (14.2.0)
```

（其余均为 `/System/Library/...` 与 `/usr/lib/...` 系统库，不计入 app 体积。）

### 框架体积：universal vs arm64 单架构

这些 framework 是**双架构 universal binary**（`lipo -archs` = `x86_64 arm64`）。打包 arm64-only app 时只需 arm64 切片：

| 框架 | universal (字节) | **arm64 切片 (字节)** | arm64 MB |
|------|-----------------|---------------------|----------|
| AetherLibavcodec | 12,898,160 | 6,115,184 | 5.83 |
| AetherLibavformat | 2,215,408 | 1,101,296 | 1.05 |
| AetherLibavutil | 1,459,088 | 738,192 | 0.70 |
| AetherLibswresample | 266,944 | 119,488 | 0.11 |
| AetherLibswscale | 2,289,616 | 1,077,200 | 1.02 |
| AetherLibavfilter | 861,312 | 418,944 | 0.39 |
| AetherLibdav1d | 2,579,664 | 810,192 | 0.77 |
| AetherLibzimg | 892,720 | 286,512 | 0.27 |
| AetherLibzvbi | 996,272 | 504,752 | 0.48 |
| **合计** | **24,459,184 (23.32 MB)** | **11,171,760 (10.65 MB)** | **10.65** |

→ **arm64 单架构框架合计 10.65 MB**（universal 的一半，符合预期）。

### 资源 bundle

`AetherEngine_AetherEngine.bundle` = 195,375 字节（0.19 MB），内含 `silent-atmos.mp4`（194,229 字节）+ `Info.plist`。

### 体积汇总（macOS arm64）

| 组成 | 字节 | MB |
|------|------|-----|
| 可执行文件 | 11,179,408 | 10.66 |
| 9 个框架（arm64 切片） | 11,171,760 | 10.65 |
| 资源 bundle | 195,375 | 0.19 |
| **.app 未压缩合计** | **22,546,543** | **21.50** |

### 压缩后体积（DMG 估算）

**⚠️ DMG 实际创建失败** —— `hdiutil create` 在本环境报 `hdiutil: create failed - 目录非空`，改用 `diskutil image create` 报 `OSStatus error 1`。原因是 DSH 文件沙箱不允许 hdiutil 挂载/写入磁盘映像。**因此 DMG 体积是用等价压缩算法实测的，不是猜的**：

实际组装了一个 arm64-only 的假 `Prism.app`（可执行 + 9 个 arm64 切片 + 资源 bundle，按真实 app 布局放进 `Contents/MacOS`、`Contents/Frameworks`、`Contents/Resources`），然后测量：

```bash
# .app 未压缩
find Prism.app -type f -exec stat -f%z {} \; | awk '{s+=$1} END {print s}'
# 22,529,775 bytes = 21.49 MB

# zip -9，-y 保留 framework 的符号链接（否则符号链接被跟随，体积会虚高 2 倍）
zip -q -r -9 -y /tmp/prism.zip Prism.app
# 8,488,375 bytes = 8.10 MB

# tar.gz -9 交叉验证
tar czf /tmp/prism.tar.gz Prism.app
# 8,499,045 bytes = 8.11 MB
```

| 指标 | 字节 | MB |
|------|------|-----|
| .app 未压缩 | 22,529,775 | 21.49 |
| zip -9（deflate） | 8,488,375 | **8.10** |
| tar.gz -9（gzip） | 8,499,045 | **8.11** |

> **符号链接陷阱**：第一次用 `zip -9`（不带 `-y`）得到 18.17 MB，因为 zip 跟随了 `Versions/Current` 和 `Foo.framework/Foo` 两个符号链接，把每个框架存了三份。加 `-y` 后为 8.10 MB，与 tar.gz 的 8.11 MB 一致 —— 两个独立工具互相验证，结果可信。

**DMG 体积估算：约 8.1 MB**（UDZO ≈ deflate，与 zip -9 同量级；DMG 有少量元数据开销，实际可能 8.2–8.6 MB）。

> 压缩率很高（21.5 → 8.1 MB，约 38%），因为可执行文件和框架里有大量可压缩的符号表/字符串/未优化代码。注意这是 **spike 可执行文件**（含完整引擎代码 + 符号），正式 Prism app 若 strip 并开启 LTO 会明显更小。

### 【无法在本环境验证】

**最终 DMG 体积** —— 需要 `hdiutil` 权限。验证方法：在非沙箱环境执行上面的 `hdiutil create -format UDZO`，或直接看 Xcode 归档导出的 DMG。

---

## 附：spike 源码结构

全部在 `.spike/engine/`（已被 `.gitignore` 忽略，不污染仓库）：

```
.spike/engine/
├── Package.swift                        # 4 个可执行 target + 1 个共享库，swiftLanguageModes [.v6]
├── Sources/
│   ├── SpikeKit/RunLoopPump.swift       # 主 run loop 泵 + PlaybackState 迁移记录器
│   ├── EngineSpike/main.swift           # 项 0：最小冒烟（主管已跑过，保留）
│   ├── PlaybackSpike/main.swift         # 项 1：真实播放 + seek 精度；项 3：音轨切换
│   ├── SubtitleSpike/main.swift         # 项 2：外挂 ASS 字幕
│   └── PlatformProbe/main.swift         # 项 4：PiP；项 5：AirPlay
└── media/
    ├── bbb_720_10s_1MB.mkv              # curl 下载，939 KB，H.264 1280x720，无音轨
    ├── bbb_2audio.mkv                   # ffmpeg 合成，1.34 MB，H.264 + AAC(eng) + AC3(jpn)
    └── spike-test.ass                   # 手写，1920x1080，含 \pos/\an/\fad/颜色/粗体
```

### 运行方式

```bash
cd /Users/fuunylmz/Prism/.spike/engine
source /Users/fuunylmz/Prism/scripts/env.sh
swift build --disable-sandbox --cache-path "$PWD/.build/cache"

.build/out/Products/Debug/EngineSpike                 # 项 0
.build/out/Products/Debug/PlaybackSpike               # 项 1（单音轨样本）
.build/out/Products/Debug/PlaybackSpike bbb_2audio.mkv # 项 1 + 项 3（双音轨）
.build/out/Products/Debug/SubtitleSpike               # 项 2
.build/out/Products/Debug/PlatformProbe               # 项 4 + 项 5
```

### 一个必须知道的实现细节：主 run loop

`AetherEngine` 是 `@MainActor` 的，其时钟依赖 AVPlayer 的 periodic time observer。Swift 的 `async main` 走 `dispatch_main()`，**只排空主队列、不跑 CFRunLoop**，导致 `clock.sourceTime` 永远停在 0（看起来像"播放没起来"）。

`SpikeKit/RunLoopPump.swift` 的解法：把异步逻辑丢进 `@MainActor` Task，主线程用 `RunLoop.main.run(until:)` 反复泵。**如果 Prism 里要写任何命令行播放测试工具，这个坑会重现。**

---

## 未通过 / 有缺口的项汇总

| 项 | 问题 | 影响 | 建议 |
|----|------|------|------|
| 2 | `\fad` 淡入淡出被丢弃 | ASS 字幕无淡入淡出效果，与 mpv/Infuse 观感有差异 | 接受（Prism 自绘层也做不了），或自行解析 ASS 原始行 |
| 2 | 样式级 `Alignment` 不映射到 `placement` | 依赖 Style 定位的字幕会全部落在默认位置 | 需自己读 `TrackInfo.assHeader` 解析 Style |
| 2 | `setSoftwareSubtitleDelay` 不影响 `$subtitleCues` | 字幕延迟功能必须自己实现 | 在 host overlay 里对 `clock.sourceTime` 施加偏移 |
| 3 | 音轨切换触发 `.loading`（143ms）+ 时钟归零（86ms） | 进度条会闪 0，有短暂黑帧风险 | UI 在 `.loading` 期间冻结进度显示；需产品决策 |
| 4 | 未验证 PiP 窗口真正弹出 | 无法确认 PiP 内画面是否正常 | 需 GUI 环境手工验证 |
| 5 | 未验证 AirPlay 实际投送 | 无法确认投送链路是否通 | 需真机 Apple TV 验证 |
| 6 | AetherEngine 内部 warning 被 `-suppress-warnings` 吞掉 | 无法断言引擎内部零并发警告 | 在 checkout 里单独 `swift build`（不带依赖 suppress）补测 |
| 7 | DMG 未实际创建（沙箱限制） | 体积为 zip/tar.gz 实测的等价估算 | 非沙箱环境补测 |
