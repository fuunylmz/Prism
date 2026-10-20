# Prism 播放引擎技术选型与落地方案

> 文档版本：2026-10-21 ｜ 作者：播放引擎架构师（代理）
> 适用代码基线：SwiftUI 原生 macOS，Xcode 27.1 / Swift 6.4 / 部署目标 macOS 15+
> 本文所有技术断言都带置信度标记，见 §9「来源与置信度」。**请先读 §0.3 再读其它章节。**

---

## 0. 结论先行

### 0.1 一句话结论

**采用双引擎：AVPlayer 负责 MP4 / HLS / 直封，libmpv（MPVKit）负责 MKV / 复杂字幕 / AVPlayer 无法解码的音频。** 该结论经过实测复核，**未被推翻**，但推翻条件明确写在 §4.3。

### 0.2 五条最重要的判断

| # | 判断 | 依据强度 |
|---|---|---|
| 1 | AVFoundation **完全不认 MKV**，且**不认 DTS/TrueHD**，这不是配置问题而是能力边界 | 本机实测 + Apple 官方格式列表 |
| 2 | HLS 路线救不了 DTS/TrueHD，也救不了 ASS/PGS（HLS 字幕只允许 WebVTT/IMSC1） | Apple HLS Authoring Spec 原文 |
| 3 | MPVKit 的 LGPL 分支**确实包含 libass**，ASS/PGS 渲染能力完整；但它产出的是**静态库**，这让 LGPL-3.0 的闭源分发只剩「附目标文件」一条路 | 实测 `file`/`otool` + `Package.swift` 原文 |
| 4 | libmpv 的 Swift 6 严格并发**不是问题**——因为 MPVKit 的 Swift 表面为零，全部是 C；我们的 wrapper 用「单串行队列 + `nonisolated(unsafe)`」即可零诊断通过 | 本机实测编译（§7.3） |
| 5 | mpv 路径**拿不到 AirPlay、PiP、系统 HDR/DV 握手**。这是双引擎方案必须接受的 UX 不对称 | Apple 文档 + mpv 架构事实 |

### 0.3 阅读前必须知道的三件事

1. **本文档的 spike 只验证了「引擎 API 面」，没有验证「窗口渲染」。** 我在本机跑通了 MKV 解封装、HEVC Main10 识别、双音轨切换、外挂 ASS 加载与样式覆盖、seek/speed/volume/buffering 属性、`audio-spdif` 选项接受——全部通过（§7.2 有完整输出）。**但 `vo=gpu-next + MoltenVK` 渲染到 `CAMetalLayer` 这一段没有跑通**（离屏 `vo=image` 未能写出帧，原因未查明，见 §9.3）。渲染路径属于「待验证」，不要把 §7 当成渲染已验证。
2. **许可证是本文最硬的风险，不是技术问题。** MPVKit 只能产静态库，LGPL-3.0 §4d1（共享库机制）走不通。详见 §3.3 与 §8-R1。本文不提供法律意见，只陈述条款原文与推论。
3. **本文与 `docs/DECISION-mpv-license.md` 是配套关系**：那份是决策备忘（A/B/C 三方案），本文是技术方案。两者对许可证的口径必须一致，若冲突以决策备忘为准。

---

## 1. 事实基础：AVFoundation 到底能做什么

### 1.1 容器与编解码边界（本机实测）

在 macOS 27.0 / Xcode 27.1 / Swift 6.4 上直接调用 AVFoundation：

```swift
AVURLAsset.audiovisualTypes()   // 返回 104 个 UTI
```

**结果：104 个 UTI 中不含任何 Matroska / MKV 类型。** 含 `public.ac3-audio`、`public.enhanced-ac3-audio`、`com.apple.m4v-video`、`public.mpeg-4` 等。

对本地生成的三份样本做 `AVURLAsset.loadTracks`：

| 文件 | 结果 | 视频 subtype | 音频 subtype |
|---|---|---|---|
| `test.mp4`（H.264 + AAC） | ✅ isPlayable=true | `avc1` | `aac` |
| `test.mkv`（H.264 + AAC） | ❌ **抛错 `Cannot Open`** | — | — |
| `test_hevc_ac3.mp4`（HEVC + AC-3） | ✅ isPlayable=true | `hvc1` | `ac-3` |

**结论（已核实）：**
- MKV 容器对 AVFoundation **完全不可见**，与内部编码无关——即使里面是 AVFoundation 最擅长的 H.264+AAC，也一样打不开。
- AC-3 在 **MP4 容器内** AVFoundation 认；HEVC 需要 `hvc1` tag（不是 `hev1`）。

### 1.2 音频编解码边界

AVFoundation **没有 DTS / DTS-HD / TrueHD / MLP 解码器**。这一条有多个独立来源交叉印证：

- Apple 官方 Apple TV 4K 规格页列出的音频格式只有 AC-3、E-AC-3、Atmos、AAC、ALAC、FLAC 等，**无任何 DTS**。
- Swiftfin（Jellyfin 官方 Apple 客户端）的播放器对比文档明确标注：Native (AVPlayer) 对 **DTS ❌、DTS-HD ❌、TrueHD/MLP ❌**；连它的 VLC 播放器选项也标注 DTS-HD/TrueHD ❌。
- Emby 社区有长期讨论：DTS/TrueHD 无法靠 remux 解决，**只能转码音频**。

**这条决定了整个架构**：如果用户的 MKV 里是 DTS，纯 AVPlayer 方案每次播放都要服务器转码音频（CPU 开销 + 音质损失），而 Emby 用户库里 DTS 极其常见。

### 1.3 HLS 能救什么、救不了什么

Apple 官方 [HLS Authoring Specification](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices) 原文（我逐条抓取核对）：

| 条款 | 原文要点 | 对我们的含义 |
|---|---|---|
| 1.2 | H.264 容器 **MUST** 是 fMP4 或 MPEG-TS | H.264 走 TS 也行 |
| **1.5** | **HEVC 容器 MUST 是 fMP4** | HEVC 不能走 TS，必须 fMP4 |
| 1.7 | HDR HEVC **MUST** 是 HDR10 / HLG / Dolby Vision | — |
| 1.9 | Dolby Vision **MUST** 是 Profile 5 且 ≤ Level 7 | DV Profile 7/8 不在规范内 |
| 1.10 | 参数集应放在 sample description，用 `hvc1`/`dvh1` 而非 `hev1`/`dvhe` | 与 §1.1 实测一致 |
| **2.5** | 支持的多声道音频只有 AC-3、E-AC-3、E-AC-3 JOC（及 AAC/ALAC/FLAC 等） | **DTS / TrueHD 不在列** |
| **5.2** | 字幕 **MUST** 是 WebVTT 或 IMSC1（text profile） | **ASS/SSA/PGS 无容身之处** |
| 5.3 | WebVTT 必须是文本文件且带 `X-TIMESTAMP-MAP` | 需要服务端切分 |
| 5.4 | IMSC1 必须在 fMP4 内 | — |

**结论（已核实）：**
- HLS 直封能解决 **容器问题**（MKV → fMP4），能保住 H.264/HEVC 视频与 AAC/AC3/EAC3 音频的**零转码**。
- HLS 直封**解决不了** DTS/TrueHD（不在允许列表），也**解决不了** ASS/PGS（只允许 WebVTT/IMSC1）。
- 所以「靠 Emby 转成 HLS 就万事大吉」是错的：字幕和 DTS 仍然会掉。

### 1.4 Emby 服务端现实（社区实证，非官方承诺）

Emby 的 HLS 输出**默认是 MPEG-TS**，除非客户端在 DeviceProfile 里显式声明 `"Container": "mp4"`。Emby 社区有详细帖记录：

- 默认输出 TS → HEVC 无法直封 → 服务器把 HEVC 转成 H.264（画质与 CPU 双输）。
- 把 TranscodingProfile 的 `Container` 设为 `mp4` 后，Emby 4.9.5.0 起确实产出 `#EXT-X-MAP:URI=` + `.mp4` 分片（即 fMP4）。
- 另有已知缺陷：ffmpeg 输出未打 `hvc1` tag，导致 AVKit 不认 HEVC。

> ⚠️ 这是**社区实证**，不同 Emby 版本行为可能不同。**必须在真实服务器上验证**（§7.4 给了验证清单）。

---

## 2. 候选引擎逐个核实

### 2.1 MPVKit（`github.com/mpvkit/MPVKit`）

#### 2.1.1 事实清单

| 项 | 值 | 来源 |
|---|---|---|
| 最新 release | `1.1.0-n9.0.2`（2026-10-07，**prerelease=true**） | GitHub Releases API |
| 最新**非** prerelease | `1.0.0`（2026-07-25） | 同上 |
| `1.0.0` 内含 | mpv **v0.41.0** / FFmpeg **n8.1.2** / libplacebo 7.360.1 / MoltenVK 1.4.2 | release notes 原文 |
| `1.1.0-n9.0.2` 差异 | 仅 FFmpeg n9.0.1 → n9.0.2（两次 bot bump，PR #82/#85），mpv 仍 v0.41.0 | release notes 对比 |
| `swift-tools-version` | 5.9 | `Package.swift` 原文 |
| platforms | `.macOS(.v12)` / `.iOS(.v15)` / `.tvOS(.v15)` / `.visionOS(.v1)` | `Package.swift` 原文 |
| products | `MPVKit`（LGPL-3.0）、`MPVKit-GPL`（GPL-3.0） | `Package.swift` + README |
| 产物形态 | **静态库**（`current ar archive`） | 实测 `file` / `otool -hv`（filetype OBJECT） |
| client API 版本 | `131077`（= 2×65536+5 → mpv 2.5） | 实测 `mpv_client_api_version()` |
| LGPL 分支的 FFmpeg 许可证串 | `libavcodec license: LGPL version 3 or later` | 实测 `strings` |
| 是否有 Swift 源码 | **没有**。`Sources/_MPVKit/` 只有 `dummy.c` + `include/` | GitHub API 列目录 |

#### 2.1.2 LGPL 分支是否包含 libass？——**包含，已确认**

`Package.swift` 中 `_FFmpeg`（LGPL 分支的聚合 target）的依赖列表里明确含：

```
"Libass", "Libfreetype", "Libfribidi", "Libharfbuzz", "Libunibreak"
```

而 `_FFmpeg-GPL` 相对 `_FFmpeg` **只多一个 `Libsmbclient`**。所以：

- **libass 在 LGPL 分支里**，ASS/SSA 渲染能力不因选 LGPL 而损失。
- **代价是 LGPL 版没有 SMB**（`Libsmbclient` 仅 GPL 分支）。对 Emby 场景无影响（走 HTTP）。
- 这 5 个 libass 家族的 binaryTarget **LGPL/GPL 共用同一份 asset URL**（指向 `libass-build` 仓库，无 `-GPL` 后缀），所以不存在「GPL 版才有 libass」的陷阱。
- 各自许可证：libass **ISC**、FreeType **FTL/GPLv2 双许可**、FriBidi **LGPL-2.1+**、HarfBuzz **MIT**、UnicodeBreak **zlib** —— 都比 LGPL-3.0 宽松，不构成额外负担。

