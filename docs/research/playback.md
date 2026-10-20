# Prism 播放引擎技术选型与落地方案

> 文档版本：2026-10-21（rev.3，**引擎首选已变更**）｜ 作者：播放引擎架构师（代理）
> 适用代码基线：SwiftUI 原生 macOS，Xcode 27.1 / Swift 6.4 / 部署目标 macOS 15+
> 本文所有技术断言都带置信度标记，见 §9「来源与置信度」。**请先读 §0.3 再读其它章节。**

---

## 0. 结论先行

### 0.1 一句话结论

**首选 AetherEngine 单引擎；MPVKit（libmpv）降为 Plan B。**

AetherEngine 内部已经实现了「FFmpeg demux + 重封装成 HLS-fMP4 交给 AVPlayer / 或 libavcodec 软解」的双路径，**它把我们要做的双引擎封装在了一个 Swift 包内部**。这样我们既拿到格式广度，又保住 macOS 原生能力（AirPlay / PiP / Dolby Vision / Atmos / Now Playing），还避免了 `OpaquePointer` 隔离层和 LGPL 静态链接问题。

> **变更说明（rev.2 → rev.3）**：rev.2 的结论是「AVPlayer + libmpv 双引擎」。变更原因有两个，均为主管侧决策输入：① **用户已决定开源 Prism**，LGPL 静态链接的分发义务不再构成障碍；② 核实了 AetherEngine 的实际情况（见 §2.4），它在**几乎每个维度**都优于或等于 MPVKit，且没有 mpv 的 UX 硬伤。
>
> 本文保留 MPVKit 的完整核查记录（§2.1、附录 A），因为它是 Plan B，且部分事实（AVFoundation 边界、HLS 规范、Emby 参数）与引擎选型无关，仍然有效。

### 0.2 六条最重要的判断

| # | 判断 | 依据强度 |
|---|---|---|
| 1 | AVFoundation **完全不认 MKV**，且**不认 DTS/TrueHD**，这不是配置问题而是能力边界 | 本机实测 + Apple 官方格式列表 |
| 2 | HLS 路线救不了 DTS/TrueHD，也救不了 ASS/PGS（HLS 字幕只允许 WebVTT/IMSC1） | Apple HLS Authoring Spec 原文 |
| 3 | **AetherEngine 用「FFmpeg demux → HLS-fMP4 → AVPlayer」解决了 MKV 与 DTS 问题**，同时保留系统 DV/Atmos/Match Content | 官方 README + architecture.md 原文 |
| 4 | **AetherEngine 是纯 Swift 源码包**，无 `OpaquePointer` 隔离层，API 与我们的 `PlaybackEngine` 协议高度同构 | `Package.swift` + README API 段原文 |
| 5 | AetherEngine 的许可证是 **LGPL-3.0 + App Store/DRM 例外**；Prism 开源后 LGPL 义务天然满足 | LICENSE 原文 |
| 6 | mpv 路径**拿不到 AirPlay、PiP、系统 HDR/DV 握手**——这是 MPVKit 降为 Plan B 的决定性理由 | Apple 文档 + mpv 架构事实 |

### 0.3 阅读前必须知道的三件事

1. **AetherEngine 与 MPVKit 都尚未集成进 Prism 工程，两者状态均为【未集成 · 未实测】。**
   - AetherEngine：本文所有结论来自**官方 README / Package.swift / docs/api.md / docs/architecture.md 原文**，没有一行是跑出来的。**它有一个明确的集成前提**：要求 macOS 15.0 / Swift 6.4 / Xcode 27.0 / **至少 26.2 SDK**（因 `VTRegisterSupplementalVideoDecoderIfAvailable` 是 iOS/tvOS 26.2 API）。我们的环境是 Xcode 27.1 / Swift 6.4，**满足**，但需实测确认。
   - MPVKit：§7.2 记录的是**一次性、离线的验证性实验**（手工 `swiftc` 链接 29 个 xcframework）。该实验产物已清理，**任何人无法复现**，证据等级是「参考」而非「基线」。且该实验**没有验证窗口渲染**。
2. **许可证风险已大幅降低，但未归零。** Prism 开源后，LGPL 的「提供源码/可重链接」义务通过「Prism 自身源码公开」自然满足。但仍有两条要注意：① AetherEngine 的 App Store 例外**只覆盖它自己的代码，不覆盖其依赖**（README 明示）；② 它的 FFmpeg 以**动态框架**形式分发（FFmpegBuild，LGPL-2.1），这条路径本来就合规。详见 §3.4。
3. **本文与 `docs/DECISION-mpv-license.md` 的关系已变化**：那份备忘是在「闭源 + MPVKit 静态库」前提下写的，**其结论（A/B/C 三方案）在开源 + AetherEngine 之后已基本失效**，仅作历史记录保留。若两者冲突，**以本文为准**。

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

> ⚠️ 这是**社区实证**，不同 Emby 版本行为可能不同。**必须在真实服务器上验证**（§9.2 T5 给了验证方法）。

---

## 2. 候选引擎逐个核实

### 2.1 MPVKit（`github.com/mpvkit/MPVKit`）—— **Plan B**

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

#### 2.1.3 包体积（一次性离线测量，产物已清理）

测量方法：从 `1.0.0` release 用 `curl` 逐个下载 29 个 xcframework → 解压 → `lipo -thin arm64` → 逐框架 `stat`。**该测量不可复现（产物已清理），数字按「参考值」使用。**

**下载量（仅一次性获取时需要；vendoring 后不再需要）：**

| 口径 | 数值 | 说明 |
|---|---|---|
| 单个 repo 的非 GPL `*.xcframework.zip` | ~217 MB | 只算 `MPVKit` 仓库自身的 asset |
| **全部非 GPL binaryTarget（含跨 repo）** | **~350–380 MB** | 会去 13 个不同 repo 下载 |
| release 的 36 个 asset 总量 | 449 MB | **这个数字没有意义**——含 8 个 `*-all.zip` 汇总包，用不上 |

> ⚠️ 早期估算 217 MB **偏低**，因为漏算了跨 repo 的 13 个 binaryTarget（openssl-build / gnutls-build / libass-build / libbluray-build / moltenvk-build / libshaderc-build / lcms2-build / libplacebo-build / libdovi-build / libdav1d-build / libuavs3d-build / libuchardet-build / libluajit-build）。
>
> 📌 **采用 附录 A vendoring 后，这个下载成本只发生一次**（由有网络的环境执行并 commit），日常构建与 CI 完全不再下载。

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

#### 2.1.6 Swift 6 严格并发——**文档查不到，仅有一次离线实验观察**

这是本任务里唯一「查不到文档、只能靠实验」的点。

- GitHub 搜索 `repo:mpvkit/MPVKit` + `Sendable` / `concurrency`：**total_count = 0**。
- 搜 `swift 6`：仅 1 条无关 issue。
- 即：**MPVKit 官方从未声明 Swift 6 并发适配，社区也无已知问题记录。这是「未查到」，不是「没问题」。**

在 2026-10-21 的一次离线实验中（§7.2，产物已清理、**不可复现**），一个符合「单串行队列 + `nonisolated(unsafe)`」模型的 wrapper 在 `-swift-version 6 -strict-concurrency=complete` 下编译无诊断。**该结果只作参考，需在工程内重验。**

从原理上推断（**推断，非事实**）：MPVKit 的 Swift 表面为零（`Sources/_MPVKit/` 只有 `dummy.c` + `include/`），Swift 6 的严格并发检查**没有库内 Swift 代码可检查**，只作用于我们的 wrapper。`mpv_handle*` 是 `OpaquePointer`（非 Sendable），必须由我们自己做隔离。这也是 §5.1「零泄漏」约束的技术根因。

### 2.2 VLCKit（`code.videolan.org/videolan/VLCKit`）—— Plan C

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

### 2.4 AetherEngine（`github.com/superuser404notfound/AetherEngine`）—— **首选**

> 本节事实来自：官方 README、`Package.swift`、`docs/api.md`、`docs/architecture.md`、`LICENSE`、GitHub API。**全部为文档层核实，未集成、未实测。**

#### 2.4.1 事实清单

| 项 | 值 | 来源 |
|---|---|---|
| 仓库 | `superuser404notfound/AetherEngine`（**不是** `AetherEngine/AetherEngine`） | GitHub API |
| 最新 release | **`7.44.0`**，2026-10-20 发布，**prerelease=false** | Releases API |
| 活跃度 | 最后推送 2026-10-20（与 release 同日）；**265 stars**；87 open issues | GitHub API |
| 许可证 | **LGPL-3.0 + Apple Store / DRM Exception**（GitHub 标 `NOASSERTION`，因是自定义组合许可证） | LICENSE 原文 |
| platforms | iOS 18.0 / tvOS 18.0 / **macOS 15.0** / visionOS 1.0 | README Requirements |
| 工具链要求 | **Swift 6.4 / Xcode 27.0**；源码至少需要 **26.2 SDK** | README Requirements |
| `swift-tools-version` | 6.1 | `Package.swift` |
| 形态 | **纯 Swift 源码包**（`.target`，非 `binaryTarget`） | `Package.swift` |
| 依赖 | `FFmpegBuild`(≥3.9.0)、`SMBClient`(≥0.3.1)、`LibDovi`(≥2.1.0)、`LibTrueHD`(≥3.0.0，仅 trait 开启时) | `Package.swift` |
| FFmpeg 形态 | **动态框架**（dylib-in-framework，`@rpath`），LGPL-2.1-or-later | FFmpegBuild README |
| FFmpeg 体积 | macOS universal（arm64+x86_64）**约 22.7 MB**；iOS/tvOS arm64 约 10.5 MB | FFmpegBuild README「Size」表 |
| 落地案例 | Sodalite（Jellyfin/Apple TV）、AetherPlayer（macOS）、Silo、Moonfin、Vivid、LillyPlayer 等 **17 个** | README「Used by」 |

#### 2.4.2 架构：它内部就是「双引擎」

`docs/architecture.md` 原文把两条路径写得很清楚：

**(a) Native AVPlayer pipeline（默认）**
> Demux the source with libavformat, re-mux the elementary streams on the fly into HLS-fMP4, serve them from a local HTTP server on an ephemeral port ... point `AVPlayer` at the playlist. Apple's stack does all decode, all HDR / Dolby Vision signaling over HDMI, all audio routing.

关键细节（原文）：
- 本地 HTTP 服务器监听**所有网卡**（不是只 127.0.0.1），以便 **AirPlay 接收机能通过局域网访问**；带 per-session path token、32 连接上限（非回环 24）、10 秒头部超时。
- 选 HLS-fMP4 而不是直接喂源 URL 的理由：「AVPlayer's progressive-download path won't accept arbitrary MKV containers, and even for MP4 sources it's brittle around Dolby Vision sample-description quirks and EAC3 `dec3` box variants.」

