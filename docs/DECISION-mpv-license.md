# 决策备忘：libmpv 的静态链接与 LGPL-3.0 合规

> 主管 ｜ 2026-10-21 ｜ 状态：**待用户拍板**
> 触发原因：播放引擎代理在核查 MPVKit 时报告「framework 实为静态库」，我复核后确认，并追加了更严重的结论。

---

## 1. 已核实事实（附证据）

| # | 事实 | 证据 |
|---|---|---|
| 1 | MPVKit 提供的 `Libmpv.xcframework` 是**静态库**，不是动态库 | 我下载 `Libmpv.xcframework.zip`（19.2 MB）解压后 `file` 结果：`Mach-O universal binary ... current ar archive`，`otool -hv` 显示 `filetype OBJECT`（归档成员） |
| 2 | MPVKit 的构建配置**只能产出静态库** | `Sources/BuildScripts/XCFrameworkBuild/base.swift` 中 meson 配置 `default_library = 'static'`；FFmpeg 配置含 `--enable-static --disable-shared` |
| 3 | MPVKit 许可证为 **LGPL-3.0**（LGPL 变体） | 仓库 LICENSE；README：「`MPVKit` bundles are also licensed under the LGPL v3.0」 |
| 4 | MPVKit 自述**维护频率低** | README 原文：「MPVKit is only suitable for learning `libmpv` and will not be maintained too frequently.」 |
| 5 | 最新稳定版 `1.0.0`（2026-07-25，非 prerelease）；`1.1.0-n9.0.2` 是 prerelease | GitHub Releases API `prerelease` 字段 |
| 6 | LGPL 分支首次构建需下载 **约 220–350 MB** 的 xcframework | 按 `Package.swift` 中非 GPL 的 binaryTarget URL 逐个 HEAD 累加得 346 MB（含 GPL 变体与 Libsmbclient 则为 556 MB）。SPM 实际下载量需实测，标【待验证】 |

---

## 2. 问题所在

LGPL-3.0 §4 规定：把库与「应用」结合成「组合作品」分发时，必须**三选一**满足：

- **4d0**：提供 Minimal Corresponding Source，**并以目标代码形式提供应用代码**，使接收者能重新链接修改版库；
- **4d1**：使用**合适的共享库机制**（动态链接），且能配合用户自行替换的接口兼容版本工作；
- 4d0/4d1 的组合。

**静态链接使 4d1 不可用**，只能走 4d0 —— 即**随 App 分发我们的目标文件（.o）**，让用户能自行重新链接。

对一个闭源分发的 macOS App 来说，这条义务很别扭：DMG 里要附带一堆 `.o`，或者提供可重链接的工程产物。

**同时注意**：这不是「有没有人告你」的问题，而是「你的分发形态是否合规」的问题。个人自用不构成「分发」（LGPL 只约束分发行为）；一旦公开下载就构成分发。

---

## 3. 三个可选方案

### 方案 A：照用 MPVKit 静态库，发布时附带目标文件（成本最低）
- 开发期完全不受影响。
- 发布时 DMG 内附 `Prism-objects.zip`（我们的 `.o` 或可重链接产物）+ MPVKit 的 Minimal Corresponding Source 链接 + 许可证全文。
- 风险：对普通用户是噪音；若将来想上架 App Store，此路彻底不通。
- 工作量：M5 时增加约 0.5 天。

### 方案 B：自建动态版 libmpv（合规最干净）
- 修改 MPVKit 构建脚本（`default_library = 'shared'`、FFmpeg `--enable-shared`），自行产出 `libmpv.dylib` 及依赖 dylib，嵌入 App 并逐个签名。
- 动态链接直接满足 4d1，**无需附带目标文件**。
- 代价：需要本地构建 mpv + FFmpeg + 依赖链（meson/ninja/python），一次构建可能 1–3 小时；产物需自己维护版本升级；CI 也要能重建。
- 风险：MPVKit 的构建脚本以静态为前提写了大量逻辑（`combineStaticLibraries`、`lipo -create` 合并 `.a`），改 shared 不是改一行，属于中等改造。

### 方案 C：换 VLCKit（LGPL-2.1，官方提供动态 framework）
- `videolan/vlckit` 提供 SPM `binaryTarget`，LGPL-2.1，动态 framework，合规路径成熟。
- 但：当前 SPM 指向的是 **VLCKit 4.0.0a21（alpha）**，稳定版 3.x 未提供同等 SPM 支持；我实测该 zip **922 MB**（含全平台切片）。
- 代价：换引擎意味着播放层封装、字幕/音轨 API、事件模型全部重写；且 alpha 版稳定性未知。

---

## 4. 主管建议

**短期（M0–M4 开发期）：方案 A，不折腾。**
开发期不存在分发行为，先用 MPVKit 静态库把功能跑通，把播放层封装在 `PlaybackEngine` 协议之后——这个抽象本来就已经在契约里，随时可换。

**发布前（M5）再定 A 还是 B。** 到那时我们已经知道：
- 是否真的要公开分发（自己用 → 无所谓）
- 是否需要 App Store（要 → 必须 B 或换 VLCKit）
- 静态链接的实际体验是否够用

**关键**：现在就把 `PlaybackEngine` 协议的边界守住，任何 MPVKit 特有类型（`OpaquePointer`、`mpv_handle`）**不得泄漏到 PrismPlayback 之外**。这样 B/C 的切换成本被限制在一个模块内。

---

## 5. 待用户确认

1. Prism 将来是**自己用**，还是**公开发布**？
2. 若公开发布，是否接受 DMG 附带目标文件（方案 A）？
3. 是否考虑**把 Prism 本身开源**？（若 Prism 以 GPL 兼容许可证开源，LGPL 静态链接问题直接消失，这是最省事的合规路径，但对商业化不利。）