#### 2.1.3 包体积（本次实测，非估算）

测量方法：从 `1.0.0` release 用 `curl` 逐个下载 29 个 xcframework → 解压 → `lipo -thin arm64` → 逐框架 `stat`。

**下载量：**

| 口径 | 数值 | 说明 |
|---|---|---|
| 单个 repo 的非 GPL `*.xcframework.zip` | ~217 MB | 只算 `MPVKit` 仓库自身的 asset |
| **全部非 GPL binaryTarget（含跨 repo）** | **~350–380 MB** | SwiftPM 实际会去 13 个不同 repo 下载 |
| release 的 36 个 asset 总量 | 449 MB | **这个数字没有意义**——含 8 个 `*-all.zip` 汇总包，SPM 不下载 |

> ⚠️ 早期估算 217 MB **偏低**，因为漏算了跨 repo 的 13 个 binaryTarget（openssl-build / gnutls-build / libass-build / libbluray-build / moltenvk-build / libshaderc-build / lcms2-build / libplacebo-build / libdovi-build / libdav1d-build / libuavs3d-build / libuchardet-build / libluajit-build）。

**最终二进制增量（macOS arm64 单架构，未压缩）：**

| 框架 | 大小 |
|---|---|
| Libshaderc_combined | 15.7 MB |
| Libavcodec | 9.8 MB |
| Libcrypto | 8.7 MB |
| Libmpv | 6.0 MB |
| gnutls | 4.4 MB |
| Libdovi | 2.9 MB |
| Libavformat | 2.4 MB |
| Libharfbuzz | 2.0 MB |
| Libssl | 1.9 MB |
| Libplacebo | 1.7 MB |
| 其余 18 个 | ~9.1 MB |
| **合计** | **≈ 67.6 MB** |

> 注意：这是 `lipo -thin arm64` 后的**未压缩**体积。若只发 Apple Silicon（macOS 15+ 的现实选择），.app 增量约 **60–70 MB**（zip 压缩后可下载体积更小）；若发 Universal 则约翻倍。Xcode 的 dead-strip 会砍掉未引用的 FFmpeg 解码器，实际可能更小，但**没有实测，不要引用具体收益数字**。

#### 2.1.4 维护活跃度——**这是主要风险**

README 原文（逐字引用）：

> **MPVKit is only suitable for learning libmpv and will not be maintained too frequently.**
> For production use, consider try using AetherEngine

- 仓库 209 stars / 130 forks / 230 commits（GitHub 页面数据）。
- 2026 年提交主要是 GitHub Actions bot 的版本 bump（FFmpeg/libplacebo 等），人工提交很少。
- 8 个 open issues，多数是平台适配问题（tvOS 冻结、iOS Metal resize、Atmos 音频连接不断开）。
- **作者本人建议生产环境换 AetherEngine**（见 §2.4）。

**这条必须写进风险表**：我们选的不是一个活跃维护的库，而是一个「能用但作者不承诺维护」的二进制分发。

#### 2.1.5 一个已修复但值得记录的许可证事故

MPVKit issue #77 / PR #78：用户发现**「LGPL 版」的 FFmpeg 构建带了 `--enable-nonfree`**，二进制里含 `libavcodec license: nonfree and unredistributable` 字符串——这会让整个产物**不可再分发**。维护者确认并合并了修复（2026-07-11）。

**本次实测复核：`1.0.0` 的 `Libavcodec` 里只有 `libavcodec license: LGPL version 3 or later`，不含 nonfree 字样。** 即 `1.0.0` 已包含该修复。

> **教训**：依赖第三方二进制分发时，**必须自己 `strings | grep nonfree` 复核**，不能信 README 的「LGPL」标签。这条已写入 §8-R2。

#### 2.1.6 Swift 6 严格并发——**实测通过**

这是本任务里唯一「查不到文档、只能实测」的点。

- GitHub 搜索 `repo:mpvkit/MPVKit` + `Sendable` / `concurrency`：**total_count = 0**。
- 搜 `swift 6`：仅 1 条无关 issue。
- 即：**MPVKit 官方从未声明 Swift 6 并发适配，社区也无已知问题记录。**

但我用实测给出了答案（§7.3 有完整命令与输出）：在 `-swift-version 6 -strict-concurrency=complete` 下编译一个符合「单串行队列 + `nonisolated(unsafe)`」模型的 wrapper，**编译零诊断、运行全部功能通过**。

原因很清楚：MPVKit 的 Swift 表面为零（只有 `dummy.c` + C 头文件），Swift 6 的严格并发检查**没有库内 Swift 代码可检查**，只作用于我们的 wrapper。`mpv_handle*` 是 `OpaquePointer`（非 Sendable），必须由我们自己做隔离。

### 2.2 VLCKit（`code.videolan.org/videolan/VLCKit`）

| 项 | 值 | 来源 |
|---|---|---|
| 许可证 | **LGPL-2.1-or-later** | 仓库 README / COPYING |
| 最新 tag | `4.0.0-a25`（2026-09-30）、`3.7.4`（同日） | GitLab API |
| SPM 支持 | **官方仓库自带 `Package.swift`** | 原文 |
| platforms | iOS 12 / macOS **10.13** / tvOS 12 / watchOS 7.4 / visionOS 1 | `Package.swift` 原文 |
| 分发方式 | 单一 `binaryTarget` 指向 `download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260929-1631.zip` | 原文 |
| **动态 or 静态** | **动态**。4.0 的 NEWS 明确写 "removed support to compile VLCKit as a static framework" | NEWS 原文 |
| 二进制 zip 体积 | **922 MB**（HTTP `Content-Length: 922611306`） | 实测 HEAD |
| PiP | 4.0 新增，**iOS + macOS 都支持** | NEWS 原文 |
| 双字幕轨 | 4.0 支持两条字幕同时显示 | NEWS 原文 |

**关键差异（相对 MPVKit）：**