**(b) Software path**
> Demux the source, run video packets through libavcodec (dav1d for AV1, FFmpeg's native decoder for VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1) into `CVPixelBuffer`s, run audio through libavcodec into `CMSampleBuffer`s, render via `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` with `AVSampleBufferRenderSynchronizer` as the master clock.

用于 AVPlayer 的 HLS-fMP4 管线不接受的编码：AV1（无硬解时）、VP9/VP8、MPEG-4 Part 2、MPEG-2、VC-1、**隔行 H.264**（AVPlayer 不反交错）。

**对我们最重要的一点**：视图是**多态的**（README 原文）：
> The view is polymorphic: under the hood the engine swaps the hosted CALayer (`AVPlayerLayer` for the native AVPlayer path, `AVSampleBufferDisplayLayer` for the SW dav1d fallback path) per session without the host having to know.

也就是说，**我们不需要自己写两套画面输出层**——这正是 rev.2 双引擎方案里最麻烦的部分。

#### 2.4.3 格式覆盖（README 原文归纳）

| 类别 | 覆盖 |
|---|---|
| 容器 | MKV、MP4、WebM、MPEG-TS、AVI、ASF/WMV、OGG、FLV、RealMedia、3GP/3G2 |
| 光盘 | DVD-Video、Blu-ray ISO（已解密），可选 title/chapter |
| 视频（硬解） | H.264、HEVC、HEVC Main10（VideoToolbox）；AV1 Main（有硬件 AV1 时） |
| 视频（软解） | AV1（dav1d）、VP9/VP8、MPEG-4 Part 2、MPEG-2、VC-1、QuickTime RLE、Flash 系、RealVideo、H.263、Theora |
| HDR | HDR10、HDR10+（逐帧 ST 2094-40）、**Dolby Vision P5 / P7（8.1 或可选 FEL 双层）/ P8.1 / P8.4 / AV1 P10.x**、HLG、HDR Vivid |
| 音频 | AAC、AC3、EAC3、FLAC、ALAC（stream-copy 无损）；TrueHD/MLP、DTS、DTS-HD MA、MP3、Opus、Vorbis、LPCM、WMA、RealAudio、AMR 等 |
| Dolby Atmos | **EAC3+JOC 在所有路由上 stream-copy**（HDMI MAT 2.0 / AirPods 空间音频 / BT 降混）；TrueHD Atmos 与 DTS:X 可选 trait 渲染成 APAC |
| 字幕 | **文本（SRT / ASS / SSA / VTT / mov_text）inline**；**图形（PGS / DVB / DVD、VobSub）以 `CGImage` 输出**；CEA-608；DVB teletext；**外挂文件是一等 track** |
| PiP | **原生路径**：宿主可用 `currentAVPlayer` 或 `nativePlayerLayer` 建 `AVPictureInPictureController`；**软解路径**：`softwarePiPSource` 提供 `AVSampleBufferDisplayLayer`，且**在 PiP 窗口内合成字幕**（文本 + PGS/DVB 位图） |
| Now Playing | 原生视频路径可选 `ownsVideoNowPlayingSession`（`MPNowPlayingSession`）；音频路径无条件拥有 |
| 其它 | FrameExtractor（缩略图/截帧）、`installAudioTap()`、预热点 `prewarm`、直播+DVR、SMB、自定义 `IOReader`、自签证书 `serverTrustEvaluator` |

#### 2.4.4 它的「App Store Exception」到底写了什么

LICENSE 原文（我读了全文，这是核心段落）：

> As an additional permission under Section 7 of the GNU General Public License v3 ... the copyright holder grants permission to distribute, install, and use this Program — and any modified versions thereof — through application stores and beta-distribution platforms operated by third parties (including but not limited to the Apple App Store and Apple TestFlight), even where the platform's terms impose restrictions on: signing or re-signing of the binary ...; tamper protection, FairPlay-style DRM ...; end-user redistribution ...; end-user re-linking ...

**这条对我们已经不重要了**（Prism 开源后 LGPL 义务自然满足），但它说明**作者认真考虑过分发合规**，是个正面信号。

README 同时明确一条**重要限制**：
> The exception covers AetherEngine's own code; it does not extend to its dependencies.

即：例外**不覆盖** FFmpeg/LibDovi/LibTrueHD。但 FFmpeg 走的是 **FFmpegBuild 的动态框架**（LGPL-2.1），动态链接本来就满足 LGPL 的重链接要求，所以这条不构成障碍。FFmpegBuild README 原文：
> The shipped xcframeworks contain **dynamic frameworks** (dylib-in-framework, `@rpath` install names); Xcode embeds and signs them in the app bundle automatically when you link the package. **That is what keeps the LGPL relink requirement satisfiable for closed-source apps.**

#### 2.4.5 需要警惕的地方

| 项 | 说明 |
|---|---|
| **单人维护 + AI 辅助** | README 自述「vibe-coded ... in close pair-programming with Claude」，几乎每个 commit 带 `Co-Authored-By: Claude`。**这是真实的治理风险**，与 MPVKit 的「不常维护」是同一类问题，但至少它**活跃**（2026-10-20 还在发版）。 |
| **87 个 open issues** | 相对 265 stars 偏高，说明问题不少（也说明有人真的在用）。 |
| **工具链门槛硬** | 需要 Swift 6.4 / Xcode 27.0 / **26.2+ SDK**。我们是 Xcode 27.1 / Swift 6.4，满足；但 CI 镜像必须跟得上。 |
| **依赖链深** | 4 个直接依赖，其中 `FFmpegBuild` 又是 binaryTarget（9 个 xcframework，含 dSYM 约 45 MB）。**首次 clone/构建体积仍需实测**（未测）。 |
| **`traits` 在 XcodeGen 下不可用** | README 明说 XcodeGen 2.45.4 会**静默丢弃** `traits:`。我们工程用了 `project.yml`（XcodeGen），**若将来要开 TrueHD/DTS:X/DV-FEL 等 trait，必须手工 patch `.pbxproj` 或包一层本地 package**。 |
| **默认只 HEVC/H.264/AV1 走原生** | 其余全部软解。软解 4K 的功耗/发热需实测。README 给了 M1 的实测数据（38 Mbit/s 4K HDR10：GPU 41 mW、CPU 4.4% of a core），但那是**作者自己的 benchmark 工具**测的，需独立验证。 |

### 2.5 其它已排除的方案

| 方案 | 排除理由 |
|---|---|
| **FFmpegKit** | **2025-01-06 已停止维护**，二进制从仓库移除。作者官方公告。**不要用**。 |
| 纯 AVPlayer + 服务端全转码 | DTS 必须转音频；ASS/PGS 必须烧录；每次播放吃服务器 CPU。违背「原生客户端」价值主张。 |
| 自研 MKV demux + fMP4 mux（AetherEngine/PrismCore 路线） | 工程量约 2000 行 Swift，且仍需解决 DTS 解码。**长期正确但短期不现实**。 |
| QuickTime `QTMovieModernizer` | 只做格式现代化，不扩展解码能力。 |

---

## 3. 对比矩阵

### 3.1 主矩阵（四引擎全景）

图例：✅ 原生支持 ｜ 🟡 有条件/需额外工作 ｜ ❌ 不支持 ｜ ⬜ 不适用

| 维度 | AVPlayer（裸） | **AetherEngine** | libmpv / MPVKit | VLCKit 4 |
|---|---|---|---|---|
| **MKV 容器** | ❌ 实测 `Cannot Open` | ✅ | ✅ | ✅ |
| **HEVC / HEVC Main10** | ✅（需 `hvc1` tag） | ✅ VideoToolbox | ✅ VideoToolbox hwdec | ✅ |
| **DTS / DTS-HD** | ❌ 无解码器 | ✅ 解码；可选 bridge 成 EAC3 | ✅ 解码；可 `audio-spdif` 直通 | ✅ 解码 |
| **TrueHD / MLP** | ❌ | ✅ 解码；Atmos 对象需 `TrueHDObjectAudio` trait | ✅ 解码 | ✅ 解码 |
| **Atmos（EAC3+JOC）** | 🟡 仅经 HLS/MP4 的 E-AC-3 | ✅✅ **所有路由 stream-copy**（HDMI MAT 2.0 / 空间音频） | 🟡 无对象直通（mpv 官方对比表） | 🟡 解成 PCM，无对象直通 |
| **ASS / SSA** | ❌ HLS 只允许 WebVTT/IMSC1 | ✅ 文本 inline（`$subtitleCues` 的 `.richText` 带样式） | ✅ libass | ✅ libass |
| **PGS（图形字幕）** | ❌ | ✅ 以 `CGImage` 输出；PiP 内也合成 | ✅ | ✅ |
| **SRT** | 🟡 需转 WebVTT | ✅ 原生 | ✅ 原生 | ✅ |
| **HLS 直封** | ✅ 唯一原生消费者 | ✅✅ **自己产 HLS-fMP4**（内部实现） | 🟡 能播，但不用系统 HDR 通路 | 🟡 同左 |
| **字幕渲染质量** | ❌ 无 ASS | ✅ 良好（`.richText` 带颜色/粗斜体/字体/字号/对齐） | ✅✅ **最佳**（libass + libplacebo） | ✅ 良好 |
| **音频直通（HDMI/SPDIF）** | 🟡 仅 AC3/EAC3 经系统 | ✅ EAC3+JOC stream-copy；TrueHD/DTS 可桥接 | ✅ `audio-spdif=ac3,eac3,dts,dts-hd,truehd` | 🟡 有 passthrough 模块 |
| **HDR / 杜比视界** | ✅✅ 系统级握手 | ✅✅ **系统级**（DV P5/P7/P8.1/P8.4，Match Content） | 🟡 自 tone-map，**不走系统 DV 握手** | 🟡 自 tone-map，无 DV 显示 |
| **画中画** | ✅ AVPlayerLayer 最稳 | ✅ 原生路径用 `currentAVPlayer`/`nativePlayerLayer`；软解路径用 `softwarePiPSource` | ❌ **渲染到 CAMetalLayer，拿不到 PiP** | ✅ 4.0 支持（iOS+macOS） |
| **AirPlay** | ✅✅ 系统级 | ✅✅ 系统级（本地 HTTP 服务器监听全网卡专为此设计） | ❌ 不支持 | 🟡 音频有已知延迟 bug（VLCKit #544） |
| **Now Playing** | ✅ 自动 | ✅ `MPNowPlayingSession`（可选）或宿主自管 | 🟡 需手动填 `MPNowPlayingInfoCenter` | 🟡 同左 |
| **性能与功耗** | ✅✅ 最低 | 🟡 原生路径接近 AVPlayer；软解路径更重 | 🟡 软件栈重；Metal 支持是 patch | 🟡 中等 |
| **包体积增量** | **0** | 🟡 FFmpeg 动态框架 **macOS universal ≈ 22.7 MB**（+ 引擎自身，**未实测**） | 🟡 arm64 未压缩 **≈ 67.6 MB**（一次性实验） | 🟡 **922 MB 下载包**，.app 增量未测 |
| **Swift 互操作** | ✅ | ✅✅ **纯 Swift**，`async`/`await` + `@Published` | ❌ **C API**，需 `OpaquePointer` + 串行队列隔离层 | ❌ Objective-C，无 Sendable 标注 |
| **Swift 6 并发** | ✅ | 🟡 声明 Swift 6.4，**未实测**（可能需 `@preconcurrency` 包 Combine） | 🟡 C 表面，wrapper 自管（一次性实验零诊断，不可复现） | 🟡 需大量 `@preconcurrency` |
| **SPM 集成难度** | ⬜ 系统框架 | 🟡 一条 `.package`，但依赖链 4 层、含 binaryTarget；**`traits` 在 XcodeGen 下会被静默丢弃** | 🟡 建议 vendoring（附录 A）；走远程依赖会**触发钥匙串弹窗** | 🟡 一条 `.package`，但 **922 MB 单包** |
| **许可证** | 系统框架 | ✅ LGPL-3.0 + App Store 例外；FFmpeg 走**动态**框架（LGPL-2.1） | ⚠️ LGPL-3.0 + **静态库** → 闭源时只能走 4d0 | ✅ LGPL-2.1 + **动态**框架 → 4d1 可行 |
| **维护活跃度** | Apple 维护 | 🟡 **单人 + AI 辅助，但活跃**（2026-10-20 发版，265★） | ⚠️ **作者明示「不会频繁维护」** | ✅ VideoLAN 官方，月更 |

### 3.2 MPVKit vs AetherEngine 正面对比（决策依据）

这一节只比较两个**实际候选**，按「对 Prism 的重要性」排序。

| 维度 | MPVKit（libmpv） | AetherEngine | 胜者 |
|---|---|---|---|
| **容器/编码覆盖** | 极广（mpv 全家桶） | 极广（FFmpeg demux + 软解兜底） | **平**（都够用） |
| **ASS 渲染质量** | libass + libplacebo，可 shader 级 | 文本 cue 转 `.richText`（颜色/粗斜体/字体/字号/对齐） | **MPVKit 略优**（libass 原生排版更完整，尤其特效字幕） |
| **PGS** | ✅ 原生 | ✅ `CGImage`，且 PiP 内合成 | **平** |
| **PiP** | ❌ **不可能**（CAMetalLayer 渲染） | ✅ 原生 + 软解双路径 | **AetherEngine 决定性胜出** |
| **AirPlay** | ❌ **不支持** | ✅ 系统级（专为 AirPlay 设计了全网卡监听） | **AetherEngine 决定性胜出** |
| **Dolby Vision** | 🟡 自 tone-map，无系统 DV 握手 | ✅ P5/P7/P8.1/P8.4，真实显示器切换 | **AetherEngine 决定性胜出** |
| **Atmos** | 🟡 无对象直通 | ✅ EAC3+JOC 全路由 stream-copy | **AetherEngine 胜** |
| **HDR 在 macOS** | 🟡 `target-colorspace-hint` + EDR，需自己处理 | ✅ 走 AVPlayer 时系统级；`displayCapabilities` 有 macOS 适配 | **AetherEngine 胜** |
| **Swift 互操作** | ❌ C API + 隔离层 | ✅ 纯 Swift，`async`/`await` | **AetherEngine 决定性胜出** |
| **维护活跃度** | ⚠️ 作者明示不常维护 | 🟡 单人但活跃（发版次日仍在推） | **AetherEngine 胜** |
| **体积** | ≈ 67.6 MB（arm64，一次性实验） | ≈ 22.7 MB（FFmpeg macOS universal）+ 引擎 | **AetherEngine 胜**（约 1/3） |
| **许可证** | ⚠️ 静态库 + LGPL-3.0 | ✅ 动态 FFmpeg + App Store 例外 | **AetherEngine 胜** |
| **集成难度** | 🟡 需 vendoring 绕开钥匙串问题 | 🟡 一条 `.package`，但依赖链深、`traits` 与 XcodeGen 冲突 | **平** |
| **成熟度/案例** | 209★，130 fork | 265★，**17 个真实 App**（含 Jellyfin 客户端 Sodalite、macOS 播放器 AetherPlayer） | **AetherEngine 胜** |
| **风险** | 停更 + 无 AirPlay/PiP | 单人维护 + 87 open issues + 工具链门槛硬 | **各有风险** |

**结论：AetherEngine 在 9 个维度胜出，MPVKit 只在「ASS 渲染质量」上略优，其余持平。**

mpv 唯一不可替代的优势是 **libass 的排版完整度**（动漫特效字幕、复杂样式）。如果将来发现 AetherEngine 的 `.richText` 对某类 ASS 还原不够，可以**只对那类内容**降级到 MPVKit——但这属于 Plan B 的触发条件，不是默认路径。

### 3.3 单引擎可行性判断

| 方案 | 能否单引擎 | 致命缺口 |
|---|---|---|
| 纯 AVPlayer | ❌ | MKV 打不开、DTS 解不了、ASS 渲染不了。对 Emby 库等于废掉大半 |
| 纯 libmpv | 🟡 技术上可以 | **丢 AirPlay、丢 PiP、丢系统 HDR/DV 握手、丢自动 Now Playing**；且背 LGPL 静态链接问题 |
| 纯 VLCKit | 🟡 技术上可以 | 丢系统 HDR/DV 握手、AirPlay 音频有 bug、TLS 1.3 缺失、922 MB 包、200 MB 体积 |
| **纯 AetherEngine** | ✅ **可以，且是当前选择** | 未实测、单人维护、工具链门槛硬 |

**关键洞察**：没有任何单引擎能同时拿到「格式全覆盖」和「macOS 原生体验（AirPlay/PiP/HDR/Now Playing）」，因为这两组能力分属两个技术栈。**AetherEngine 的解法是在一个框架内部做双路径**——本质仍是双引擎，只是封装在第三方包内部，由它负责路由。这让「单引擎」在**我们这一层**成立。

rev.2 选择「自己实现双引擎」，是因为当时不知道 AetherEngine 已经把这个模式产品化了。

### 3.4 许可证：开源后义务已解除

#### 前提变更

**Prism 已决定开源。** 这一条改变了整个许可证分析的前提：LGPL 的核心义务是「让接收者能修改库并重新链接」，而**Prism 自身源码公开**天然满足了这一点。

#### 具体到各组件

| 组件 | 许可证 | 开源后是否有义务 | 说明 |
|---|---|---|---|
| **AetherEngine** | LGPL-3.0 + App Store 例外 | ✅ **已满足** | 我们修改引擎需同样以 LGPL 发布（README 原文：「Modifications to the engine itself still have to be released under LGPL」）。**只要我们不 fork 修改它，就无需额外动作**。 |
| **FFmpegBuild**（AetherEngine 依赖） | LGPL-2.1-or-later | ✅ **已满足** | 以**动态框架**分发（`@rpath`），本来就走 4d1；开源后更无争议。 |
| **LibDovi / LibTrueHD** | LGPL-3.0 / MIT+Apache-2.0 | ✅ **已满足** | LibTrueHD 的 Apache-2.0 部分要求携带 license 文本与 NOTICE（README 明示）。 |
| **MPVKit**（Plan B） | LGPL-3.0，**静态库** | ✅ **已满足** | 静态链接走 4d0（提供可重链接的目标文件）；**开源后源码本身就是对应源**。rev.2 里「必须分发 .o」的结论**已失效**。 |
| **VLCKit**（Plan C） | LGPL-2.1，动态框架 | ✅ 已满足 | — |

#### 仍然存在的注意事项（不要因为开源就完全放松）

1. **第三方专利**：AetherEngine 的 `TrueHDObjectAudio` / `DTSXObjectAudio` / `DualLayerDolbyVision` / `DolbyVisionStillReshaping` 四个 trait，README 原文：「These components may be subject to third-party patent licensing. Integrators who enable them are responsible for their own licensing.」——**默认全关，我们也建议保持关闭**。
2. **许可证文本要随分发附带**：LGPL 的 4a/4b/4c 义务（显著声明、附许可证副本、启动版权声明）**不会因开源消失**。要有一个「开源许可」页面列出 AetherEngine / FFmpeg / LibDovi / LibTrueHD 及其许可证全文。
3. **App Store 例外不覆盖依赖**：README 明说「The exception covers AetherEngine's own code; it does not extend to its dependencies.」——若将来要上架且启用 trait，需单独评估。
4. **我们不能闭源回去**：一旦用了 LGPL-3.0 的 AetherEngine 并分发，Prism 就必须保持开源（LGPL 允许闭源**应用**，但若我们修改引擎则修改部分需 LGPL；且 Prism 既然开源，这条不是问题）。**但要注意：如果将来 Prism 想闭源商业化，这条会成为障碍**——届时应选 VLCKit（LGPL-2.1 + 动态）而非 AetherEngine。

#### 历史记录（已失效，仅存档）

rev.2 曾基于「闭源 + MPVKit 静态库」推导出「只能走 LGPL-3.0 §4d0（随 App 分发 .o）」。该推导的**条款引用本身是正确的**（§4 原文 4d0/4d1 二选一），但**前提已不成立**。`docs/DECISION-mpv-license.md` 整份备忘基于旧前提，**结论作废**。

#### 我不能替你确认的部分

- FSF 官方 GPL FAQ 页面我抓取全文搜 `App Store` / `iTunes` / `Apple` / `iPhone`，**命中数均为 0**。**FSF 没有关于 App Store 的专门条目**，任何「FSF 说……」的说法都是二手转述，本文不采用。
- **本文不构成法律意见。** 开源发布前建议由懂开源合规的人过一遍 NOTICE/许可证清单。

---

## 4. 推荐方案

### 4.1 结论

**AetherEngine 单引擎，我们只做薄适配层。**

```
                    ┌──────────────────────────────────┐
                    │  PlaybackEngine（我们的协议）      │
                    │  引擎无关，纯 Swift，零泄漏        │
                    └──────────────┬───────────────────┘
                                   │
                    ┌──────────────▼───────────────────┐
                    │  AetherPlaybackEngine            │
                    │  （适配层：Combine → AsyncStream） │
                    └──────────────┬───────────────────┘
                                   │
                    ┌──────────────▼───────────────────┐
                    │  AetherEngine（第三方，LGPL-3.0）  │
                    │  ┌────────────┐  ┌────────────┐  │
                    │  │ Native     │  │ Software   │  │
                    │  │ AVPlayer   │  │ libavcodec │  │
                    │  │ HLS-fMP4   │  │ + ASBDL    │  │
                    │  └────────────┘  └────────────┘  │
                    └──────────────────────────────────┘
```

**我们不再自己实现双引擎。** AetherEngine 内部已经有「FFmpeg demux → HLS-fMP4 → AVPlayer」与「libavcodec 软解 → AVSampleBufferDisplayLayer」两条路径，并且**对宿主透明地按会话切换**（README 原文：视图多态，自动换 `AVPlayerLayer` / `AVSampleBufferDisplayLayer`）。

我们要写的只有一层**薄适配**：把它的 Combine `@Published` 桥成我们的 `AsyncStream`，把它的 `TrackInfo` 映射成我们的 `MediaTrack`。见 §4.4。

### 4.2 为什么推翻 rev.2 的「AVPlayer + libmpv 双引擎」

rev.2 的双引擎方案在技术上是成立的，但代价是：

1. **要自己写两套画面输出层**（`AVPlayerLayer` 一套、`CAMetalLayer` + `wid` 一套），且 mpv 那套**渲染从未跑通**（§7.2）。
2. **要自己维护 `OpaquePointer` 隔离层**（§5.1 的零泄漏约束），这是一整层样板代码。
3. **mpv 路径拿不到 AirPlay / PiP / 系统 DV 握手**，造成 UX 不对称，必须在 UI 上解释「为什么这个片子不能 AirPlay」。
4. **mpv 路径的字幕要自己做 libass 样式映射**（`sub-ass-style-overrides` 的 BGR 颜色格式等，容易错）。
5. MPVKit 作者自己建议生产环境用 AetherEngine。

**AetherEngine 把这 5 条全部解决了**，代价是引入一个单人维护的第三方依赖。考虑到 Prism 是开源项目、且 AetherEngine 已有 17 个真实 App 在用（含 Jellyfin 客户端 Sodalite），这个代价可接受。

### 4.3 为什么仍然保留 `PlaybackEngine` 抽象

即使只有一个实现，抽象层仍然要留。理由不是「为了将来换引擎」这种空话，而是：

1. **AetherEngine 要求 Swift 6.4 / Xcode 27.0 / 26.2+ SDK**。若 CI 或某台开发机跟不上，我们需要能快速回退。
2. **它 87 个 open issues**，且是单人维护。**必须有 Plan B**（§4.5）。
3. **UI 层不应直接依赖第三方的 Combine publisher**。用我们自己的 `AsyncStream<PlaybackEvent>`，UI 才不会被 AetherEngine 的 API 变更牵着走。
4. **测试**：`PlaybackEngine` 协议让我们能写一个 `MockPlaybackEngine` 做 UI 测试，不必启动真引擎。

> **注意**：抽象层不是「为了抽象而抽象」。它的验收标准是：**`import AetherEngine` 只出现在 `AetherPlaybackEngine.swift` 一个文件里**（§10.2）。

### 4.4 AetherEngine → `PlaybackEngine` 映射

这是本文最实用的部分。左侧是我们的协议（§5.4），右侧是 AetherEngine 的实际 API（README / `docs/api.md` 原文）。

| 我们的协议成员 | AetherEngine 对应 | 适配方式 |
|---|---|---|
| `load(_ source:)` | `try await player.load(url:startPosition:options:)` | 直接映射；`PlaybackSource.url(headers:)` → `LoadOptions(httpHeaders:)` |
| `unload()` | `player.stop()` | 直接映射 |
| `play()` | `player.play()` | 直接映射（**注意：它是同步的**） |
| `pause()` | `player.pause()` | 直接映射 |
| `seek(to:precise:)` | `await player.seek(to:)` | 直接映射；`precise` 参数它没有对应物，忽略 |
| `setRate(_:)` | `player.setRate(1.5)` | 直接映射；**它内部 clamp 到 `maxSupportedRate`**（2x 视频 / 3x 纯音频） |
| `setVolume(_:)` | **无直接对应** | ⚠️ **缺口**：README/API 文档中没有 `setVolume`。需查源码或改用系统音量。**待验证** |
| `setMuted(_:)` | **无直接对应** | ⚠️ **缺口**，同上 |
| `tracks` | `player.audioTracks` + `player.subtitleTracks` | 映射 `TrackInfo` → `MediaTrack`；**视频轨它不暴露**（单视频轨场景够用） |
| `selectAudioTrack(_:)` | `player.selectAudioTrack(index: trackID)` | 直接映射 |
| `selectSubtitleTrack(_:)` | `player.selectSubtitleTrack(index: streamID)` | 直接映射；`nil` → `player.clearSubtitle()` |
| `addExternalSubtitle(_:language:title:)` | `player.addExternalSubtitleTrack(ExternalSubtitleTrack(url:name:language:sourceStreamIndex:))` | 返回 `TrackInfo`，取其 `id` 作为我们的 `TrackID` |
| `removeSubtitleTrack(_:)` | **无直接对应** | ⚠️ **缺口**：只有 `clearSubtitle()`（取消选中），没有移除已注册的外挂轨。**待验证** |
| `setSubtitleDelay(_:)` | `player.setSoftwareSubtitleDelay(_:)` | ⚠️ **语义差异**：它只影响**软解路径合成进 PiP 帧**的字幕；原生路径的 AVPlayer rendition 不受影响（文档明示）。我们 UI 上必须说明 |
| `setSubtitleStyle(_:)` | **无直接对应，但也不需要** | ✅ 字幕是我们自己画的（§5.3.1），`SubtitleStyle` 由我们的渲染层消费，**不需要引擎 API**。见下方「缺口 2」 |
| `state` | `player.$state` + `player.$playbackPhase` + `player.clock.$currentTime` 等 | **需要组合**：`$playbackPhase` 是最接近的单一真相源 |
| `events` | 多个 `@Published` + `PassthroughSubject` | **需要桥接**：见 §4.4「缺口 1」 |
| `makeVideoView()` | `AetherPlayerSurface(engine:)`（SwiftUI）或 `AetherPlayerView` + `player.bind(view:)` | ⚠️ **返回类型不匹配**：我们协议要 `NSView`，它给的是 SwiftUI `View`。**改协议**：让 `makeVideoView()` 返回 `AnyView`，或直接用 `AetherPlayerSurface` |
| `supportsPictureInPicture` | 恒 `true`（原生路径）；软解路径看 `softwarePiPSource != nil` | 映射 |
| `supportsAirPlay` | 恒 `true`（原生路径）；`$airPlayPictureStaysLocal` 表示软解路径只有声音过去 | 映射，**注意这个细分状态** |
| `nowPlayingSnapshot` | `player.videoNowPlayingSession` / `setVideoNowPlayingInfo(_:)` | 若 `ownsVideoNowPlayingSession = true` 则由引擎管；否则我们自管 |

#### 三个必须处理的缺口

**缺口 1：`$state` 是 Combine，不是 `AsyncStream`**

这是主管点名要说明的。桥接方案：

```swift
// 用 AsyncStream 的 bufferingNewest 避免 UI 追不上
func events() -> AsyncStream<PlaybackEvent> {
    AsyncStream { continuation in
        let c1 = engine.$playbackPhase.sink { phase in
            continuation.yield(.stateChanged(map(phase)))
        }
        let c2 = engine.$audioTracks.sink { tracks in
            continuation.yield(.tracksChanged(map(tracks)))
        }
        let c3 = engine.clock.$bufferedPosition.sink { pos in
            continuation.yield(.bufferStateChanged(...))
        }
        continuation.onTermination = { _ in
            c1.cancel(); c2.cancel(); c3.cancel()
        }
    }
}
```

**注意**：`AnyCancellable` 不是 `Sendable`，在 Swift 6 严格并发下需要小心。若报错，用 `@preconcurrency import Combine` 或把 sink 关在主 actor 上。

**缺口 2：字幕样式（`setSubtitleStyle`）没有引擎 API——但这反而是优势**

这原本看起来是缺口，实际是**优势**：AetherEngine 的字幕是「引擎给你 cues，你自己画」的模式：
- 文本 cue：`$subtitleCues` → `.text(String)` 或 `.richText([SubtitleTextRun])`，**你自己用 SwiftUI/TextKit 渲染**
- 图形 cue：`.image(SubtitleImage)`

**好消息**：因为字幕是我们自己画的，**用户字号/颜色/描边偏好完全由我们控制**——这反而比 mpv 的 `sub-ass-style-overrides` 更灵活。
**坏消息**：ASS 的复杂排版（定位、特效、karaoke）在 `.richText` 里只能近似还原，**不如 libass 精确**。这是 §3.2 里 MPVKit 唯一胜出的维度。

**缺口 3：`setVolume` / `setMuted` 未在文档中找到**

README 和 `docs/api.md` 的 transport 段列了 `play/pause/togglePlayPause/setRate/seek/stop`，**没有音量**。两种可能：① 引擎不管音量（靠系统音量）；② 有 API 但没写进文档。**必须先查源码确认**，这是集成 spike 的第二件事（§7.1 #2，仅次于「能否编译」）。

### 4.5 什么时候切回 MPVKit（Plan B 触发条件）

| 触发条件 | 说明 |
|---|---|
| **AetherEngine 无法编译**（工具链/SDK 不满足） | 最硬的条件。若 Xcode 27.1 + 26.2 SDK 仍编不过，直接切 |
| **ASS 渲染质量不可接受** | 用户反馈特效字幕/双语字幕排版错乱，且 `.richText` 无法修复 |
| **软解路径功耗过高** | 4K HEVC 软解导致风扇狂转/掉帧（注意：HEVC 默认走硬解，这条主要影响 VP9/AV1/MPEG-2 等） |
| **AetherEngine 停更** | 连续 6 个月无 release |
| **`setVolume` 等关键缺口无法绕过** | 若音量控制只能靠系统音量，UX 不可接受 |

切回时，`PlaybackEngine` 协议不变，只需新增 `MPVPlaybackEngine`（附录 A 保留了 MPVKit 的完整集成资料）。

### 4.6 什么情况下应该推翻整个方案

| 若发现 | 则改为 |
|---|---|
| 用户库里 MKV 占比 < 20%，且几乎无 DTS/ASS | **纯 AVPlayer + 服务端转码**，省掉所有第三方依赖 |
| 只需要「能播」，不要 AirPlay/PiP/HDR | **VLCKit 单引擎**（LGPL-2.1 动态框架，成熟稳定） |
| AetherEngine 与 MPVKit 都不可用 | **VLCKit** 兜底，接受 UX 降级 |
| 产品要求闭源商业化 | **不能选 AetherEngine**（LGPL-3.0 会传染修改部分）；选 VLCKit |

---

## 5. 抽象设计

### 5.1 硬性约束：引擎类型零泄漏

> **验收标准**：`import AetherEngine`、`OpaquePointer`、`mpv_handle`、`mpv_render_context`、`import Libmpv`、`import VLCKit`、`AetherEngine` 的任何类型名（`TrackInfo`、`PlaybackPhase`、`LoadOptions`…）**一律不得出现在 `PlaybackEngine` 协议、`PlaybackState`、`MediaTrack`、`PlaybackEvent` 及任何对外类型中**。
>
> CI 检查（两条都要）：
> ```bash
> # 1) 只允许 AetherPlaybackEngine.swift 一个文件 import AetherEngine
> grep -rl "import AetherEngine" --include="*.swift" . \
>   | grep -v "AetherPlaybackEngine.swift" && exit 1
>
> # 2) 协议层不得出现第三方类型名
> grep -rn "TrackInfo\|LoadOptions\|PlaybackPhase\|OpaquePointer" \
>   Sources/PrismPlayback/ && exit 1
> ```

**理由**（三条，都不是空话）：

1. **AetherEngine 是单人维护 + 87 个 open issues**，必须有 Plan B（§4.5）。零泄漏让「换引擎」从「重写播放器」降级为「新增一个实现类」。
2. **它的工具链门槛是硬的**（Swift 6.4 / Xcode 27.0 / 26.2+ SDK）。若 CI 跟不上，我们要能在不改 UI 的前提下回退。
3. **UI 不应被第三方 Combine publisher 的形状绑架**。我们的 `PlaybackEvent` 是稳定契约，AetherEngine 的 `$playbackPhase` 不是。

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
    public let language: String?        // BCP-47（AetherEngine 用 BCP-47；mpv 用 ISO 639-2，适配层需转换）
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

/// 播放阶段。**这是 UI 的唯一真相源**，对应 AetherEngine 的 `$playbackPhase`。
/// 不要用 `isPlaying` + `isBuffering` 自己拼——那会漏掉 `.stalled` / `.rebuffering` 的区别。
public enum PlaybackPhase: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    case rebuffering
    case stalled(reconnecting: Bool)
    case ended
    case failed(PlaybackFailureReason)
}