1. **VLCKit 是动态框架** → LGPL 的 4d1 路径（共享库机制）**可行**，闭源分发负担远小于 MPVKit。这是 VLCKit 相对 MPVKit 的**最大优势**，比技术能力更重要。
2. **922 MB 的下载包**是实打实的集成成本（SPM 会全量下载这个 zip，即使只用 macOS slice）。
3. libVLC 的 TLS **不支持 TLS 1.3**（Swiftfin 文档记录）——对走 HTTPS 的远程 Emby 服务器是潜在问题。
4. AirPlay：Swiftfin 记录 VLC 有「显著音频延迟」的已知 bug（[VLCKit issue #544](https://code.videolan.org/videolan/VLCKit/-/issues/544)），且不支持 AVPlayer 那种视频 AirPlay 路由。
5. 字幕渲染：VLC 有自己的 libass 集成，ASS 质量良好；但**没有 mpv 那种 `sub-ass-override` 的细粒度样式覆盖**。

### 2.3 KSPlayer（`github.com/kingslay/KSPlayer`）

- 定位：完整的播放器框架（自带 UI），基于 AVPlayer + FFmpeg。
- **许可证：默认 GPL**，LGPL 版本需**付费**购买。GPL 版本功能阉割（AV1 硬解、全部解码器、PiP 字幕显示等都在付费 LGPL 版）。
- 对我们：**不适用**。要么 GPL 传染，要么付费，且它自带 UI 与我们的 SwiftUI 设计冲突。
- 结论：**排除**，但记入对比矩阵作为「同类方案参考」。

### 2.4 AetherEngine（`github.com/superuser404notfound/AetherEngine`）

这是 MPVKit 作者在 README 里推荐的替代品，值得认真评估。

| 项 | 值 |
|---|---|
| 许可证 | **LGPL-3.0 + App Store/DRM Exception**（自定义例外条款） |
| platforms | iOS 18 / tvOS 18 / **macOS 15** / visionOS 1 |
| swift-tools | 6.1 |
| 架构 | FFmpeg demux → **两条路**：(a) 重新封装成 HLS-fMP4 交给 AVPlayer；(b) libavcodec 解码 + `AVSampleBufferDisplayLayer`/`AVSampleBufferAudioRenderer` |
| 覆盖 | MKV/MP4/WebM/TS/AVI/OGG/FLV；H.264/HEVC/AV1/VP9/MPEG-2/VC-1；DVD/BD ISO |
| HDR | HDR10 / HDR10+ / Dolby Vision / HLG |
| 音频 | Atmos 直通、TrueHD/DTS 通过 "audio bridge" 转 EAC3 |

**它的 App Store Exception 条款**（我读了 LICENSE 原文）明确授予：即使平台条款限制重签名、DRM、终端用户重链接，也允许通过 App Store / TestFlight 分发。这直接解决了 §3.3 的 4d0/4d1 难题。

**但**：
- 单人维护（作者自述 "Vibe-coded ... in close pair-programming with Claude"）。
- macOS 15 起，与我们部署目标一致（这点反而合适）。
- 它是**引擎**（不是 UI），设计上就是给我们这种「自带 SwiftUI」的场景用的。
- **未实测**，只在文档层面核实。

**结论**：列为**Plan B**。如果 MPVKit 的许可证问题无法接受、又不想自建 dylib，AetherEngine 是比 VLCKit 更贴合「Apple 原生 + 格式广度」的选项。但它把 FFmpeg 作为**源码依赖**引入（不是二进制），构建时间和可审计性都需要评估。

### 2.5 其它已排除的方案

| 方案 | 排除理由 |
|---|---|
| **FFmpegKit** | **2025-01-06 已停止维护**，二进制从仓库移除。作者官方公告。**不要用**。 |
| 纯 AVPlayer + 服务端全转码 | DTS 必须转音频；ASS/PGS 必须烧录；每次播放吃服务器 CPU。违背「原生客户端」价值主张。 |
| 自研 MKV demux + fMP4 mux（AetherEngine/PrismCore 路线） | 工程量约 2000 行 Swift，且仍需解决 DTS 解码。**长期正确但短期不现实**。 |
| QuickTime `QTMovieModernizer` | 只做格式现代化，不扩展解码能力。 |

---

## 3. 对比矩阵

### 3.1 主矩阵

图例：✅ 原生支持 ｜ 🟡 有条件/需额外工作 ｜ ❌ 不支持 ｜ ⬜ 不适用

| 维度 | AVPlayer（原生） | libmpv / MPVKit | VLCKit 4 | AetherEngine |
|---|---|---|---|---|
| **MKV 容器** | ❌ 实测 `Cannot Open` | ✅ | ✅ | ✅ |
| **HEVC / HEVC Main10** | ✅（需 `hvc1` tag） | ✅（VideoToolbox hwdec） | ✅ | ✅ |
| **DTS / DTS-HD** | ❌ 无解码器 | ✅ 可解码，也可 `audio-spdif` 直通 | ✅ 可解码 | ✅（转 EAC3 桥接） |
| **TrueHD / Atmos** | 🟡 仅 E-AC-3 JOC（Atmos）经 HLS/MP4 | ✅ 解码；`audio-spdif=truehd` 可尝试直通 | ✅ 解码 | ✅ Atmos 直通（EAC3+JOC 原样拷贝） |
| **ASS / SSA** | ❌ HLS 只允许 WebVTT/IMSC1 | ✅ **libass**，支持 `sub-ass-override`/`sub-ass-style-overrides` | ✅ libass | ✅ |
| **PGS（图形字幕）** | ❌ | ✅ | ✅ | ✅ |
| **SRT** | 🟡 需转 WebVTT | ✅ 原生 | ✅ | ✅ |
| **HLS 直封/转码兼容** | ✅ 唯一原生消费者 | 🟡 能播 HLS，但不用系统 HDR 通路 | 🟡 同上 | ✅ 自己产 HLS-fMP4 |
| **字幕渲染质量** | ❌ 无 ASS | ✅✅ **最佳**（libass + libplacebo 可做 shader 级渲染） | ✅ 良好 | ✅ 良好 |
| **音频直通（HDMI/SPDIF）** | 🟡 仅 AC3/EAC3，经系统 | ✅ `audio-spdif=ac3,eac3,dts,dts-hd,truehd`（实测选项被接受） | 🟡 有 passthrough 模块 | ✅ |
| **HDR / 杜比视界** | ✅✅ **系统级握手**（Match Dynamic Range） | 🟡 自己 tone-map，`target-colorspace-hint` 可输出 EDR，但**不走系统 DV 握手** | 🟡 自己 tone-map（Swiftfin 注：色彩准确度可能有偏差） | ✅ 走 AVPlayer 时系统级 |
| **画中画（AVPictureInPictureController）** | ✅ AVPlayerLayer 路径最稳 | ❌ **渲染到 CAMetalLayer，拿不到 PiP** | ✅ 4.0 支持（iOS+macOS） | 🟡 用 AVSampleBufferDisplayLayer 路径时可行（macOS 有已知缩放 bug） |
| **AirPlay** | ✅✅ 系统级，视频+音频 | ❌ 不支持 | 🟡 音频有已知延迟 bug | ✅（走 AVPlayer 时） |
| **Now Playing / 远程控制** | ✅ 自动 + `MPNowPlayingInfoCenter` | 🟡 需手动填 `MPNowPlayingInfoCenter`（框架在 macOS 可用） | 🟡 同左 | ✅ 内置 |
| **性能与功耗** | ✅✅ 硬件解码 + 系统合成，最低功耗 | 🟡 软件栈更重；`gpu-next+MoltenVK` 有额外开销；作者注 Metal 支持只是 patch | 🟡 中等 | 🟡 取决于路径 |
| **包体积增量** | **0** | **≈ 60–70 MB**（arm64，未压缩实测） | **≈ 200 MB+**（922 MB 下载包） | 待测（FFmpeg 源码构建） |
| **Swift 6 并发安全** | ✅ Apple 已适配 | ✅ **实测零诊断**（C 表面，wrapper 自管） | 🟡 Objective-C API，无 Sendable 标注，需大量 `@preconcurrency` | 🟡 声明 Swift 6，未实测 |
| **SPM 集成难度** | ⬜ 系统框架 | 🟡 一条 `.package` 即可，但**首次拉 350–380 MB / 29 个 binaryTarget** | 🟡 一条 `.package`，但 **922 MB 单包** | 🟡 源码编译 FFmpeg，构建慢 |
| **许可证** | 系统框架，无限制 | ⚠️ **LGPL-3.0 + 静态链接 → 只能走 4d0** | ✅ **LGPL-2.1 + 动态框架 → 4d1 可行** | ✅ LGPL-3.0 + App Store 例外 |
| **维护活跃度** | Apple 维护 | ⚠️ **作者明示「不会频繁维护」** | ✅ VideoLAN 官方，月更 | ⚠️ 单人维护 |

### 3.2 单引擎可行性判断

| 方案 | 能否单引擎 | 致命缺口 |
|---|---|---|
| 纯 AVPlayer | ❌ | MKV 打不开、DTS 解不了、ASS 渲染不了。对 Emby 库等于废掉大半 |
| 纯 libmpv | 🟡 技术上可以 | **丢 AirPlay、丢 PiP、丢系统 HDR/DV 握手、丢自动 Now Playing**；且背 LGPL 静态链接问题 |
| 纯 VLCKit | 🟡 技术上可以 | 丢系统 HDR/DV 握手、AirPlay 音频有 bug、TLS 1.3 缺失、922 MB 包、200 MB 体积 |
| 纯 AetherEngine | 🟡 可能最优单引擎 | 未实测、单人维护、FFmpeg 源码构建 |

**这就是「不推翻双引擎」的核心论据**：没有任何单引擎能同时拿到「格式全覆盖」和「macOS 原生体验（AirPlay/PiP/HDR/Now Playing）」。这两组能力分属两个技术栈，物理上无法在一个引擎里兼得——除非像 AetherEngine 那样**在一个框架内部做双路径**（本质仍是双引擎，只是封装在别人家里）。

### 3.3 许可证：必须说清楚的部分

#### LGPL-3.0 §4 原文（我下载了 `gnu.org/licenses/lgpl-3.0.txt` 逐条核对）

闭源分发（Combined Work）时，除了 4a（显著声明）、4b（附 GPL+LGPL 副本）、4c（启动版权声明）之外，**4d 必须二选一**：

> **4d0)** Convey the Minimal Corresponding Source ... and the Corresponding Application Code in a form suitable for, and under terms that permit, the user to **recombine or relink** the Application with a modified version of the Linked Version ...
>
> **4d1)** Use a **suitable shared library mechanism** for linking with the Library. A suitable mechanism is one that (a) **uses at run time a copy of the Library already present on the user's computer system**, and (b) will operate properly with a modified version of the Library that is interface-compatible ...

#### 对 MPVKit 的推论

MPVKit 产出的是**静态库**（实测 `file` → `current ar archive`；`otool -hv` → `filetype OBJECT`）。

- **4d1 走不通**：静态链接后，库里没有「运行时使用用户机器上已有的副本」这回事。
- **只能走 4d0**：随 App 分发 **Minimal Corresponding Source + 可重链接的应用目标文件（.o）**，让用户能自己重链接。
- 这在 App Store 分发下**极其别扭**（要公开 .o、要提供重链接说明），且与 Apple 的签名/DRM 机制天然冲突。

#### 对 VLCKit 的推论

VLCKit 是**动态框架**（NEWS 明确 "removed support to compile VLCKit as a static framework"）。

- **4d1 可行**：把 VLCKit.framework 作为独立动态库嵌入 .app，用户可替换其中的二进制。
- 加上 4a/4b/4c 的声明义务即可。
- **这是 VLCKit 在许可证维度完胜 MPVKit 的原因**，与技术能力无关。

#### 我不能替你确认的部分

- FSF 官方 GPL FAQ 页面我抓下来全文搜 `App Store` / `iTunes` / `Apple` / `iPhone`，**命中数均为 0**。即 **FSF 没有关于 App Store 的专门条目**，任何「FSF 说 App Store 与 GPL 不兼容」的说法都是二手转述，我不会写。
- 可引用的**间接历史证据**：VLC 2011 年初因 GPLv2 与 App Store 条款冲突被下架；2011-10 将引擎部分改为 LGPLv2+；2013-07 以 MPL-2.0 重新上架 iOS。这说明「GPL 系 + App Store」历史上确有冲突，且业界解法是**换许可证或换动态链接**。
- **本文不构成法律意见。** 上线前必须由法务确认，或直接采用 AetherEngine 那种「显式 App Store 例外」的许可证。

---

## 4. 推荐方案

### 4.1 结论

**双引擎，按内容选路，AVPlayer 优先。**

```
                    ┌─────────────────────────┐
                    │   EngineSelector        │
                    │  (纯函数，无副作用)      │
                    └───────────┬─────────────┘
                                │ EngineChoice
              ┌─────────────────┴──────────────────┐
              ▼                                    ▼
   ┌────────────────────┐              ┌────────────────────┐
   │ AVPlayerEngine     │              │ MPVEngine          │
   │ MP4 / HLS / 直封    │              │ MKV / ASS / PGS    │
   │ AirPlay / PiP / HDR│              │ DTS / TrueHD       │
   └────────────────────┘              └────────────────────┘
              │                                    │
              └──────────────┬─────────────────────┘
                             ▼
                  ┌────────────────────┐
                  │  PlaybackEngine    │  ← 协议，引擎无关
                  │  (actor / MainActor)│
                  └────────────────────┘
```

### 4.2 为什么不是「AVPlayer 优先 + 全走 HLS 直封」

理论上可以让 Emby 把所有 MKV 直封成 HLS-fMP4 喂给 AVPlayer，这样只需一个引擎。**不采用**，因为：

1. **DTS/TrueHD 过不去**（HLS 音频白名单不含），必须转码音频 → 服务器 CPU + 音质损失。
2. **ASS/PGS 过不去**（HLS 字幕只允许 WebVTT/IMSC1），只能烧录 → 必须重新编码视频 → 画质损失 + 服务器重负载。
3. **依赖 Emby 服务端配置正确**（fMP4 输出、`hvc1` tag），而这些在不同版本上行为不一致（§1.4）。把核心体验押在服务端配置上，脆弱。
4. 直封需要客户端做「先探测再请求」的两段式，首帧延迟更高。

**结论**：HLS 直封作为**降级路径**保留，不作为主路径。

### 4.3 什么情况下应该推翻本方案

诚实列出推翻条件，供后续复核：

| 若发现 | 则改为 |
|---|---|
| 用户库里 MKV 占比 < 20%，且几乎无 DTS/ASS | **纯 AVPlayer + 服务端转码**，省掉 60 MB 和全部许可证麻烦 |
| 法务认定 4d0（分发 .o）不可接受，且不愿自建 dylib | **换 VLCKit 单引擎**（动态框架，4d1 合规），接受 UX 降级 |
| AetherEngine 实测稳定且许可证可接受 | **换 AetherEngine 单引擎**（它内部已做双路径，我们少维护一层） |
| mpv 渲染在 macOS 15 上无法稳定嵌入 SwiftUI | **放弃 mpv**，退化为 AVPlayer + 服务端转码 |
| 我们只需要「能播」，不需要 AirPlay/PiP/HDR | **VLCKit 单引擎**最省事 |

---

## 5. 抽象设计

### 5.1 硬性约束：引擎类型零泄漏

> **验收标准**：`OpaquePointer`、`mpv_handle`、`mpv_render_context`、`import Libmpv`、`import VLCKit` **一律不得出现在 `PlaybackEngine` 协议、`PlaybackState`、`Track`、`PlaybackEvent` 及任何对外类型中**。
>
> 建议加 CI 检查：
> ```bash
> # 只允许 MPVCore.swift 一个文件 import Libmpv
> grep -rl "import Libmpv" --include="*.swift" . | grep -v "MPVCore.swift" && exit 1
> ```

理由：许可证与维护风险都可能让我们**换引擎**（§4.3）。零泄漏是让「换引擎」从「重写播放器」降级为「换一个实现类」的唯一保障。

### 5.2 领域模型（引擎无关）

```swift
// MARK: - 值类型，全部 Sendable

public struct TrackID: Hashable, Sendable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}

public enum TrackKind: String, Sendable, Codable {
    case video, audio, subtitle
}

public struct MediaTrack: Identifiable, Hashable, Sendable {
    public let id: TrackID
    public let kind: TrackKind
    public let codec: String            // "h264" / "hevc" / "aac" / "dts" / "ass" / "hdmv_pgs_subtitle"
    public let language: String?        // BCP-47 或 mpv 的 ISO 639-2
    public let title: String?
    public let isDefault: Bool
    public let isForced: Bool
    public let channels: Int?           // 音频用
    public let isExternal: Bool         // 外挂字幕
}

public struct MediaTrackSet: Sendable {
    public var video: [MediaTrack] = []
    public var audio: [MediaTrack] = []
    public var subtitle: [MediaTrack] = []

    public var all: [MediaTrack] { video + audio + subtitle }
}

public struct PlaybackState: Sendable, Equatable {
    public var isPlaying: Bool = false
    public var isBuffering: Bool = false
    public var position: TimeInterval = 0
    public var duration: TimeInterval = 0
    public var bufferedPosition: TimeInterval = 0
    public var rate: Float = 1.0
    public var volume: Float = 1.0
    public var isMuted: Bool = false
    public var didReachEnd: Bool = false

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

public enum PlaybackEvent: Sendable {
    case stateChanged(PlaybackState)
    case tracksChanged(MediaTrackSet)
    case bufferStateChanged(isBuffering: Bool, bufferedPosition: TimeInterval)
    case didReachEnd
    case failed(PlaybackError)
    /// 引擎自愈失败，请求上层降级（见 §6.3 状态机）
    case requestsFallback(reason: PlaybackFailureReason)
}

public struct PlaybackError: Error, Sendable {
    public let reason: PlaybackFailureReason
    public let underlyingDescription: String
    public let isRecoverable: Bool
}

public enum PlaybackFailureReason: String, Sendable, Codable {
    case containerUnsupported
    case videoCodecUnsupported
    case audioCodecUnsupported
    case subtitleUnsupported
    case networkError
    case serverRejected
    case engineCrashed
    case unknown
}
```

### 5.3 字幕样式（引擎无关的中间表示）

```swift
public struct SubtitleStyle: Sendable, Equatable {
    public var fontName: String?            // nil = 引擎默认（跟随系统）
    public var fontSize: Double             // 相对 1080p 的像素值
    public var primaryColor: SubtitleColor
    public var outlineColor: SubtitleColor
    public var backgroundColor: SubtitleColor
    public var outlineWidth: Double
    public var shadowOffset: Double
    public var marginBottom: Double
    public var alignment: SubtitleAlignment
    /// 是否允许覆盖 ASS 内嵌样式。
    /// false = 尊重字幕作者排版（动漫/特效字幕必须 false）
    /// true  = 用户样式优先（普通观影偏好）
    public var overrideEmbeddedASS: Bool
}

public struct SubtitleColor: Sendable, Equatable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
}

public enum SubtitleAlignment: String, Sendable {
    case bottom, center, top
}
```

**映射到 mpv**（实测有效的选项名，见 §9.2）：

| 我们的字段 | mpv 选项 | 备注 |
|---|---|---|
| `overrideEmbeddedASS` | `sub-ass-override` = `no` / `force` / `scale` / `strip` | `no` 尊重作者样式；`force` 强制覆盖 |
| `fontName` / `fontSize` / `primaryColor` / `outlineWidth` | `sub-ass-style-overrides=FontName=...,FontSize=...,PrimaryColour=&HAARRGGBB,Outline=...` | **逗号分隔的 key=value 串**，实测被接受 |
| `marginBottom` | `sub-margin-y` / `sub-pos` | |
| `alignment` | `sub-align-y` = `top`/`center`/`bottom` | |
| 全局字号缩放 | `sub-scale` | |

> ⚠️ `sub-ass-style-overrides` 的颜色是 ASS 的 `&HAABBGGRR` 格式（**BGR 序，不是 RGB**），容易写错。实测接受 `&H0000FFFF`（= 黄色）。

### 5.4 `PlaybackEngine` 协议

```swift
import AVFoundation
import AppKit

/// 引擎无关的播放抽象。
///
/// 实现方必须是引用类型（class 或 actor）。所有方法在主 actor 上调用，
/// 内部实现自行负责把工作搬到自己的串行队列。
@MainActor
public protocol PlaybackEngine: AnyObject {

    // MARK: 身份

    static var engineKind: EngineKind { get }
    var engineKind: EngineKind { get }

    // MARK: 生命周期

    /// 加载媒体。`source` 是引擎无关的描述，由 EngineSelector 产出。
    func load(_ source: PlaybackSource) async throws

    /// 卸载并释放底层资源。
    func unload() async

    // MARK: 传输控制

    func play() async
    func pause() async
    func seek(to position: TimeInterval, precise: Bool) async
    func setRate(_ rate: Float) async
    func setVolume(_ volume: Float) async
    func setMuted(_ muted: Bool) async

    // MARK: 轨道

    var tracks: MediaTrackSet { get }
    func selectAudioTrack(_ id: TrackID?) async
    func selectSubtitleTrack(_ id: TrackID?) async
    /// 外挂字幕（URL 可以是 Emby 的 /Videos/{id}/{index}/Subtitles/{trackId}/Stream.ass）
    func addExternalSubtitle(_ url: URL, language: String?, title: String?) async throws -> TrackID
    func removeSubtitleTrack(_ id: TrackID) async
    func setSubtitleDelay(_ seconds: Double) async
    func setSubtitleStyle(_ style: SubtitleStyle) async

    // MARK: 状态

    var state: PlaybackState { get }
    /// 状态与事件的唯一出口。订阅者（ViewModel）负责驱动 SwiftUI。
    var events: AsyncStream<PlaybackEvent> { get }

    // MARK: 画面输出

    /// 返回一个可嵌入 SwiftUI 的 NSView（通过 NSViewRepresentable）。
    /// 引擎自己管理内部图层；调用方只负责布局。
    func makeVideoView() -> NSView

    /// 该引擎是否支持系统级画中画。AVPlayer 引擎 true，libmpv 引擎 false。
    var supportsPictureInPicture: Bool { get }

    /// 该引擎是否支持 AirPlay 路由。
    var supportsAirPlay: Bool { get }

    /// 用于系统 Now Playing。引擎不直接写 MPNowPlayingInfoCenter，
    /// 由上层统一的 NowPlayingCoordinator 负责（见 §5.6）。
    var nowPlayingSnapshot: NowPlayingSnapshot { get }
}
```

```swift
public enum EngineKind: String, Sendable, Codable {
    case avPlayer
    case libmpv
    case vlc          // 预留
    case aether       // 预留
}

/// 引擎无关的播放源描述。
public enum PlaybackSource: Sendable {
    /// 直接给引擎一个 URL（远程 HTTP / 本地文件 / Emby 直连 URL）
    case url(URL, headers: [String: String])
    /// 给 AVPlayer 一个本地 HLS 清单（未来若做客户端直封）
    case hlsManifest(URL)
    /// 给 libmpv 一个 URL + 额外 mpv 选项（如强制 `--sub-ass-override=no`）
    case urlWithOptions(URL, headers: [String: String], options: [String: String])
}
```

**为什么 `events` 用 `AsyncStream` 而不是 delegate/Combine**：
- Swift 6 下 `AsyncStream` 是 `Sendable` 的，天然跨隔离域。
- 与 SwiftUI 的 `.task { for await ... }` 配合自然。
- 避免 `@Published` 在主线程之外的写入问题。

### 5.5 `EngineSelector` 选路策略

```swift
public struct EngineSelection: Sendable {
    public let kind: EngineKind
    public let reason: SelectionReason
    /// 若该引擎加载失败，按顺序尝试这些
    public let fallbackChain: [EngineKind]
}

public enum SelectionReason: String, Sendable {
    case userPreference          // 用户显式指定
    case containerRequiresLibmpv // MKV 等
    case audioRequiresLibmpv     // DTS / TrueHD
    case subtitleRequiresLibmpv  // ASS / SSA / PGS
    case nativeOptimal           // MP4 + 兼容音频 + 无复杂字幕
    case hlsDirectPlay           // 服务端给的 HLS
    case lastKnownGood           // 上次成功的引擎
    case forcedFallback          // 上一轮失败后的降级
}

/// 纯函数，无 I/O、无状态。可单元测试。
public struct EngineSelector: Sendable {

    public struct Input: Sendable {
        public let container: String              // "mkv" / "mp4" / "ts" ...
        public let videoCodec: String?            // "h264" / "hevc" / "av1"
        public let audioCodecs: [String]          // ["aac","ac3","dts"]
        public let subtitleCodecs: [String]       // ["subrip","ass","hdmv_pgs_subtitle"]
        public let isHLS: Bool
        public let userPreference: UserEnginePreference
        public let lastSuccessful: EngineKind?
        /// 该设备 AVFoundation 是否认这个容器（来自能力探测缓存）
        public let avFoundationCanOpenContainer: Bool
    }

    public enum UserEnginePreference: String, Sendable {
        case automatic      // 默认
        case preferNative   // 尽量 AVPlayer（可能牺牲格式）
        case preferCompatibility  // 尽量 libmpv（画质/格式优先）
        case forceNative
        case forceCompatibility
    }

    public func select(_ input: Input) -> EngineSelection
}
```

**选路规则（按优先级短路）：**

```
1. 用户强制 → 直接用，fallbackChain = [强制引擎]
2. 用户偏好 preferNative 且 AVFoundation 能开容器、音频全兼容、字幕无 ASS/PGS
   → avPlayer, reason = nativeOptimal
3. 容器是 mkv/webm/avi 等 → libmpv, reason = containerRequiresLibmpv
4. 音频含 dts/dts-hd/truehd/mlp → libmpv, reason = audioRequiresLibmpv
5. 字幕含 ass/ssa/pgs/dvbsub → libmpv, reason = subtitleRequiresLibmpv
6. isHLS 且容器/编码在 HLS 白名单内 → avPlayer, reason = hlsDirectPlay
7. 其余 → avPlayer, reason = nativeOptimal

fallbackChain 规则：
- avPlayer 首选 → [avPlayer, libmpv]        （AVPlayer 失败就用 mpv 硬解）
- libmpv 首选  → [libmpv, avPlayer]         （mpv 失败，若容器是 mp4 可回 AVPlayer）
- 若 libmpv 也不可用（未集成/初始化失败）→ 只剩 avPlayer + 服务端转码
```