public struct PlaybackState: Sendable, Equatable {
    public var phase: PlaybackPhase = .idle
    /// 便于 SwiftUI 直接绑定；等价于 `phase == .playing`
    public var isPlaying: Bool { phase == .playing }
    /// 便于显示 spinner；覆盖 loading / rebuffering / stalled
    public var isBuffering: Bool {
        switch phase {
        case .loading, .rebuffering, .stalled: return true
        default: return false
        }
    }
    public var position: TimeInterval = 0
    public var duration: TimeInterval = 0
    public var bufferedPosition: TimeInterval = 0
    public var rate: Float = 1.0
    public var volume: Float = 1.0
    public var isMuted: Bool = false

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
    /// 字幕 cue 更新。**字幕由我们自己渲染**（AetherEngine 只给 cue），
    /// 所以这条事件驱动我们的 SwiftUI 字幕层。见 §5.3.1。
    case subtitleCuesChanged([SubtitleCue])
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

#### 5.3.1 字幕 cue 与渲染归属

**关键设计决定：字幕由我们渲染，不由引擎渲染。**

AetherEngine 的模型是「引擎给 cue，宿主画」：
```swift
player.$subtitleCues  // [SubtitleCue]，body 为 .text / .richText([SubtitleTextRun]) / .image(SubtitleImage)
```

我们的中间表示：

```swift
public enum SubtitleCueBody: Sendable {
    case text(String)
    case richText([SubtitleTextRun])
    /// PGS / DVB / DVD 图形字幕
    case image(SubtitleImage)
}

public struct SubtitleTextRun: Sendable {
    public var text: String
    public var color: SubtitleColor?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikeout: Bool
    public var fontName: String?
    /// 相对字号（ASS 的 `s` 是相对 PlayResY 的，需按视频高度归一）
    public var relativeSize: Double?
}

public struct SubtitleCue: Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var body: SubtitleCueBody
    /// numpad 对齐（1-9）+ 可选 [0,1] 锚点
    public var placement: SubtitlePlacement?
}
```

**为什么这是好事**：用户偏好（字号/颜色/描边/位置）**完全由我们的 `SubtitleStyle` 控制**，不需要依赖引擎的样式 API。这比 mpv 的 `sub-ass-style-overrides` 更灵活。

**代价**：ASS 的复杂排版（精确定位、karaoke、特效）在 `.richText` 里只能近似。这是 §3.2 里 MPVKit 唯一胜出的维度。

**渲染实现要点**：
- 文本用 SwiftUI `Text` 拼 `AttributedString`（`SubtitleTextRun` → `AttributeContainer`）。
- 图形 cue 用 `Image(nsImage:)` 叠加，注意按视频实际渲染尺寸缩放（不能按窗口尺寸）。
- **对时用 `clock.$sourceTime`**（画面 PTS），不是 `clock.$currentTime`。

---

**Plan B（mpv）的样式映射**（若切到 MPVKit 才用；选项名见 §9.1 V19/V20）：

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
/// 实现方必须是引用类型。所有方法在主 actor 上调用；
/// 具体实现（AetherEngine / MPVKit）自行负责内部隔离。
@MainActor
public protocol PlaybackEngine: AnyObject {