**关键设计点：**

1. **选路发生在 `load` 之前，不在播放中切换。** 中途换引擎会黑屏 + 丢位置。切换只在「加载失败」时发生，且要**保留 `position` 并在新引擎上 seek 回去**。
2. **`avFoundationCanOpenContainer` 来自能力探测，不是硬编码。** 用 `AVURLAsset.isPlayable` 异步探测一次并缓存（按 container + codec 组合做 key）。这样 Apple 未来若支持 MKV，我们自动受益。
3. **`lastSuccessful` 用于学习**：同一部剧集连续 3 集用 libmpv 成功，第 4 集直接走 libmpv，省掉一次失败的探测。
4. **用户偏好必须能覆盖一切**，但要在 UI 上说明代价（"强制原生可能无法播放此文件"）。

### 5.6 跨引擎统一能力：Now Playing

两个引擎都不能自动填系统 Now Playing（AVPlayer 在 macOS 上也不会自动发布完整元数据）。**统一由一个协调器负责**，避免每个引擎重复实现：

```swift
@MainActor
public final class NowPlayingCoordinator {
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()

    public func bind(engine: any PlaybackEngine, metadata: NowPlayingMetadata) {
        // 1. 填 nowPlayingInfo：title/artist/albumTitle/duration/elapsedTime/artwork
        // 2. 注册 remote command：play/pause/togglePlayPause/changePlaybackPosition/skipForward/skipBackward
        // 3. 订阅 engine.events，把 stateChanged 映射回 elapsedTime/rate
    }
}
```

> `MPNowPlayingInfoCenter` 与 `MPRemoteCommandCenter` 在 macOS 上均可用（macOS 10.12.2+，Apple 文档已核实）。

### 5.7 画面输出层

#### AVPlayer 引擎

```swift
final class AVPlayerVideoView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct AVPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerVideoView {
        let v = AVPlayerVideoView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ nsView: AVPlayerVideoView, context: Context) {}
}
```

PiP 走标准路径：`AVPictureInPictureController(playerLayer:)`。

#### libmpv 引擎（`wid` 嵌入）

MPVKit 官方 Demo 的做法是把一个 `CAMetalLayer` 子类当作 `wid` 传进去（macOS 上 libmpv 把 `wid` 解释为 `NSView*`）：

```swift
// 选项顺序很重要：必须在 mpv_initialize 之前设置
mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayer)   // ← 传 CAMetalLayer
mpv_set_option_string(mpv, "vo", "gpu-next")
mpv_set_option_string(mpv, "gpu-api", "vulkan")
mpv_set_option_string(mpv, "gpu-context", "moltenvk")
mpv_set_option_string(mpv, "hwdec", "videotoolbox")
```

**必须抄的两个 workaround**（来自 MPVKit Demo 的 `MetalLayer.swift`，是踩过坑的代码，不要自己重写）：

```swift
final class PrismMetalLayer: CAMetalLayer {
    // Workaround 1: MoltenVK 会把 drawableSize 强推成 1x1 来强制 present，
    // 导致闪烁 / drawableSize 卡在 1x1。拦掉 <=1 的赋值。
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    // Workaround 2: 激活屏幕 EDR（HDR）只能在主线程设置，
    // 其它线程调用不生效（target-colorspace-hint 依赖它）。
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}
```

> ⚠️ **`wid` vs render API 的路线冲突**：mpv 官方 `mpv-examples/libmpv/README.md` 说「using the render API is currently recommended over window embedding」（理由：window embedding 在 OSX 上有稳定性问题）；而 MPVKit 的 Demo 用的是 `wid`。
>
> **本文的选择：先走 `wid`**（1 天能跑通、代码量最小、MPVKit 唯一验证过的组合），**render API 作为 Plan B**。若 `wid` 在 SwiftUI 层级出现尺寸/层级/全屏问题，再切 `mpv_render_context_create` + 自管 `CAMetalLayer` 绘制循环。

---

## 6. HLS 转码与降级

### 6.1 Emby 的 `master.m3u8` 参数（官方 REST 文档逐字核对）

> **重要澄清**：`TranscodingContainer` **不是** `master.m3u8` 的 query 参数，它是 `PlaybackInfo` 响应里 `MediaSourceInfo` 的一个字段（服务端告诉你"我打算用什么容器转"）。传给服务端的是 `Container`。

| 参数 | 类型 | 说明 |
|---|---|---|
| `Id`（路径） | — | Item ID |
| `MediaSourceId` | query | 必填（`/Videos/{Id}/master.m3u8` 场景下从 PlaybackInfo 取） |
| `PlaySessionId` | query | 必填，客户端生成 |
| `Container` | query | **必填**。输出容器，如 `mp4` / `ts` |
| `VideoCodec` | query | `h264` / `hevc` / `mpeg4` / `theora` / `vpx` / `wmv` |
| `AudioCodec` | query | `aac` / `mp3` / `vorbis` / `wma` |
| `VideoBitRate` | query | 视频码率（bps） |
| `AudioBitRate` | query | 音频码率（bps） |
| `MaxWidth` / `MaxHeight` | query | 分辨率上限 |
| `MaxAudioChannels` | query | 声道数上限 |
| `AudioSampleRate` | query | 采样率 |
| `VideoStreamIndex` / `AudioStreamIndex` | query | 选流 |
| `SubtitleStreamIndex` | query | 烧录字幕时用 |
| `SubtitleMethod` | query | `Encode` / `Embed` / `External` / `Hls` / `VideoSideData` |
| `MaxVideoBitDepth` | query | 位深上限 |
| `StartTimeTicks` | query | 起播偏移（1ms = 10000 ticks） |
| `Static` | query | `true` = 原样静态流（直连/直封） |
| `EnableAutoStreamCopy` | query | 允许自动 stream copy（默认 true） |
| `CopyTimestamps` | query | 转码带偏移时是否复制时间戳 |

> `MaxStreamingBitrate` 是 **Universal Audio / PlaybackInfo** 端点的参数（DeviceProfile 层面），不是 `master.m3u8` 的。别传错。

### 6.2 DeviceProfile 建议（我们声明给 Emby 的能力）

#### DirectPlayProfiles（直连，零转码）

```json
[
  { "Container": "mp4,m4v,mov", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,alac,flac", "Type": "Video" },
  { "Container": "mkv",         "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,dts,truehd,flac,opus", "Type": "Video" },
  { "Container": "mp3,aac,m4a,flac,ogg,opus", "AudioCodec": "mp3,aac,flac,vorbis,opus", "Type": "Audio" }
]
```

**关键**：`mkv` 行把 `dts,truehd` 也列进去，因为 **libmpv 能解**。这能让 Emby 对大量 MKV 直接放行 DirectPlay，省掉服务器转码。

#### TranscodingProfiles（转码，降级用）

```json
[
  {
    "Type": "Video",
    "Protocol": "hls",
    "Container": "mp4",
    "VideoCodec": "hevc,h264",
    "AudioCodec": "aac,ac3,eac3",
    "Context": "Streaming",
    "MaxAudioChannels": "8",
    "MinSegments": 1,
    "SegmentLength": 6,
    "BreakOnNonKeyFrames": true,
    "CopyTimestamps": false,
    "EstimateContentLength": false,
    "EnableMpegtsM2TsMode": false
  }
]
```

**参数取舍理由：**

| 参数 | 值 | 理由 |
|---|---|---|
| `Protocol: hls` | 必须 | Emby 唯一的自适应流协议 |
| `Container: mp4` | **必须 mp4，不能 ts** | HLS 规范 1.5：HEVC 的容器 MUST 是 fMP4。设 `mp4` 才会让 Emby 走 `-hls_segment_type fmp4`（§1.4 实证） |
| `VideoCodec: hevc,h264` | 顺序有讲究 | **hevc 在前** = 优先保留 HEVC 直封（省 CPU、保 HDR）；h264 兜底 |
| `AudioCodec: aac,ac3,eac3` | 不含 dts/truehd | HLS 白名单里没有 DTS/TrueHD（规范 2.5）。写了也没用 |
| `SegmentLength: 6` | 6 秒 | Apple HLS 最佳实践推荐 6 秒 |
| `BreakOnNonKeyFrames: true` | 是 | 避免分片切在非关键帧导致花屏 |
| `EnableMpegtsM2TsMode: false` | 关 | 我们不要 TS |
| `MaxAudioChannels: "8"` | 8 | 保留 7.1，别过早降到 2.0 |

#### SubtitleProfiles

```json
[
  { "Format": "ass",  "Method": "External" },
  { "Format": "ssa",  "Method": "External" },
  { "Format": "srt",  "Method": "External" },
  { "Format": "subrip", "Method": "External" },
  { "Format": "pgssub", "Method": "Embed" },
  { "Format": "vtt",  "Method": "Hls" }
]
```

**关键**：ASS/SRT 全部声明为 **`External`**（不烧录），因为 libmpv 能直接读服务端给的字幕流（`/Videos/{id}/{mediaSourceId}/Subtitles/{index}/Stream.ass`）。**只有 PGS 声明 `Embed`**（图形字幕，libmpv 能解容器内的，但外挂形式 Emby 支持不好）。

> ⚠️ 若某条内容最终落到 AVPlayer 引擎，ASS 就不能 `External` 直读了（AVPlayer 不认 ASS）。此时要么转 WebVTT（`Method: "Hls"`），要么切回 libmpv。**这是 EngineSelector 与 DeviceProfile 的耦合点，容易漏。**

### 6.3 直连失败 → 降级转码的状态机

```
                    ┌──────────────┐
                    │   .idle      │
                    └──────┬───────┘
                           │ user selects item
                           ▼
                    ┌──────────────┐
                    │  .selecting  │  EngineSelector.select(input)
                    └──────┬───────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
     ┌─────────────────┐       ┌─────────────────┐
     │ .directPlay     │       │ .directStream   │
     │ (原文件 URL)     │       │ (HLS 直封)      │
     └────────┬────────┘       └────────┬────────┘
              │ 失败                     │ 失败
              ▼                          ▼
     ┌──────────────────────────────────────────┐
     │ .fallbackAttempt(attempt: 1..3)          │
     │  attempt 1: 换引擎（avPlayer ↔ libmpv）   │
     │  attempt 2: 请求 HLS 直封（只换容器）      │
     │  attempt 3: 请求 HLS 转码（换视频+音频）   │
     └──────────────┬───────────────────────────┘
                    │ 全部失败
                    ▼
             ┌──────────────┐
             │  .failed     │  向用户展示具体原因 + 重试按钮
             └──────────────┘

  任意状态 --用户停止--> .idle
  .directPlay/.directStream/.fallback --播放到结尾--> .ended
```

**降级决策表（触发条件 → 动作）：**

| 观测到的失败 | 判定 | 动作 |
|---|---|---|
| `AVURLAsset` 打不开容器（MKV） | `containerUnsupported` | 换 libmpv |
| 能打开但无视频轨 / 黑屏 | `videoCodecUnsupported` | 换 libmpv |
| 有画面无声音，日志显示音频解码失败 | `audioCodecUnsupported` | 换 libmpv；若已是 libmpv → 请求转码音频 |
| 字幕不显示（ASS 轨存在但无渲染） | `subtitleUnsupported` | 换 libmpv；若已是 libmpv → 请求 `SubtitleMethod=Encode` 烧录 |
| HTTP 4xx/5xx | `serverRejected` | 刷新 PlaybackInfo 重取 URL（token 可能过期） |
| 播放中卡死 > 15s 无进度 | `networkError` | 重连一次；再失败 → 降码率转码 |
| 引擎进程/上下文崩溃 | `engineCrashed` | 重建引擎，从最后位置 seek 回去 |
| 连续 3 次降级失败 | — | `.failed`，**不要无限重试** |

**关键实现约束：**

1. **每次降级必须保留播放位置**。`position` 在切引擎前捕获，新引擎 `load` 后立刻 `seek(to: position)`。
2. **降级要有退避**：第 2 次降级前等 500ms，第 3 次前等 1500ms，避免服务端被连击。
3. **降级结果要上报**（`POST /Sessions/Playing` 的 `PlayMethod` 字段：`DirectPlay` / `DirectStream` / `Transcode`），这样服务器端统计正确，用户也能在 Emby 面板看到"为什么在转码"。
4. **降级不可逆**：一旦降级到转码，本次会话就保持转码，不要"好了再切回直连"（会造成二次缓冲）。

---

## 7. 最小可运行验证方案（1 天 spike）

### 7.1 目标与非目标

**目标（必须验证）**
1. libmpv 能在 macOS 上打开 MKV 并解出正确的轨道信息
2. 外挂 ASS 能被加载、能被 libass 解析、样式覆盖选项生效
3. 多音轨能切换
4. Swift 6 严格并发下 wrapper 能编译通过

**非目标（本 spike 不做）**
- 窗口渲染（`vo=gpu-next` + MoltenVK）—— 风险最高，单独排期
- PiP / AirPlay / Now Playing
- Emby 网络集成（用本地文件）

### 7.2 已完成的验证结果（本机实测，2026-10-21）

**环境**：macOS 27.0 / Xcode 27.1 / Swift 6.4 / arm64
**依赖**：MPVKit `1.0.0`，29 个 xcframework 手动 `curl` 下载（**不走 SwiftPM，避免 git 凭据问题**）

**编译命令**（关键点：`-swift-version 6 -strict-concurrency=complete`）：

```bash
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -F vendor/Libmpv.xcframework/macos-arm64_x86_64 \
  -F vendor/Libass.xcframework/macos-arm64_x86_64 \
  # ... 其余 27 个 -F \
  spike_core.swift \
  -framework Libmpv -framework Libavcodec -framework Libavformat \
  # ... 其余 -framework \
  -framework Cocoa -framework IOKit -framework QuartzCore -framework CoreMedia \
  -framework AVFoundation -framework CoreFoundation -framework CoreAudio \
  -framework AudioUnit -framework AudioToolbox -framework OpenGL \
  -framework CoreVideo -framework VideoToolbox -framework Metal -framework CoreGraphics \
  -lz -lbz2 -liconv -lexpat -lxml2 -lresolv -lc++ -lm \
  -o spike_core
```

**编译结果：零 error、零 warning**（`exit=0`，输出为空）。

> 系统库清单不是猜的：`-l` 部分抄自 `libmpv-all.zip` 里的 `pkgconfig-example/macos/arm64/mpv.pc` 的 `Libs:` 行，加上 `Package.swift` 里 `_FFmpeg` target 的 `linkerSettings`。

**运行输出（节选，真实）：**

```
client_api=131077  (mpv 2.5 => 2*65536+5 = 131077)

[1] load MKV (H.264 + AAC)
    duration=6.023  time-pos=2.0
    track-list/count=2
      [0] type=video id=1 codec=h264 lang=- default=no
      [1] type=audio id=1 codec=aac lang=- default=no

[2] load MKV (HEVC Main10 + E-AC-3)
    duration=6.006  video-params/pixelformat=yuv420p10
    video-params/primaries=bt.709  hwdec-current=no
    track-list/count=2
      [0] type=video id=1 codec=hevc lang=- default=no
      [1] type=audio id=1 codec=eac3 lang=- default=no

[3] load MKV (2x AC-3) and switch audio track
    track-list/count=3
      [0] type=video id=1 codec=h264 lang=- default=no
      [1] type=audio id=1 codec=ac3 lang=eng default=yes
      [2] type=audio id=2 codec=ac3 lang=chi default=no
    audio track ids = [1, 2]
    after aid=2 -> aid=2  current-tracks/audio/lang=chi
    after aid=99 (bogus) -> aid=no  (expect 'no')

[4] external ASS subtitle
    sub-add rc=0
    sid=1  sub-visibility=yes  sub-delay=0.0
    after sub-delay=1.5 -> 1.5
    sub-ass-override=force
    sub-ass-style-overrides=FontName=PingFang SC,PrimaryColour=&H0000FFFF,Outline=2

[5] state properties
    pause = no
    speed = 1.000000
    volume = 100.000000
    mute = no
    eof-reached = no
    core-idle = no
    paused-for-cache = no
    cache-buffering-state = 100
    demuxer-cache-time = 4.000000
    seeking = no
    after speed=1.5 volume=70 -> speed=1.5 volume=70.0
    after seek 3.0 -> time-pos=3.875

[6] audio passthrough option
    audio-spdif=ac3,eac3,dts,dts-hd,truehd

[7] ytdl disabled check
    ytdl=yes          ← ⚠️ 默认是 yes，必须显式关掉
```

**结论：**

| 验证项 | 结果 |
|---|---|
| MKV 解封装 | ✅ |
| HEVC Main10 识别（`yuv420p10`） | ✅ |
| E-AC-3 / AC-3 识别 | ✅ |
| 多音轨切换 + 非法 id 回落 `no` | ✅ |
| 外挂 ASS 加载（`sub-add` rc=0） | ✅ |
| `sub-delay` 可写 | ✅ |
| `sub-ass-override` / `sub-ass-style-overrides` 被接受 | ✅ |
| `speed` / `volume` / `seek` / buffering 属性 | ✅ |
| `audio-spdif` 选项被接受 | ✅（**只证明选项存在，未证明 HDMI 真的直通**） |
| Swift 6 严格并发编译 | ✅ 零诊断 |

**两个意外发现（必须写进实现要求）：**

1. **`ytdl` 默认是 `yes`**。这意味着 libmpv 遇到未知 URL 可能尝试调用 youtube-dl 子进程。**必须显式 `mpv_set_option_string(h, "ytdl", "no")`**，否则是安全与性能双重隐患。
2. **`hwdec-current` 在 `vo=null` 下是 `no`**（因为没有视频输出，不解码）。这是预期行为，但也说明 **spike 没有验证硬件解码路径**。

### 7.3 已验证的 Swift 6 并发模型

```swift
final class MPVCore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.prism.mpv.core", qos: .userInitiated)
    nonisolated(unsafe) private var handle: OpaquePointer?

    // 不变式：handle 的每一次读写都发生在 queue 上。
    // deinit 也用 queue.sync 包裹，保证不与飞行中的调用竞争。
}
```

**为什么这个模型成立：**
- `mpv_handle*` 是 `OpaquePointer`（非 `Sendable`），Swift 6 会拒绝跨隔离域传递。
- `nonisolated(unsafe)` 是**显式**的逃逸口，配合 `@unchecked Sendable` + 文档化的不变式，是 Swift 6 下包装 C 句柄的标准做法。
- **不要**用 `actor`：mpv 的回调（`mpv_set_wakeup_callback`）来自内部线程，无法 `await` 进 actor，会造成死锁。

### 7.4 1 天 spike 的排期

| 时段 | 任务 | 产出 |
|---|---|---|
| 0–2h | 环境：`curl` 拉 29 个 xcframework 到 `.spike/mpv/vendor/`（**不用 SwiftPM**）；写 `MPVCore`；`swiftc` 编过 | 能 `mpv_create` + `mpv_initialize` |
| 2–4h | 加载 MKV，打印 `track-list`；验证音轨切换 | §7.2 的 [1][3] |
| 4–5h | 外挂 ASS：`sub-add` + `sub-ass-override` + `sub-delay` | §7.2 的 [4] |
| 5–8h | **渲染**：`wid` + `CAMetalLayer` + `gpu-next/moltenvk`，在 `NSViewRepresentable` 里出画面 | 一个能显示 MKV 画面的 SwiftUI 视图 |

> **风险提示**：前 5 小时的部分我已经跑通（§7.2），真正的未知在 5–8h 的渲染段。**如果渲染段 3 小时搞不定，立刻降级到 render API 方案，或直接放弃 mpv 路线**（回到 §4.3 的推翻条件）。

### 7.5 渲染段代码骨架（未验证部分）

```swift
import SwiftUI
import AppKit
import Libmpv

final class MPVMetalView: NSView {
    private let metalLayer = PrismMetalLayer()
    private var core: MPVCore?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        updateDrawableSize()
        if core == nil { core = MPVCore(layer: metalLayer) }
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.screen?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale,
                                         height: bounds.height * scale)
    }
}

struct MPVPlayerSurface: NSViewRepresentable {
    let core: MPVCore
    func makeNSView(context: Context) -> MPVMetalView { MPVMetalView(frame: .zero) }
    func updateNSView(_ nsView: MPVMetalView, context: Context) {}
}
```

`MPVCore` 的渲染相关初始化（**顺序关键**）：

```swift
init(layer: CAMetalLayer) {
    queue.sync {
        guard let h = mpv_create() else { return }
        // 1) 先给 wid（必须是 NSView 或 CALayer 的指针）
        var ptr = layer
        mpv_set_option(h, "wid", MPV_FORMAT_INT64, &ptr)
        // 2) 再设 VO 相关选项，全部在 initialize 之前
        mpv_set_option_string(h, "vo", "gpu-next")
        mpv_set_option_string(h, "gpu-api", "vulkan")
        mpv_set_option_string(h, "gpu-context", "moltenvk")
        mpv_set_option_string(h, "hwdec", "videotoolbox")
        mpv_set_option_string(h, "ytdl", "no")          // ← 必须，默认是 yes
        mpv_set_option_string(h, "config", "no")        // 不读用户 ~/.config/mpv
        mpv_set_option_string(h, "terminal", "no")
        mpv_set_option_string(h, "input-media-keys", "yes")   // 媒体键
        mpv_set_option_string(h, "subs-match-os-language", "yes")
        mpv_set_option_string(h, "subs-fallback", "yes")
        // 3) initialize
        mpv_initialize(h)
        // 4) 注册事件回调（必须在 initialize 之后）
        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVCore>.fromOpaque(ctx).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
        handle = h
    }
}
```