    // MARK: 身份

    static var engineKind: EngineKind { get }
    var engineKind: EngineKind { get }

    // MARK: 生命周期

    /// 加载媒体。`source` 是引擎无关的描述。
    /// `resumeAt` 用于降级时保留播放位置（§6.3 约束 1）。
    func load(_ source: PlaybackSource, resumeAt position: TimeInterval?) async throws

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

    /// 返回一个可直接放进 SwiftUI 视图树的画面视图。
    ///
    /// **为什么是 `AnyView` 而不是 `NSView`**：AetherEngine 提供的是
    /// `AetherPlayerSurface(engine:)`（SwiftUI View）；MPVKit 提供的是
    /// `NSViewRepresentable` 包着的 `NSView`。两者都能表达成 `AnyView`，
    /// 但表达不成同一个 `NSView` 子类。协议选择 `AnyView` 以兼容两者。
    ///
    /// 调用方用法：`engine.videoSurface().frame(maxWidth: .infinity, maxHeight: .infinity)`
    @MainActor func videoSurface() -> AnyView

    /// 该引擎当前会话是否支持系统级画中画。
    /// 注意这是**会话级**而非引擎级：AetherEngine 原生路径 true、
    /// 软解路径看 `softwarePiPSource` 是否存在；libmpv 恒 false。
    var supportsPictureInPicture: Bool { get }

    /// 该引擎当前会话是否支持 AirPlay 视频路由。
    /// 注意 AetherEngine 的 `$airPlayPictureStaysLocal`：软解路径下
    /// 接收机只拿到音频，画面留在本机。UI 必须区分这两种状态。
    var supportsAirPlay: Bool { get }
    var airPlayPictureStaysLocal: Bool { get }

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

### 5.5 引擎选择与降级策略

> **重要变化**：rev.2 里 `EngineSelector` 的职责是「在 AVPlayer 和 libmpv 之间选路」。**AetherEngine 内部已经做了这件事**（`$videoRoute` 暴露它选了哪条），我们不再需要自己选路。
>
> 现在 `EngineSelector` 的职责收窄为两件事：① **决定用哪个 `PlaybackEngine` 实现**（正常情况恒为 AetherEngine）；② **失败后的降级决策**。

#### 5.5.1 引擎实现选择（几乎恒定）

```swift
public enum EngineKind: String, Sendable, Codable {
    case aether       // 默认
    case libmpv       // Plan B
    case vlc          // Plan C（预留）
    case mock         // 测试
}

public struct EngineSelector: Sendable {
    public struct Input: Sendable {
        /// 用户设置里的引擎偏好（默认 .automatic）
        public let preference: EngineKind?
        /// 启动时探测到的 AetherEngine 可用性（编译期决定，缓存一次）
        public let aetherAvailable: Bool
        /// 上次会话是否因引擎问题失败
        public let lastFailureWasEngineFault: Bool
    }

    public func selectEngine(_ input: Input) -> EngineKind {
        if let p = input.preference { return p }
        if input.aetherAvailable && !input.lastFailureWasEngineFault { return .aether }
        return .libmpv   // 或 .vlc，取决于哪个已集成
    }
}
```

**这个函数的价值不在「选路」，而在于**：把「引擎不可用时怎么办」这件事显式化，而不是散落在 UI 里。

#### 5.5.2 降级决策（真正的复杂度在这里）

AetherEngine 自己会在内部路由（native ↔ software），也会自己重连。**但有些失败它不会自动恢复**，需要我们决策。依据它的 `$errorInfo.PlaybackErrorKind`（README 明示「Classify on this」，不要解析 `error` 字符串——那是本地化文本）。

```swift
public enum FallbackAction: Sendable {
    case retrySameSource          // 原地重试（网络抖动）
    case requestHLSDirectStream   // 请求 Emby 只换容器（fMP4）
    case requestHLSTranscode      // 请求 Emby 转码
    case switchEngine(EngineKind) // 换引擎
    case surfaceToUser(String)    // 放弃，给用户看
}

public struct FallbackPolicy: Sendable {
    public func decide(errorKind: String,          // AetherEngine 的 PlaybackErrorKind.rawValue
                       attempt: Int,
                       source: MediaSourceInfo) -> FallbackAction
}
```

**降级阶梯（按 attempt 递进，最多 3 次）：**

| attempt | 动作 | 触发条件 |
|---|---|---|
| 1 | `retrySameSource` | 网络类错误（连接断开、超时）；等 500ms |
| 2 | `requestHLSDirectStream` | 解码/容器类错误；请求 Emby 用 `Container=mp4` 直封 |
| 3 | `requestHLSTranscode` | 仍失败；请求 `VideoCodec=h264` + `AudioCodec=aac` 转码 |
| 4 | `surfaceToUser` | 停在这里，**不要无限重试** |

**关键约束：**

1. **每次降级保留 `position`**：切源前捕获，新源 `load(url:startPosition:)` 直接带过去。
2. **退避**：attempt 2 前等 500ms，attempt 3 前等 1500ms。
3. **上报 `PlayMethod`**：`POST /Sessions/Playing` 要如实填 `DirectPlay` / `DirectStream` / `Transcode`，否则服务器统计错误、用户也不知道为什么在转码。
4. **降级不可逆**：一旦降到转码，本次会话保持转码，不要「好了再切回直连」（会造成二次缓冲）。
5. **不要靠 `$state == .error` 的字符串判断原因**——用 `$errorInfo.PlaybackErrorKind`。

#### 5.5.3 用户偏好

| 偏好 | 行为 |
|---|---|
| 自动（默认） | 引擎自选路由；失败按 5.5.2 降级 |
| 优先原生播放（省服务器） | `LoadOptions.nativeRemoteHLS = true`（若源是 HLS）；否则无区别 |
| 优先兼容（保画质） | 不请求转码，宁可换引擎或提示用户 |
| 强制直连 | 不允许任何转码；失败即报错 |

> ⚠️ **注意**：AetherEngine 的「原生 vs 软解」路由**不是用户可选的**——它按编解码能力自动决定，`$videoRoute` 只读。用户偏好只能影响「我们向 Emby 请求什么」，不能影响引擎内部路由。

### 5.6 Now Playing 与远程控制

**AetherEngine 提供了两种模式**（`docs/api.md` 原文）：

| 模式 | 做法 | 适用 |
|---|---|---|
| **引擎托管** | `player.ownsVideoNowPlayingSession = true`，然后用 `setVideoNowPlayingInfo([...])` 塞元数据；elapsed/rate/duration 由引擎从 player 合并，**不要自己塞** | 我们自绘 transport bar 的场景 ✅ |
| **宿主自管** | 用 `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` 自己填 | 需要完全控制时 |

**我们选「引擎托管」**，理由：`MPNowPlayingSession` 能正确处理后台暂停、跨 track 切换等边界，自己实现容易出错。

```swift
@MainActor
public final class NowPlayingCoordinator {
    public func bind(engine: any PlaybackEngine, metadata: NowPlayingMetadata) {
        // 1. 若底层支持托管，走托管；否则回落到 MPNowPlayingInfoCenter
        // 2. 注册 remote command：play/pause/togglePlayPause/changePlaybackPosition
        // 3. 订阅 engine.events 更新 elapsedTime/rate
    }
}
```

> ⚠️ **两个平台差异（README 原文）**：
> - `ownsVideoNowPlayingSession` **只在 tvOS / iOS 的原生视频路径生效**；`docs/architecture.md` 明说「on macOS the path compiles and plays without the system session」。
> - **macOS 上我们必须用 `MPNowPlayingInfoCenter` 自管**。这是 macOS 特有的工作量，不要假设引擎会帮我们做。
> - 音频路径（`audioOnly`）的 `audioNowPlayingSession` 是**无条件拥有**的，不受上述限制。

`MPNowPlayingInfoCenter` 与 `MPRemoteCommandCenter` 在 macOS 10.12.2+ 可用（Apple 文档已核实）。

### 5.7 画面输出层

#### AetherEngine（首选）

**我们几乎不用写代码**——它直接给 SwiftUI 视图：

```swift
import AetherEngine
import SwiftUI

struct PlayerContainer: View {
    let engine: AetherPlaybackEngine

    var body: some View {
        engine.videoSurface()          // 内部是 AetherPlayerSurface(engine:)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

适配层实现：

```swift
@MainActor
final class AetherPlaybackEngine: PlaybackEngine {
    private let engine: AetherEngine   // 唯一持有第三方类型的地方

    func videoSurface() -> AnyView {
        AnyView(AetherPlayerSurface(engine: engine))
    }
}
```

**关键点（README 原文）**：
> The view is polymorphic: under the hood the engine swaps the hosted CALayer (`AVPlayerLayer` for the native AVPlayer path, `AVSampleBufferDisplayLayer` for the SW dav1d fallback path) per session without the host having to know.

即：**画面输出层不需要我们关心路径切换**。这正是它相对 rev.2 双引擎方案最大的省力点。

#### PiP（AetherEngine）

```swift
// 原生路径：用引擎给的 AVPlayer / AVPlayerLayer 建 PiP
let pip = AVPictureInPictureController(playerLayer: engine.nativePlayerLayer)
// 或
let pip = AVPictureInPictureController(playerLayer: playerLayer(from: engine.currentAVPlayer))

// 进入 PiP 前要告诉引擎（影响后台 teardown 与软解路径是否继续解码视频）
engine.pictureInPictureActive = true
```

软解路径用 `engine.softwarePiPSource`（提供 `AVSampleBufferDisplayLayer` + transport 回调）。

> ⚠️ **macOS 已知问题**（Apple Developer Forums 记录，见 §9.1 V37b）：macOS 26.4 上 `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:)` 存在**缩放 bug**——PiP 窗口按 1:1 像素镜像，只显示画面左下角一块。**iOS 不受影响**。这条影响 AetherEngine 的软解路径 PiP，需要在 macOS 上实测。

#### MPVKit（Plan B，仅保留资料）

若将来切到 Plan B，画面输出走 `wid` 嵌入 `CAMetalLayer`：

```swift
// 选项顺序很重要：必须在 mpv_initialize 之前设置
mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayer)   // ← 传 CAMetalLayer
mpv_set_option_string(mpv, "vo", "gpu-next")
mpv_set_option_string(mpv, "gpu-api", "vulkan")
mpv_set_option_string(mpv, "gpu-context", "moltenvk")
mpv_set_option_string(mpv, "hwdec", "videotoolbox")
```

**必须抄的两个 workaround**（来自 MPVKit Demo 的 `MetalLayer.swift`）：

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
> Plan B 若启动，先走 `wid`（代码量最小、MPVKit 唯一验证过的组合），render API 作为退路。

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
                           │ 用户选中条目
                           ▼
                    ┌──────────────────────────────┐
                    │  .preparing                  │
                    │  POST /Items/{id}/PlaybackInfo│
                    │  拿到 MediaSources + 决策      │
                    └──────┬───────────────────────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
     ┌─────────────────┐       ┌─────────────────┐
     │ .directPlay     │       │ .directStream   │
     │ 原文件 URL 给引擎 │       │ HLS 直封 URL    │
     └────────┬────────┘       └────────┬────────┘
              │ 失败                     │ 失败
              ▼                          ▼
     ┌──────────────────────────────────────────────┐
     │ .fallback(attempt: 1..3)                     │
     │  attempt 1: 同源重试（网络类）                 │
     │  attempt 2: 请求 HLS 直封（只换容器 → fMP4）   │
     │  attempt 3: 请求 HLS 转码（h264 + aac）        │
     └──────────────┬───────────────────────────────┘
                    │ 全部失败
                    ▼
             ┌──────────────┐
             │  .failed     │  展示 $errorInfo 归类后的原因 + 重试按钮
             └──────────────┘

  任意状态 --用户停止--> .idle
  .directPlay/.directStream/.fallback --播放到结尾--> .ended
```

> **与 rev.2 的差异**：rev.2 的 attempt 1 是「换引擎（avPlayer ↔ libmpv）」。现在只有一个引擎，**attempt 1 改为「同源重试」**（网络抖动占失败的大多数）。换引擎降为 Plan B 时的选项。

**降级决策表（触发条件 → 动作）：**

| 观测到的失败 | 判定（映射到 `PlaybackFailureReason`） | 动作 |
|---|---|---|
| 引擎报容器/格式不支持 | `.containerUnsupported` | attempt 2：请求 HLS 直封 |
| 能打开但无视频轨 / 黑屏 | `.videoCodecUnsupported` | attempt 3：请求转码 |
| 有画面无声音 | `.audioCodecUnsupported` | attempt 3：请求转码（只转音频） |
| 字幕不显示 | `.subtitleUnsupported` | 请求 `SubtitleMethod=Encode` 烧录 |
| HTTP 4xx / 401 / 403 | `.serverRejected` | **重新** `POST /PlaybackInfo`（token 可能过期），不消耗 attempt |
| 播放中卡死 > 15s 无进度 | `.networkError` | attempt 1：重试；再失败 → attempt 2 |
| 引擎崩溃 / 上下文失效 | `.engineCrashed` | 重建引擎，从最后位置 `load(startPosition:)` |
| 连续 3 次降级失败 | — | `.failed`，**停止重试** |

**关键实现约束：**

1. **每次降级必须保留播放位置**：`position` 在切换前捕获，新源 `load(url:startPosition:)` 直接带过去。
2. **退避**：attempt 2 前等 500ms，attempt 3 前等 1500ms。
3. **上报 `PlayMethod`**：`POST /Sessions/Playing` 的 `PlayMethod` 必须与实际一致（`DirectPlay` / `DirectStream` / `Transcode`）。
4. **降级不可逆**：一旦降到转码，本次会话保持转码。
5. **用 `$errorInfo.PlaybackErrorKind` 分类**，不要解析 `$state` 里的 `.error(String)`——README 明说那个 message 是本地化的 AVFoundation 文本，「a substring rule over it buckets every non-English device as unknown」。

## 7. 最小可运行验证方案（1 天 spike）

### 7.1 AetherEngine spike（**这是现在要做的那个**）

> ⚠️ **前提**：本节是**计划**，尚未执行。§7.2 是 MPVKit 的历史实验记录，保留作为 Plan B 参考。

**目标（必须验证，按优先级）**

| # | 验证项 | 为什么重要 | 判定标准 |
|---|---|---|---|
| 1 | **能否编译** | 它要求 Swift 6.4 / Xcode 27.0 / 26.2+ SDK；我们是 Xcode 27.1 / Swift 6.4 | `import AetherEngine` + `AetherPlayerSurface` 能过编译 |
| 2 | **`setVolume` / `setMuted` 是否存在** | 文档里没写，是明确缺口（§4.4 缺口 3） | 读源码 `Sources/AetherEngine/` 找 `volume`；或看 `AVPlayer.volume` 是否透传 |
| 3 | **MKV + HEVC + DTS 能播** | 这是整个选型的核心价值 | 本地 MKV 能出画面、有声音 |
| 4 | **外挂 ASS 能显示且样式可控** | 决定「字幕渲染质量」这条是否真的输给 mpv | `.richText` 渲染出中文，字号/颜色可改 |
| 5 | **切音轨** | 双音轨 MKV 能切 | `selectAudioTrack(index:)` 生效 |
| 6 | **PiP 在 macOS 上能用** | §5.7 记录的 macOS 缩放 bug 是否影响 | PiP 窗口画面比例正常 |
| 7 | **Swift 6 严格并发** | 它声明 Swift 6.4，但没说是否 `complete` 检查通过 | 我们的适配层在 `-strict-concurrency=complete` 下零诊断 |

**非目标**：Emby 网络集成（用本地文件）、Dolby Vision（需要 DV 显示器 + 素材）、AirPlay（需要接收机）。

**代码骨架（伪代码，未验证）**