> ⚠️ Demo 里 `target-colorspace-hint`（HDR 输出）是注释掉的，且注释写明「**不支持运行时修改，必须在 init 时设，否则会卡顿/挂起**」。我们若要 HDR，必须在 `mpv_initialize` 之前决定，不能做成运行时可切换的开关。

### 7.6 渲染段的验证清单（给执行者）

跑通后请逐条确认：

- [ ] 窗口能显示 MKV 画面，不闪烁（闪烁 = `drawableSize` workaround 没生效）
- [ ] 窗口 resize 时画面跟随，不变形、不模糊（`drawableSize` 要乘 `backingScaleFactor`）
- [ ] 全屏切换正常
- [ ] `hwdec-current` 显示 `videotoolbox`（证明硬件解码生效）
- [ ] 4K HEVC 能流畅播放（证明性能可接受）
- [ ] 外挂 ASS 的字幕**画在视频上**（不是单独的 NSView 叠加层）
- [ ] HDR 内容在 HDR 屏上不过曝（`target-colorspace-hint` + `wantsExtendedDynamicRangeContent`）
- [ ] 关闭窗口后无泄漏（`mpv_terminate_destroy` 被调用）

---

## 8. 风险登记

| ID | 风险 | 等级 | 影响 | 缓解 |
|---|---|---|---|---|
| **R1** | **LGPL-3.0 + 静态链接 → 只能走 4d0（分发 .o）**，App Store 分发极其别扭 | 🔴 高 | 可能无法上架，或需要公开目标文件 | 决策备忘 A/B/C 三方案；**首选 A（附 .o）**，次选 B（自建 dylib，把 MPVKit 的静态库重新链接成动态库），最后 C（换 VLCKit/AetherEngine） |
| **R2** | **MPVKit 维护不活跃**，作者明示「不会频繁维护」并建议生产环境用 AetherEngine | 🔴 高 | 上游停更 → 无法跟进 mpv/FFmpeg 安全修复 | ① 锁版本 `1.0.0`；② 把「自建构建脚本」纳入预案（MPVKit 的 `Makefile` 开源，可自己编）；③ 抽象层保证可换引擎 |
| **R3** | **mpv 路径拿不到 AirPlay / PiP / 系统 HDR 握手**，造成 UX 不对称 | 🟠 中高 | 用户看 MKV 时不能 AirPlay 到电视、不能 PiP | ① UI 上明确标注能力（灰色禁用 + 说明）；② 提供「为此内容转码以获得 AirPlay」的显式选项；③ 长期看 AetherEngine 的 AVPlayer 路径能补上 |
| **R4** | **渲染段（`gpu-next` + MoltenVK + `wid`）未实测**，且 MPVKit README 自己说「Metal 支持只是 patch 版，遇到问题不奇怪」 | 🟠 中高 | 可能整体方案不可行 | spike 优先验证；Plan B 是 render API；Plan C 是放弃 mpv 回到服务端转码 |
| **R5** | **首次集成下载 350–380 MB / 29 个 binaryTarget**，CI 与新人上手成本高 | 🟡 中 | 构建慢、CI 缓存难做 | ① 用 `.spike/` 预下载 + 本地 `binaryTarget(path:)`；② CI 缓存 `SourcePackages`；③ 文档写明预期耗时 |
| **R6** | **Emby 服务端 fMP4 行为版本相关**，默认可能出 TS，导致 HEVC 被迫转码 | 🟡 中 | 降级路径可能失效 | 在 DeviceProfile 显式 `Container: mp4`；实测多版本；失败则回落到 libmpv 直连 |
| **R7** | **mpv `ytdl` 默认 `yes`**，未知 URL 可能拉起外部进程 | 🟡 中 | 安全 / 性能隐患 | 显式 `ytdl=no`（实测确认默认是 yes） |
| **R8** | **第三方二进制可能带 `--enable-nonfree`**（MPVKit 历史上出过，issue #77） | 🟡 中 | 产物「不可再分发」，许可证污染 | 每次升级后 `strings Libavcodec \| grep nonfree` 复核（`1.0.0` 已验证干净） |
| **R9** | **VLCKit TLS 1.3 缺失**（若最终换 VLCKit） | 🟡 中 | 部分 HTTPS 服务器连不上 | 换引擎时需评估；Emby 通常支持 TLS 1.2 |
| **R10** | **`wid` 嵌入在 SwiftUI 全屏/多窗口下可能不稳**（mpv 官方文档对 OSX window embedding 有保留） | 🟡 中 | 全屏、多窗口场景出问题 | spike 验证清单第 3 条；Plan B render API |

---

## 9. 来源与置信度

### 9.1 已核实（附 URL）

| # | 事实 | 来源 |
|---|---|---|
| V1 | AVFoundation 的 `AVURLAsset.audiovisualTypes()` 在 macOS 27.0 上返回 104 个 UTI，**不含 Matroska** | 本机实测（Swift 脚本） |
| V2 | 本地 `test.mkv`（H.264+AAC）用 `AVURLAsset.loadTracks` 抛 `Cannot Open`；`test_hevc_ac3.mp4` 正常，subtype 为 `hvc1` / `ac-3` | 本机实测 |
| V3 | HLS 规范：H.264 容器 MUST fMP4 或 TS（1.2）；**HEVC MUST fMP4（1.5）**；HDR HEVC MUST HDR10/HLG/DV（1.7）；DV MUST Profile 5（1.9）；`hvc1`/`dvh1` 优于 `hev1`/`dvhe`（1.10） | https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices |
| V4 | HLS 规范：支持的多声道音频仅 AC-3 / E-AC-3 / E-AC-3 JOC（2.5）；**字幕 MUST WebVTT 或 IMSC1（5.2）** | 同上 |
| V5 | MPVKit `1.0.0`：`swift-tools-version:5.9`、`platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .visionOS(.v1)]`、products 为 `MPVKit`(LGPL) / `MPVKit-GPL` | https://raw.githubusercontent.com/mpvkit/MPVKit/main/Package.swift |
| V6 | **LGPL 分支（`_FFmpeg`）依赖含 `Libass`/`Libfreetype`/`Libfribidi`/`Libharfbuzz`/`Libunibreak`；GPL 分支只多 `Libsmbclient`** | 同上 |
| V7 | `1.0.0` 内含 mpv v0.41.0 / FFmpeg n8.1.2 / libplacebo 7.360.1 / MoltenVK 1.4.2；`1.1.0-n9.0.2` 仅 FFmpeg n9.0.1→n9.0.2 | GitHub Releases API |
| V8 | `1.0.0` 的 `prerelease=false`；`1.1.0-n9.0.2` 的 `prerelease=true` | GitHub Releases API |
| V9 | MPVKit README 原文：「MPVKit is only suitable for learning libmpv and will not be maintained too frequently.」 | https://github.com/mpvkit/MPVKit |
| V10 | MPVKit issue #77 / PR #78：LGPL 版曾带 `--enable-nonfree`，2026-07-11 修复 | https://github.com/mpvkit/MPVKit/issues/77 · /pull/78 |
| V11 | MPVKit 产物是**静态库**（`current ar archive`，`otool -hv` → `filetype OBJECT`） | 本机实测 `file` / `otool` |
| V12 | `1.0.0` 的 Libavcodec 只含 `libavcodec license: LGPL version 3 or later`，无 nonfree 字样 | 本机实测 `strings` |
| V13 | MPVKit release 共 36 个 asset，其中 8 个是 `*-all.zip` 汇总包（SPM 不下载） | GitHub Releases API |
| V14 | 29 个非 GPL xcframework 下载约 350–380 MB；arm64 macOS slice 未压缩合计 **≈ 67.6 MB**（Libshaderc 15.7 / Libavcodec 9.8 / Libcrypto 8.7 / Libmpv 6.0 …） | 本机实测：curl 下载 + 解压 + `lipo -thin arm64` + `stat` |
| V15 | `mpv_client_api_version()` 返回 `131077`（= mpv 2.5） | 本机实测 |
| V16 | **`-swift-version 6 -strict-concurrency=complete` 下 wrapper 编译零诊断** | 本机实测 swiftc |
| V17 | 实测通过：MKV 解封装、HEVC Main10（`yuv420p10`）、E-AC-3、双音轨切换、非法 aid 回落 `no`、`sub-add` rc=0、`sub-delay` 可写、`sub-ass-override`/`sub-ass-style-overrides` 接受、`speed`/`volume`/`seek`/`paused-for-cache`/`cache-buffering-state` 可用、`audio-spdif` 接受 | 本机实测运行 |
| V18 | **mpv `ytdl` 默认值为 `yes`** | 本机实测（读取属性） |
| V19 | mpv 命令/属性名：`sub-add <url> [flags] [title] [lang]`、`sub-delay`、`sid`/`aid`/`vid`、`track-list/N/{type,id,codec,lang,default}`、`time-pos`、`duration`、`paused-for-cache`、`cache-buffering-state`、`eof-reached`、`core-idle`、`demuxer-cache-time`、`seeking` | https://raw.githubusercontent.com/mpv-player/mpv/master/DOCS/man/input.rst |
| V20 | mpv 选项名：`sub-ass-override=<no\|yes\|scale\|force\|strip>`、`sub-ass-style-overrides`、`sub-outline-size`（`sub-border-size` 为别名）、`sub-back-color`、`sub-align-y`、`sub-margin-y`、`audio-spdif`（支持 ac3/dts/dts-hd/eac3/truehd/dsd）、`hwdec=videotoolbox` 需 `vo=gpu/gpu-next` 或 `vo=libmpv` | https://raw.githubusercontent.com/mpv-player/mpv/master/DOCS/man/options.rst |
| V21 | macOS 上 libmpv 的 `wid` 被解释为 `NSView*`，且注明 "Setting vo=libmpv" 是唯一受支持方式 | https://github.com/mpv-player/mpv/commit/6fbd93b38f653bdd6ca765a85cecb3a6ba9ee3da |
| V22 | mpv 官方 examples：「using the render API is currently recommended over window embedding」（理由：OSX window embedding 有稳定性问题） | https://github.com/mpv-player/mpv-examples/blob/master/libmpv/README.md |
| V23 | MPVKit macOS Demo 用 `wid` 传 `CAMetalLayer`，配 `vo=gpu-next`/`gpu-api=vulkan`/`gpu-context=moltenvk`/`hwdec=videotoolbox`；`MetalLayer.swift` 含两个 workaround | https://raw.githubusercontent.com/mpvkit/MPVKit/main/Demo/Demo-macOS/Demo-macOS/Player/Metal/MPVMetalViewController.swift · .../Metal/MetalLayer.swift |
| V24 | VLCKit 官方仓库**自带 `Package.swift`**，platforms iOS 12 / macOS 10.13 / tvOS 12 / watchOS 7.4 / visionOS 1，单一 `binaryTarget` | https://code.videolan.org/videolan/VLCKit/-/raw/master/Package.swift |
| V25 | VLCKit 4.0 NEWS：「**removed support to compile VLCKit as a static framework**」「switched to dynamic instead of static frameworks」「added support for Picture-in-Picture playback on iOS and macOS」「support for two subtitles tracks」 | https://code.videolan.org/videolan/VLCKit/-/raw/master/NEWS |
| V26 | VLCKit 许可证 LGPL-2.1-or-later | 仓库 README / COPYING |
| V27 | VLCKit 最新 tag `4.0.0-a25`（2026-09-30）、`3.7.4`（同日） | GitLab API |
| V28 | VLCKit 4.0 SPM 包 zip 体积 **922,611,306 字节（≈ 922 MB）** | 本机 `curl -I` 实测 |
| V29 | LGPL-3.0 §4 原文：4d0 = 提供 Minimal Corresponding Source + 可重链接的应用代码；4d1 = 使用「运行时使用用户机器上已有副本」的共享库机制 | https://www.gnu.org/licenses/lgpl-3.0.txt |
| V30 | Emby `master.m3u8` 参数：`Container`/`AudioCodec`/`VideoCodec`/`VideoBitRate`/`AudioBitRate`/`MaxWidth`/`MaxHeight`/`MaxAudioChannels`/`AudioSampleRate`/`VideoStreamIndex`/`AudioStreamIndex`/`SubtitleStreamIndex`/`SubtitleMethod`/`MaxVideoBitDepth`/`StartTimeTicks`/`Static`/`EnableAutoStreamCopy`/`CopyTimestamps` | https://dev.emby.media/reference/RestAPI/DynamicHlsService/getVideosByIdMasterM3u8.html |
| V31 | Emby `TranscodingProfile` 字段含 `Container`/`VideoCodec`/`AudioCodec`/`Protocol`/`SegmentLength`/`MinSegments`/`BreakOnNonKeyFrames`/`EnableMpegtsM2TsMode`/`CopyTimestamps`/`MaxAudioChannels`/`ManifestSubtitles` | https://dev.emby.media/reference/RestAPI/SessionsService/postSessionsCapabilitiesFull.html |
| V32 | Emby `SubtitleDeliveryMethod` 枚举 = `Encode`/`Embed`/`External`/`Hls`/`VideoSideData` | 同上 |
| V33 | Emby `MediaSourceInfo` 含 `SupportsDirectPlay`/`SupportsDirectStream`/`SupportsTranscoding`/`TranscodingUrl`/`TranscodingContainer`/`TranscodingSubProtocol` | 同上 |
| V34 | FFmpegKit 于 **2025-01-06 正式退役**，二进制按计划移除 | https://github.com/arthenica/ffmpeg-kit |
| V35 | KSPlayer 默认 GPL，LGPL 版需付费；GPL 版阉割 AV1 硬解、全部解码器、PiP 字幕等 | https://github.com/kingslay/KSPlayer |
| V36 | AetherEngine：LGPL-3.0 **+ App Store/DRM Exception**；platforms iOS 18/tvOS 18/macOS 15/visionOS 1；swift-tools 6.1；架构为「FFmpeg demux → HLS-fMP4 给 AVPlayer / 或 AVSampleBufferDisplayLayer」 | https://raw.githubusercontent.com/superuser404notfound/AetherEngine/main/LICENSE · /Package.swift · /docs/architecture.md |
| V37 | `AVPictureInPictureController` macOS 10.15+；`ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` macOS 12+；`AVSampleBufferAudioRenderer` macOS 10.13+ | Apple 文档（`.md` 端点，含 availability 元数据） |
| V38 | `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` macOS 10.12.2+ | Apple 文档 |
| V39 | `AVPlayer.allowsExternalPlayback` macOS 10.11+ | Apple 文档 |
| V40 | Swiftfin 官方播放器对比：Native(AVPlayer) 对 **MKV ❌ / DTS ❌ / DTS-HD ❌ / TrueHD ❌ / ASS ❌**；VLC 对 PiP ❌、AirPlay 音频有延迟 bug、TLS 1.3 不支持 | https://github.com/jellyfin/Swiftfin/blob/main/Documentation/players.md |
| V41 | Apple TV 4K 官方规格音频列表：AC-3 / E-AC-3 / Atmos / AAC / ALAC / FLAC，**无 DTS** | https://www.apple.com/apple-tv-4k/specs/ |
| V42 | Emby 社区实证：HLS 默认输出 TS；TranscodingProfile 设 `Container: mp4` 后（Emby 4.9.5.0）产出 `#EXT-X-MAP` + `.mp4` 分片；HEVC 需 `-tag:v hvc1` | https://emby.media/community/topic/149003-hls-transcoding-for-apples-native-player-fmp4-segments-and-an-hdr-sdr-variant-pair |
| V43 | VLC 许可证历史：2011 年初因 GPLv2 与 App Store 冲突被下架；2011-10 引擎改为 LGPLv2+；2013-07 以 MPL-2.0 重新上架 | Wikipedia「Software relicensing」「VLC media player」 |