```swift
// Package.swift —— 注意：我们工程用 XcodeGen（project.yml），
// 而 XcodeGen 2.45.4 会静默丢弃 traits:（README 明示）。
// 第一版先不加 traits（全部默认关闭），避免踩这个坑。
dependencies: [
    .package(url: "https://github.com/superuser404notfound/AetherEngine",
             .upToNextMinor(from: "7.44.0"))
]

// 适配层骨架
import AetherEngine
import SwiftUI
import Combine

@MainActor
final class AetherPlaybackEngine: PlaybackEngine {
    private let engine: AetherEngine
    private var cancellables = Set<AnyCancellable>()

    init() throws {
        self.engine = try AetherEngine()
        self.engine.ownsVideoNowPlayingSession = false   // macOS 上自己管
    }

    func load(_ source: PlaybackSource, resumeAt position: TimeInterval?) async throws {
        guard case .url(let url, let headers) = source else {
            throw PlaybackError(reason: .unknown, underlyingDescription: "unsupported source", isRecoverable: false)
        }
        try await engine.load(url: url,
                              startPosition: position,
                              options: .init(httpHeaders: headers))
    }

    func videoSurface() -> AnyView { AnyView(AetherPlayerSurface(engine: engine)) }

    // ... 其余按 §4.4 映射表实现
}
```

**排期**

| 时段 | 任务 |
|---|---|
| 0–1h | 加依赖、编过、`AetherEngine()` 能初始化 |
| 1–2h | **查 `setVolume` 是否存在**（决定 §4.4 缺口 3 的结论） |
| 2–4h | 本地 MKV（HEVC+DTS）能播，出画面有声音 |
| 4–5h | 外挂 ASS + 切音轨 |
| 5–7h | SwiftUI 集成 + PiP 实测 |
| 7–8h | 写适配层 `events` 桥接，跑 `-strict-concurrency=complete` |

### 7.2 MPVKit 一次性验证实验记录（Plan B 参考；非工程内集成，产物已清理、不可复现）

> **证据等级声明（务必先读）**
>
> 本节记录的是 2026-10-21 的一次**离线探索性实验**：手工 `swiftc` 直接链接 29 个解压后的 xcframework，**完全绕开 SwiftPM / git / 网络凭据**。
>
> - 它**不是** Prism 工程内的集成验证，`Package.swift` 里没有 MPVKit 依赖，Xcode 工程没有链接它。
> - 实验产物目录（`.spike/mpv/`，含 vendor/ 与可执行文件）**已被清理，当前不存在**。因此**任何人无法复现本节结果**，包括作者本人。
> - 该实验触发了 macOS 钥匙串弹窗事故（SwiftPM 解析 GitHub 依赖时调用 `gh auth git-credential`），团队因此决定**放弃 SwiftPM 远程依赖**，改用 vendoring（附录 A）。
> - **结论**：本节内容仅供实现时参考「API 大致长什么样、哪些属性名存在」，**不得作为「已验证可用」引用**。正式验证必须在 vendoring 落地后于工程内重做。

**环境**：macOS 27.0 / Xcode 27.1 / Swift 6.4 / arm64
**依赖**：MPVKit `1.0.0`，29 个 xcframework 手动 `curl` 下载（不走 SwiftPM）

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

**结论（一次性实验的观察结果，非工程基线）：**

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
| **窗口渲染（`gpu-next`+MoltenVK）** | ❌ **未跑通** |
| **硬件解码（`hwdec-current`）** | ❌ 未验证（`vo=null` 下不解码） |

> ⚠️ 上表「✅」的含义是「那次离线实验里观察到预期行为」，**不是「Prism 工程里已验证」**。产物已清理，不可复现，请按 §9.2 的待验证清单在集成落地后重做。

**两个意外发现（必须写进实现要求）：**

1. **`ytdl` 默认是 `yes`**。这意味着 libmpv 遇到未知 URL 可能尝试调用 youtube-dl 子进程。**必须显式 `mpv_set_option_string(h, "ytdl", "no")`**，否则是安全与性能双重隐患。
2. **`hwdec-current` 在 `vo=null` 下是 `no`**（因为没有视频输出，不解码）。这是预期行为，但也说明 **该实验没有验证硬件解码路径**。

### 7.3 Swift 6 并发模型（设计建议，基于该次实验的编译观察）

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

### 7.4 MPVKit spike 排期（Plan B）

| 时段 | 任务 | 产出 |
|---|---|---|
| 0–2h | 环境：按附录 A 把 xcframework vendoring 进 `ThirdParty/MPVKit/`，`Package.swift` 用 `binaryTarget(path:)`，工程能编译 | `import Libmpv` 能过 |
| 2–4h | 加载 MKV，打印 `track-list`；验证音轨切换 | §7.2 的 [1][3] |
| 4–5h | 外挂 ASS：`sub-add` + `sub-ass-override` + `sub-delay` | §7.2 的 [4] |
| 5–8h | **渲染**：`wid` + `CAMetalLayer` + `gpu-next/moltenvk`，在 `NSViewRepresentable` 里出画面 | 一个能显示 MKV 画面的 SwiftUI 视图 |

> **风险提示**：0–5h 的部分在一次性离线实验中观察到过预期行为（§7.2），但**未在工程内复现**。真正的未知在 5–8h 的渲染段——**该段从未跑通**。**如果渲染段 3 小时搞不定，立刻降级到 render API 方案，或直接放弃 mpv 路线**（回到 §4.5 的 Plan B 触发条件）。

### 7.5 MPVKit 渲染段代码骨架（Plan B，未验证部分）

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

### 7.6 MPVKit 渲染段验证清单（Plan B，给执行者）

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

> 按「当前首选方案（AetherEngine）」与「Plan B（MPVKit）」分组。等级：🔴 高 / 🟠 中高 / 🟡 中。

### 8.1 AetherEngine（当前首选）

| ID | 风险 | 等级 | 影响 | 缓解 |
|---|---|---|---|---|
| **A1** | **单人维护 + AI 辅助**（README 自述 "vibe-coded ... with Claude"），87 个 open issues | 🔴 高 | 停更或维护质量下滑 → 无法跟进安全修复 | ① `PlaybackEngine` 零泄漏（§5.1）保证可换；② 锁 `.upToNextMinor`；③ 定期评估 issue 关闭速度 |
| **A2** | **工具链门槛硬**：Swift 6.4 / Xcode 27.0 / **26.2+ SDK** | 🟠 中高 | CI 或开发机跟不上就无法构建 | ① spike 第一件事就是验证能否编译（§7.1 #1）；② CI 镜像锁定 `xcode-27` |
| **A3** | **`setVolume` / `setMuted` 在文档中找不到** | 🟠 中高 | 若真的没有，音量只能靠系统音量，UX 不可接受 | spike 第二件事就是查源码（§7.1 #2）；若确实没有，评估能否用 `AVPlayer.volume` 透传或加 issue |
| **A4** | **字幕样式无用户偏好 API**（只有字幕自带的 `.richText`） | 🟡 中 | 用户不能改字号/颜色/描边 | 字幕是我们自己画的 → 用自己的 SwiftUI 渲染层实现偏好；但要接受 ASS 复杂排版还原度不如 libass |
| **A5** | **macOS 上 PiP 的 `AVSampleBufferDisplayLayer` 缩放 bug**（macOS 26.4 已记录，iOS 正常） | 🟡 中 | 软解路径的 PiP 画面只显示左下角一块 | ① 原生路径不受影响（用 `AVPlayerLayer`）；② spike 验证（§7.1 #6）；③ 若确认，软解路径禁用 PiP 并提示 |
| **A6** | **`traits` 与 XcodeGen 冲突**（2.45.4 静默丢弃 `traits:`） | 🟡 中 | 无法开启 TrueHD/DTS:X/DV-FEL 等可选组件 | ① 第一版全部保持默认关闭；② 若必须开，手工 patch `.pbxproj` 或包一层本地 package（README 给了两种做法） |
| **A7** | **依赖链深**（4 个直接依赖，FFmpegBuild 含 9 个 binaryTarget + 约 45 MB dSYM） | 🟡 中 | 首次 clone/构建慢 | 实测后决定是否 vendoring；FFmpeg 动态框架 **macOS universal 约 22.7 MB** 是已知的 .app 增量 |
| **A8** | **LGPL-3.0 传染性**：若我们修改 AetherEngine，修改部分需以 LGPL 发布 | 🟡 中 | 未来若想闭源商业化会受阻 | ① 不 fork、只提 issue/PR 上游；② 若必须改，接受开源该部分；③ 商业化前重新评估（§4.6） |
| **A9** | **软解路径功耗**（VP9/AV1/MPEG-2 等走软解） | 🟡 中 | 4K 软解可能风扇狂转/掉帧 | HEVC/H.264 默认走硬解，影响面有限；实测 4K VP9 场景 |
| **A10** | **Emby 服务端 fMP4 行为版本相关** | 🟡 中 | 若走服务端 HLS 直封，可能出 TS 导致 HEVC 被迫转码 | AetherEngine **自己产 fMP4**，不依赖服务端；仅当用 `nativeRemoteHLS` 时才受影响 |

### 8.2 环境风险（与引擎无关）

| ID | 风险 | 等级 | 影响 | 缓解 |
|---|---|---|---|---|
| **E1** | **SwiftPM 解析 GitHub 依赖会触发 macOS 钥匙串弹窗**（本机 `~/.gitconfig` 有 `credential.helper = gh auth git-credential`），已实际打断用户 **3 次** | 🔴 高 | 开发体验破坏、代理会话中断 | ① 所有联网构建命令加 `GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null`（**`GIT_CONFIG_COUNT` + 空 helper 压不住多行 helper 配置**）；② 若反复失败，改为 vendoring |
| **E2** | **首次拉取 AetherEngine 依赖链体积未实测** | 🟡 中 | CI 与新人上手成本未知 | spike 时记录实际耗时与体积 |

### 8.3 Plan B（MPVKit）的既有风险（保留备查）

| ID | 风险 | 等级 | 说明 |
|---|---|---|---|
| **R2** | **MPVKit 维护不活跃**，作者明示「不会频繁维护」并建议生产环境用 AetherEngine | 🔴 高 | 这正是降为 Plan B 的直接原因之一 |
| **R3** | **mpv 路径拿不到 AirPlay / PiP / 系统 HDR 握手** | 🔴 高 | 决定性劣势 |
| **R4** | **渲染段（`gpu-next` + MoltenVK + `wid`）从未跑通** | 🟠 中高 | Plan B 启动时首先要解决 |
| **R5** | 首次集成 350–380 MB / 29 个 binaryTarget | 🟡 中 | 需 vendoring（附录 A） |
| **R7** | mpv `ytdl` 默认 `yes`，未知 URL 可能拉起外部进程 | 🟡 中 | 显式 `ytdl=no` |
| **R8** | 第三方二进制可能带 `--enable-nonfree`（MPVKit 历史 issue #77） | 🟡 中 | 每次升级 `strings \| grep nonfree` 复核 |
| **R10** | `wid` 嵌入在 SwiftUI 全屏/多窗口下可能不稳 | 🟡 中 | Plan B 启动时验证 |

> **已失效的风险**：rev.2 的 R1「LGPL-3.0 静态链接需分发 .o」——Prism 开源后该义务通过源码公开自然满足（§3.3）。

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
| V14 | 29 个非 GPL xcframework 下载约 350–380 MB；arm64 macOS slice 未压缩合计 **≈ 67.6 MB**（Libshaderc 15.7 / Libavcodec 9.8 / Libcrypto 8.7 / Libmpv 6.0 …） | 本机实测：curl 下载 + 解压 + `lipo -thin arm64` + `stat`（**一次性实验，产物已清理**） |
| V15 | `mpv_client_api_version()` 返回 `131077`（= mpv 2.5） | 一次性实验（产物已清理，不可复现） |
| V16 | 一次性实验中 `-swift-version 6 -strict-concurrency=complete` 下 wrapper 编译零诊断 | 一次性实验（产物已清理，**不可复现**；需在工程内重验） |
| V17 | 一次性实验中观察到：MKV 解封装、HEVC Main10（`yuv420p10`）、E-AC-3、双音轨切换、非法 aid 回落 `no`、`sub-add` rc=0、`sub-delay` 可写、`sub-ass-override`/`sub-ass-style-overrides` 接受、`speed`/`volume`/`seek`/`paused-for-cache`/`cache-buffering-state` 可用、`audio-spdif` 接受 | 一次性实验（产物已清理，**不可复现**） |
| V18 | 一次性实验中读到 mpv `ytdl` 默认值为 `yes` | 一次性实验；**旁证**：`mpv_options.rst` 中 `--ytdl` 默认值文档亦为 yes |
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

| V44 | AetherEngine 仓库为 `superuser404notfound/AetherEngine`；265 stars；最后推送 2026-10-20；87 open issues；未归档 | GitHub API `/repos/...` |
| V45 | 最新 release **`7.44.0`**，发布 2026-10-20T06:04:27Z，**`prerelease=false`**；唯一 asset 是 `AetherEngine-Demo-7.44.0.dmg`（**没有二进制 framework**，即源码包） | GitHub Releases API |
| V46 | `Package.swift`：`swift-tools-version: 6.1`；`platforms: iOS 18 / tvOS 18 / macOS 15 / visionOS 1`；**纯 `.target`，无 `binaryTarget`** | https://raw.githubusercontent.com/superuser404notfound/AetherEngine/main/Package.swift |
| V47 | 依赖：`FFmpegBuild`(≥3.9.0)、`SMBClient`(≥0.3.1)、`LibDovi`(≥2.1.0)、`LibTrueHD`(≥3.0.0，仅 `TrueHDObjectAudio` trait) | 同上 |
| V48 | README Requirements：iOS 18 / tvOS 18 / **macOS 15** / visionOS 1 / **Swift 6.4** / **Xcode 27.0**；「The source needs at least the 26.2 SDK」（因 `VTRegisterSupplementalVideoDecoderIfAvailable` 是 26.2 API） | https://raw.githubusercontent.com/superuser404notfound/AetherEngine/main/README.md |
| V49 | LICENSE：**LGPL-3.0 + Apple Store / DRM Exception**，例外「grants permission to distribute ... through application stores ... even where the platform's terms impose restrictions on: signing or re-signing ...; FairPlay-style DRM ...; end-user redistribution ...; end-user re-linking」 | https://raw.githubusercontent.com/superuser404notfound/AetherEngine/main/LICENSE |
| V50 | README 明确：**「The exception covers AetherEngine's own code; it does not extend to its dependencies.」** | README「License」段 |
| V51 | FFmpeg 以**动态框架**分发（dylib-in-framework，`@rpath`），LGPL-2.1-or-later，「That is what keeps the LGPL relink requirement satisfiable for closed-source apps」 | https://raw.githubusercontent.com/superuser404notfound/FFmpegBuild/main/README.md |
| V52 | FFmpeg 体积：**macOS universal (arm64+x86_64) 约 22.7 MB**；iOS/tvOS/visionOS arm64 约 10.5 MB（Release，含 6 个 FFmpeg 库 + dav1d/zimg/zvbi） | FFmpegBuild README「Size」表 |
| V53 | 架构（native 路径）：「Demux the source with libavformat, re-mux the elementary streams on the fly into HLS-fMP4, serve them from a local HTTP server on an ephemeral port ... point `AVPlayer` at the playlist」；服务器**监听所有网卡**以便 AirPlay 接收机访问，带 per-session token / 32 连接上限 / 10s 头部超时 | https://raw.githubusercontent.com/superuser404notfound/AetherEngine/main/docs/architecture.md |
| V54 | 架构（software 路径）：libavcodec → `CVPixelBuffer`/`CMSampleBuffer` → `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`；用于 AV1/VP9/VP8/MPEG-4 Part 2/MPEG-2/VC-1/隔行 H.264 | 同上 |
| V55 | README：「The view is polymorphic: under the hood the engine swaps the hosted CALayer (`AVPlayerLayer` for the native AVPlayer path, `AVSampleBufferDisplayLayer` for the SW dav1d fallback path) per session without the host having to know.」 | README「What it is」段 |
| V56 | 格式覆盖（README 表）：容器 MKV/MP4/WebM/TS/AVI/ASF/OGG/FLV/RealMedia/3GP；HDR10/HDR10+/DV P5,P7,P8.1,P8.4/AV1 P10.x/HLG；音频含 TrueHD/MLP/DTS/DTS-HD MA；字幕文本 SRT/ASS/SSA/VTT/mov_text + 图形 PGS/DVB/DVD/VobSub（`CGImage`）+ CEA-608 + teletext；外挂文件为一等 track | README「What it handles」表 |
| V57 | Atmos：「EAC3+JOC stream-copied on every route (HDMI MAT 2.0, AirPods spatial, BT downmix)」 | 同上 |
| V58 | PiP：原生路径用 `currentAVPlayer` 或 `nativePlayerLayer` 建 `AVPictureInPictureController`；软解路径 `softwarePiPSource` 提供 `AVSampleBufferDisplayLayer`，且「the software path also composites active subtitle cues ... into the decoded frames」 | 同上 |
| V59 | API（README Quick start 原文）：`try AetherEngine()`、`AetherPlayerSurface(engine:)`、`player.bind(view:)`、`try await player.load(url:startPosition:options:)`、`player.play()/pause()/togglePlayPause()/setRate()/stop()`、`await player.seek(to:)`、`player.$state`（`.idle/.loading/.playing/.paused/.seeking/.ended/.error(String)`）、`player.$playbackPhase`、`player.clock.$currentTime/$sourceTime/$bufferedPosition`、`player.audioTracks`/`selectAudioTrack(index:)`、`player.subtitleTracks`/`selectSubtitleTrack(index:)`/`clearSubtitle()`、`player.$subtitleCues`、`player.addExternalSubtitleTrack(...)`、`player.setSoftwareSubtitleDelay(_:)` | README「Quick start」段 |
| V60 | **`setVolume` / `setMuted` 未出现在 README 与 `docs/api.md` 的 transport 段**（该段只列 `play/pause/togglePlayPause/setRate/seek/stop`） | README + https://raw.githubusercontent.com/superuser404notfound/AetherEngine/main/docs/api.md（**这是「没找到」，不是「不存在」**） |
| V61 | 字幕样式：`$subtitleCues` 的 cue body 为 `.text(String)` / `.richText([SubtitleTextRun])` / `.image(SubtitleImage)`；`.richText` 的 run 带 colour/bold/italic/underline/strikeout/font face/ASS 相对字号，cue 带 placement（numpad 对齐 + 可选 anchor） | README #233 段 |
| V62 | Now Playing：`ownsVideoNowPlayingSession`（默认 off）、`videoNowPlayingSession`、`setVideoNowPlayingInfo(_:)`；**macOS 上不提供系统 session**——architecture.md：「All of this is gated `#if os(tvOS) \|\| os(iOS)`; on macOS the path compiles and plays without the system session」 | README + architecture.md |
| V63 | 可选组件 4 个 trait **默认全关**：`TrueHDObjectAudio` / `DTSXObjectAudio` / `DualLayerDolbyVision` / `DolbyVisionStillReshaping`；「These components may be subject to third-party patent licensing. Integrators who enable them are responsible for their own licensing.」 | README「Optional components」段 |
| V64 | **XcodeGen 2.45.4 会静默丢弃 `traits:`**（README 原文：「XcodeGen cannot express them yet (2.45.4 drops a `traits:` key on a package without a word)」） | README「Optional components」段 |
| V65 | 落地案例 17 个，含 Sodalite（Jellyfin/Apple TV）、AetherPlayer（macOS）、Silo、Moonfin、Vivid、LillyPlayer 等 | README「Used by」段 |
| V66 | 作者自述：「AetherEngine is vibe-coded, designed and shipped by Vincent Herbst ... in close pair-programming with **Claude** (Anthropic). The commit log is the receipt: nearly every commit carries a `Co-Authored-By: Claude` trailer.」 | README「Built with」段 |
| V67 | 作者给的 benchmark（M1，4K HDR10 HEVC MKV 38 Mbit/s）：GPU 41 mW、CPU 4.4% of a core、RSS 342 MB；**但明示「produced by aetherengine-bench, which is run by this project's author」** | README「Measured」段 |

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
| **T11** | **AetherEngine 能否在 Xcode 27.1 / Swift 6.4 / 26.2+ SDK 下编译** | 只读了 Requirements，未实际构建 | §7.1 #1：加依赖、`swift build` |
| **T12** | **`setVolume` / `setMuted` 是否存在** | README 与 api.md 的 transport 段都没有；**不能据此断定不存在** | §7.1 #2：读 `Sources/AetherEngine/` 源码；或 grep `volume` |
| **T13** | **AetherEngine 的实际 .app 体积增量** | 只有 FFmpeg 的 22.7 MB 是已知数；引擎自身 + LibDovi + SMBClient 未测 | Release 构建后 `du -sh Prism.app`，与不含引擎的基线对比 |
| **T14** | **AetherEngine 依赖链首次拉取体积与耗时** | 未实测 | spike 时记录 `swift package resolve` 的网络量与耗时 |
| **T15** | **macOS 上 PiP 的缩放 bug 是否影响 AetherEngine 软解路径** | 该 bug 记录在 macOS 26.4 的 `AVSampleBufferDisplayLayer` PiP 上（Apple Forums），AetherEngine 软解路径正是用这个 layer | §7.1 #6：找一部 VP9/AV1 片源，开 PiP 看画面比例 |
| **T16** | **AetherEngine 的 ASS 渲染还原度 vs libass** | `.richText` 是近似，不是 libass 精确排版 | 用双语特效字幕样片对比 |
| **T17** | **AetherEngine 在 macOS 上的 HDR/DV 实际表现** | 需要 HDR 屏 + DV 素材；且 api.md 明说 macOS 无 per-mode 能力表（`AVPlayer.availableHDRModes` 是 `API_UNAVAILABLE(macos)`） | 用 HDR10/DV 样片在 XDR 屏上看；必要时设 `panelPresentsDolbyVision` |

### 9.3 无法确认 / 明确未查到

| # | 事项 | 说明 |
|---|---|---|
| U1 | **FSF 对「GPL/LGPL + App Store」的官方立场** | 抓取 `gnu.org/licenses/gpl-faq.html` 全文，搜 `App Store`/`iTunes`/`Apple`/`iPhone`，**命中数均为 0**。**FSF 没有专门条目**。任何「FSF 说……」的表述都是二手转述，本文不采用。 |
| U2 | **MPVKit 官方对 Swift 6 并发的支持声明** | GitHub 搜 `Sendable`/`concurrency` → **0 条**；搜 `swift 6` → 1 条无关 issue。**没有任何官方或社区记录**。本文的结论来自一次性离线实验（V16，不可复现），不是文档。 |
| U3 | **MPVKit 实际集成后的 .app 体积增量** | 没有任何 issue / 讨论 / 文档给出过这个数字。本文给的 67.6 MB 是**我自己 `lipo -thin` 后逐框架 stat 的结果**，不是项目方数据，也不等于最终 .app 增量。 |
| U4 | **mpv 路径的功耗数据** | 没有任何可引用的测量。本文只说「比 AVPlayer 重」，**不给具体数字**。 |
| U5 | **`vo=image` 失效的确切原因** | 未查明。可能是该构建的 image VO 依赖某个未链接的组件，或需要不同的选项组合。 |
| U6 | **Emby 是否会为 `SubtitleMethod=External` 的 ASS 提供独立字幕 URL** | 文档只列了枚举值，未说明各 method 的 URL 形态。需实测 `/Videos/{id}/{mediaSourceId}/Subtitles/{index}/Stream.ass`。 |
| **U7** | **AetherEngine 的 `setVolume` / `setMuted`** | 见 T12。**我明确没找到，但没有查源码**——这是「未查到」，不是「不存在」。 |
| **U8** | **AetherEngine 是否有官方的 `PlaybackEngine` 风格抽象** | 它自己就是引擎，不需要再抽象；但我们的协议是否需要它没有的成员（`removeSubtitleTrack`、`setSubtitleStyle`、`setVolume`），只能靠 spike 定 |
| **U9** | **AetherEngine 在 macOS 上的 AirPlay 视频路由是否真的可用** | README 与 api.md 的 AirPlay 讨论大量以 iOS/tvOS 为语境；macOS 上 AVPlayer 的 AirPlay 行为本身与 iOS 不同。**未查到 macOS 明确的 AirPlay 说明** |
| **U10** | **AetherEngine 的 macOS 支持成熟度** | 它有 AetherPlayer（macOS）和 DemoPlayerMac（notarized dmg）作为存在证明，但 README 的多数细节（PiP、Now Playing、background audio）都以 tvOS/iOS 为主语。**macOS 是否是二等公民，未查到明确说明** |

---

## 10. 附录：给实现者的检查清单

### 10.1 集成 AetherEngine 时（当前首选）

- [ ] 锁 `.upToNextMinor(from: "7.44.0")`（不要 `from:`，避免意外 minor 升级）
- [ ] **第一版不加任何 `traits`**（默认全关，避开 XcodeGen 丢 `traits:` 的坑）
- [ ] 确认 Xcode ≥ 27.0、Swift 6.4、SDK ≥ 26.2（否则编不过）
- [ ] `ownsVideoNowPlayingSession = false`（macOS 上不生效，我们自己用 `MPNowPlayingInfoCenter`）
- [ ] 订阅 `$playbackPhase` 而不是 `$state`（前者是统一真相源，含 `.rebuffering` / `.stalled`）
- [ ] 用 `clock.$sourceTime` 而不是 `clock.$currentTime` 去对字幕（`sourceTime` 是画面 PTS）
- [ ] 进 PiP 前设 `pictureInPictureActive = true`
- [ ] 若走软解路径，检查 `$airPlayPictureStaysLocal`，UI 上区分「画面留在本机」
- [ ] **首次构建记录实际耗时与体积**（T13/T14）

### 10.2 抽象层验收