### 9.2 待验证（有依据但未实测，或需在真实环境确认）

| # | 事项 | 为什么没确认 | 怎么验证 |
|---|---|---|---|
| T1 | **mpv 渲染到 `CAMetalLayer` 在 macOS 15/26/27 上是否稳定** | 离屏 `vo=image` 未能写出帧（原因未查明），没有窗口环境跑 `gpu-next` | §7.6 清单逐条 |
| T2 | `vo=image` 为何不写帧 | 已确认 `image` 驱动被编进 libmpv（`strings` 有），但运行时 0 文件；未进一步排查 | 用 `msg-level=all=v` 抓 mpv 日志，看 VO 初始化是否失败 |
| T3 | **HDR / Dolby Vision 在 mpv 路径的实际表现** | 需要 HDR 显示器 + HDR 素材 + `target-colorspace-hint` | 用 HDR10 样片在 XDR 屏上看是否过曝/发灰 |
| T4 | **`audio-spdif` 是否真的直通到 HDMI 接收机** | 只验证了「选项被接受」，没有接收机 | 接 AVR，看面板是否显示 Dolby/DTS；或 `mpv --audio-device=help` 核对 |
| T5 | Emby 各版本 fMP4 输出行为 | 只有社区单点实证（4.9.5.0） | 用 fixture 或真实服务器，抓 `master.m3u8` 看有无 `#EXT-X-MAP` |
| T6 | AetherEngine 实际可用性与性能 | 只读了文档，未集成 | 单独 spike（半天） |
| T7 | VLCKit 在 .app 里的实际体积增量 | 只测了 922 MB 下载包，未做 thin + 打包 | 集成后看 `.app` 大小 |
| T8 | Xcode dead-strip 对 67.6 MB 的实际削减 | 未做 release 构建对比 | Release 构建后 `du -sh Prism.app` |
| T9 | mpv 路径下 PiP 是否真的完全不可能 | 基于「mpv 渲染到 CAMetalLayer，非 AVSampleBufferDisplayLayer」的推断 | 尝试 streamyfin 的 `vo_avfoundation` fork（仅 iOS）或 render API 方案 |
| T10 | `1.1.0-n9.0.2`（FFmpeg n9）是否有我们关心的修复 | 只看了 release notes，未读 n9 changelog | 读 FFmpeg n9 Changelog 的 demuxer/decoder 段 |

### 9.3 无法确认 / 明确未查到

| # | 事项 | 说明 |
|---|---|---|
| U1 | **FSF 对「GPL/LGPL + App Store」的官方立场** | 抓取 `gnu.org/licenses/gpl-faq.html` 全文，搜 `App Store`/`iTunes`/`Apple`/`iPhone`，**命中数均为 0**。**FSF 没有专门条目**。任何「FSF 说……」的表述都是二手转述，本文不采用。 |
| U2 | **MPVKit 官方对 Swift 6 并发的支持声明** | GitHub 搜 `Sendable`/`concurrency` → **0 条**；搜 `swift 6` → 1 条无关 issue。**没有任何官方或社区记录**。本文的结论来自我自己的编译实测（V16），不是文档。 |
| U3 | **MPVKit 实际集成后的 .app 体积增量** | 没有任何 issue / 讨论 / 文档给出过这个数字。本文给的 67.6 MB 是**我自己 `lipo -thin` 后逐框架 stat 的结果**，不是项目方数据，也不等于最终 .app 增量。 |
| U4 | **mpv 路径的功耗数据** | 没有任何可引用的测量。本文只说「比 AVPlayer 重」，**不给具体数字**。 |
| U5 | **`vo=image` 失效的确切原因** | 未查明。可能是该构建的 image VO 依赖某个未链接的组件，或需要不同的选项组合。 |
| U6 | **Emby 是否会为 `SubtitleMethod=External` 的 ASS 提供独立字幕 URL** | 文档只列了枚举值，未说明各 method 的 URL 形态。需实测 `/Videos/{id}/{mediaSourceId}/Subtitles/{index}/Stream.ass`。 |

---

## 10. 附录：给实现者的检查清单

### 10.1 集成 MPVKit 时

- [ ] 锁 `exact: "1.0.0"`（非 prerelease）
- [ ] `strings Libavcodec | grep -i nonfree` → **必须无输出**
- [ ] `mpv_set_option_string(h, "ytdl", "no")` —— 默认是 `yes`
- [ ] `mpv_set_option_string(h, "config", "no")` —— 不读用户 `~/.config/mpv`
- [ ] 所有 mpv 选项在 `mpv_initialize` **之前**设置
- [ ] `wid` 传 `CAMetalLayer`，且 `MetalLayer` 的两个 workaround 必须抄
- [ ] `mpv_terminate_destroy` 在 `deinit` 的 `queue.sync` 里调用
- [ ] 首次构建预留 350–380 MB 下载

### 10.2 抽象层验收

- [ ] `grep -rl "import Libmpv" --include="*.swift" . | grep -v MPVCore.swift` → 无输出
- [ ] `PlaybackEngine` 协议签名中无 `OpaquePointer` / `mpv_*`
- [ ] `PlaybackState` / `MediaTrack` / `PlaybackEvent` 全部 `Sendable`
- [ ] `EngineSelector` 是纯函数，可单测（无 I/O）
- [ ] 引擎切换时 `position` 被保留并 seek 回去

### 10.3 降级路径验收

- [ ] MKV + DTS 文件能直连播放（不触发服务器转码）
- [ ] 手动制造 AVPlayer 失败，能自动切 libmpv 且位置不丢
- [ ] 制造 libmpv 失败，能降级到 HLS 转码
- [ ] 连续 3 次失败后停在 `.failed`，不无限重试
- [ ] `POST /Sessions/Playing` 的 `PlayMethod` 与实际路径一致