- [ ] `grep -rl "import AetherEngine" --include="*.swift" . | grep -v AetherPlaybackEngine.swift` → 无输出
- [ ] `grep -rn "TrackInfo\|LoadOptions\|PlaybackPhase\|OpaquePointer" Sources/PrismPlayback/` → 无输出
- [ ] `PlaybackState` / `MediaTrack` / `PlaybackEvent` 全部 `Sendable`
- [ ] `videoSurface()` 返回 `AnyView`，调用方不需要知道底层是 `AVPlayerLayer` 还是 `ASBDL`
- [ ] `events` 的 `AsyncStream` 在视图销毁时正确终止（`onTermination` 里 cancel 掉 Combine 订阅）

### 10.3 降级路径验收

- [ ] MKV + DTS 文件能直连播放（不触发服务器转码）
- [ ] 播放失败时，`$errorInfo` 的 `PlaybackErrorKind` 被正确映射到我们的 `PlaybackFailureReason`
- [ ] 连续 3 次失败后停在 `.failed`，不无限重试
- [ ] `POST /Sessions/Playing` 的 `PlayMethod` 与实际路径一致（`DirectPlay` / `DirectStream` / `Transcode`）

### 10.4 集成 MPVKit 时（仅 Plan B）

- [ ] 按附录 A vendoring，**不使用 SwiftPM 远程依赖**
- [ ] 锁 `1.0.0`（非 prerelease）
- [ ] `strings Libavcodec | grep -i nonfree` → **必须无输出**
- [ ] `mpv_set_option_string(h, "ytdl", "no")` —— 默认是 `yes`
- [ ] `mpv_set_option_string(h, "config", "no")` —— 不读用户 `~/.config/mpv`
- [ ] 所有 mpv 选项在 `mpv_initialize` **之前**设置
- [ ] `wid` 传 `CAMetalLayer`，且 `MetalLayer` 的两个 workaround 必须抄
- [ ] `mpv_terminate_destroy` 在 `deinit` 的 `queue.sync` 里调用

---

## 附录 A：Vendoring 方案（仅 Plan B / MPVKit 需要）

### A.1 为什么当时放弃 SwiftPM（历史背景）

SwiftPM 拉取 GitHub 依赖时，会调用本机 git 的凭据助手。本机 `~/.gitconfig` 配置为：

```ini
[credential "https://github.com"]
	helper =
	helper = !/opt/homebrew/bin/gh auth git-credential
```

**注意这个坑**：第一行空 `helper =` 只是清空列表，第二行又把 `gh auth git-credential` 加了回去，所以实际生效的仍是 gh helper。因此「`GIT_CONFIG_COUNT=1` + 空 helper」这种压法**压不住**，仍会触发 macOS 钥匙串弹窗「swift-package 想要使用你储存在钥匙串的 github.com 机密信息」。

该弹窗在本项目已实际打断用户 **3 次**（2026-10-21）。这是**环境问题，不是技术不可行**——MPVKit 本身能用，只是获取方式不适合本机。

**结论：把二进制 vendoring 进仓库，一次性获取后固化。** 收益：

- 零网络、零 git、零钥匙串——构建期完全不触网
- CI 不需要联网，缓存策略简单
- 版本完全锁定，上游删 release 也不影响我们
- 可审计：二进制在仓库里，`strings`/`otool` 随时可查（对应 §8-R8 的 nonfree 复核）

代价：仓库体积显著增大（见附录 A.4）。

### A.2 目录结构

```
Prism/
├── ThirdParty/
│   └── MPVKit/
│       ├── VERSION                      # 记录来源：1.0.0 / mpv v0.41.0 / FFmpeg n8.1.2
│       ├── LICENSE-MPVKit-LGPL-3.0.txt
│       ├── LICENSE-libmpv.txt
│       ├── LICENSE-FFmpeg-LGPL.txt
│       ├── Libmpv.xcframework/
│       ├── Libavcodec.xcframework/
│       ├── Libavdevice.xcframework/
│       ├── Libavfilter.xcframework/
│       ├── Libavformat.xcframework/
│       ├── Libavutil.xcframework/
│       ├── Libswresample.xcframework/
│       ├── Libswscale.xcframework/
│       ├── Libass.xcframework/
│       ├── Libfreetype.xcframework/
│       ├── Libfribidi.xcframework/
│       ├── Libharfbuzz.xcframework/
│       ├── Libunibreak.xcframework/
│       ├── Libbluray.xcframework/
│       ├── Libuchardet.xcframework/
│       ├── Libdav1d.xcframework/
│       ├── Libuavs3d.xcframework/
│       ├── Libdovi.xcframework/
│       ├── Libplacebo.xcframework/
│       ├── Libshaderc_combined.xcframework/
│       ├── MoltenVK.xcframework/
│       ├── lcms2.xcframework/
│       ├── Libcrypto.xcframework/
│       ├── Libssl.xcframework/
│       ├── gmp.xcframework/
│       ├── nettle.xcframework/
│       ├── hogweed.xcframework/
│       ├── gnutls.xcframework/
│       └── Libluajit.xcframework/
└── Package.swift
```

**共 29 个 xcframework**（LGPL 分支所需，不含 `Libsmbclient` / 任何 `-GPL` 变体）。

> ⚠️ **不要** vendoring `*-all.zip` 里的内容（`FFmpeg-all.zip`、`libmpv-all.zip` 等汇总包）——那是给手工链接用的裸 `.a` + 头文件，SPM 用不上。只取 `*.xcframework.zip` 解压后的 `.xcframework` 目录。

### A.3 `Package.swift` 写法

```swift
// swift-tools-version:6.0
import PackageDescription

let mpvVendoredFrameworks = [
    "Libmpv", "Libavcodec", "Libavdevice", "Libavfilter",
    "Libavformat", "Libavutil", "Libswresample", "Libswscale",
    "Libass", "Libfreetype", "Libfribidi", "Libharfbuzz", "Libunibreak",
    "Libbluray", "Libuchardet", "Libdav1d", "Libuavs3d", "Libdovi",
    "Libplacebo", "Libshaderc_combined", "MoltenVK", "lcms2",
    "Libcrypto", "Libssl", "gmp", "nettle", "hogweed", "gnutls", "Libluajit",
]

let package = Package(
    name: "Prism",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PrismPlayback", targets: ["PrismPlayback"]),
    ],
    targets: [
        // 1) 所有 vendored 二进制，全部用 path 引用，零网络
        .target(
            name: "PrismMPVBinaries",
            dependencies: mpvVendoredFrameworks.map {
                .target(name: $0, condition: .when(platforms: [.macOS]))
            },
            path: "Sources/PrismMPVBinaries",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Cocoa"),
                .linkedFramework("IOKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("OpenGL"),
                .linkedFramework("CoreGraphics"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("expat"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),

        // 2) 播放抽象层：不含任何 Libmpv import
        .target(name: "PrismPlayback", path: "Sources/PrismPlayback"),

        // 3) libmpv 实现：唯一允许 import Libmpv 的地方
        .target(
            name: "PrismPlaybackMPV",
            dependencies: ["PrismPlayback", "PrismMPVBinaries"],
            path: "Sources/PrismPlaybackMPV"
        ),
    ]
        // 4) 逐个 binaryTarget(path:) —— 用循环生成，避免 29 段重复
        + mpvVendoredFrameworks.map { name in
            .binaryTarget(
                name: name,
                path: "ThirdParty/MPVKit/\(name).xcframework"
            )
        }
)
```

> **说明**：`binaryTarget` 不能写在 `targets:` 数组内部的条件表达式里，所以上面用「数组拼接」的形式把它们追加到 `targets`。`binaryTarget(path:)` 的 `path` 是**相对 `Package.swift` 所在目录**的路径，指向 `.xcframework` 目录本身（不是 zip）。

**关键点：**
- `binaryTarget(path:)` **完全不走网络**，SwiftPM 只做本地校验（读 `Info.plist`）。
- 不再需要 `checksum`（那是 `binaryTarget(url:)` 才要的）。
- 首次 `swift build` 不再下载任何东西，只解压/校验本地文件。

### A.4 Git LFS vs 直接提交

| 维度 | 直接提交（普通 git） | Git LFS |
|---|---|---|
| 仓库体积 | 每个 clone 拉全量 **~700 MB–1.3 GB** | clone 只拉指针，按需拉二进制 |
| 首次 clone 速度 | 慢（取决于网络） | 快（但 `lfs pull` 后仍要下） |
| CI 配置 | 零配置 | 需要 `git lfs install` + `lfs: true`（actions/checkout） |
| GitHub 限制 | 单文件 >100 MB 会被拒（**需确认：`.xcframework` 内单个二进制最大 15.7 MB，未超限**） | 免费额度 1 GB 存储 / 1 GB 月流量，**可能超** |
| 离线开发 | ✅ 天然支持 | 🟡 需要先 `lfs pull` |
| 可审计性 | ✅ 二进制在仓库里，`strings` 直接可查 | 🟡 需要 `lfs pull` 后才能查 |

**建议：直接提交（普通 git），不用 LFS。** 理由：

1. 我们的场景是**小团队 + 单一平台（macOS arm64）**，不是开源大项目。700 MB 的一次性 clone 成本可以接受。
2. **离线优先**：vendoring 的核心价值就是「不触网」。用 LFS 等于把网络依赖又加回来了（LFS 服务器也可能是 GitHub）。
3. **可审计性对我们更重要**：§8-R8 要求每次升级后 `strings | grep nonfree`。二进制直接在仓库里，任何人 clone 完就能查。
4. GitHub 的 100 MB 单文件限制**不会触发**（最大的 `Libshaderc_combined` arm64 slice 是 15.7 MB）。

> ⚠️ **但仓库体积会显著变大**。若团队无法接受，退化方案是：**只 vendoring macOS arm64 单切片**——用 `lipo -thin arm64` + `xcframework` 重建，可把 1.3 GB 降到约 270 MB（29 个框架的 arm64 slice 之和 67.6 MB × 各平台副本，实际以实测为准）。代价是放弃 Intel Mac 支持——**这与「部署目标 macOS 15+」并不冲突，但要产品明确是否放弃 Intel**。

### A.5 获取与固化步骤（一次性，由有网络的环境执行）

> 这一步**只需要做一次**，且**不要在本机代理会话里做**（会触发网络/凭据问题）。建议由用户或有网络的环境执行，产物直接 commit。

```bash
# 1) 建目录
mkdir -p ThirdParty/MPVKit && cd ThirdParty/MPVKit

# 2) 从 1.0.0 release 下载 29 个 xcframework
BASE=https://github.com/mpvkit/MPVKit/releases/download/1.0.0
for n in Libmpv Libavcodec Libavdevice Libavfilter Libavformat Libavutil Libswresample Libswscale; do
  curl -LO "$BASE/$n.xcframework.zip"
done
# 其余 21 个来自各自 build 仓库（openssl-build / gnutls-build / libass-build /
# libbluray-build / moltenvk-build / libshaderc-build / lcms2-build /
# libplacebo-build / libdovi-build / libdav1d-build / libuavs3d-build /
# libuchardet-build / libluajit-build），版本号见 §2.1.1 与 Package.swift 原文

# 3) 解压（每个 zip 解出来就是一个 .xcframework 目录）
for z in *.zip; do unzip -q "$z"; done && rm *.zip

# 4) 许可证合规复核（必须做，见 §8-R8）
strings Libavcodec.xcframework/macos-arm64_x86_64/Libavcodec.framework/Versions/A/Libavcodec \
  | grep -iE "nonfree|unredistributable"
# 期望：无输出。若出现 "nonfree and unredistributable" → 该版本不可用，换版本

# 5) 记录版本来源
cat > VERSION <<'EOF'
MPVKit 1.0.0 (2026-07-25, non-prerelease)
  mpv       v0.41.0
  FFmpeg    n8.1.2
  libplacebo 7.360.1
  MoltenVK  1.4.2
  libass    0.17.5
Source: https://github.com/mpvkit/MPVKit/releases/tag/1.0.0
EOF
```

### A.6 升级流程

升级 MPVKit 时**必须**走完这套，缺一不可：

1. 改 `VERSION` 文件里的版本号与上游 release URL。
2. 重新下载 + 解压，覆盖 `ThirdParty/MPVKit/`。
3. **`strings | grep nonfree` 复核**（§8-R8）——这是历史踩过的坑。
4. 检查 `Package.swift` 的 target 清单是否变化（上游可能新增/删除依赖，如新增 `Libsmbclient`）。
5. 跑一遍 §7.6 渲染验证清单。
6. 更新本文档 §2.1 的事实表。

### A.7 这个方案不解决什么

诚实说明边界：

- **不解决许可证问题**。vendoring 只是改变了「二进制怎么来」，LGPL-3.0 静态链接的 4d0 义务（§3.3）依然存在。详见 `docs/DECISION-mpv-license.md`。
- **不解决维护风险**。上游停更时，vendoring 反而让我们更难跟进（需要自己重新构建）。§8-R2 的「自建构建脚本」预案仍然需要。
- **不解决渲染未验证**。§7.6 的清单仍然是必须做的。
- **仓库体积代价真实存在**。若团队不接受 700 MB–1.3 GB，需要回到附录 A.4 的单切片方案或 LFS。
