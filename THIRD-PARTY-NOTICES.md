# 第三方组件声明（Third-Party Notices）

Prism 以 **GNU GPL v3.0**（`GPL-3.0-only`）发布。本项目包含或链接以下第三方组件，各自遵循其自身许可证。

> 本文件随发布更新。所有链接在提交时均已核对可访问（2026-10-21）。

---

## 1. 播放内核与多媒体

### AetherEngine
- **用途**：播放引擎（FFmpeg demux + VideoToolbox 解码 + AVPlayer 处理 Dolby Atmos/Vision）
- **许可证**：**LGPL-3.0 + Apple Store / DRM Exception**
- **版权**：Copyright (C) 2026 Vincent Herbst
- **源码**：https://github.com/superuser404notfound/AetherEngine
- **集成方式**：SPM 依赖，锁定版本
- **许可证例外说明**：该例外通过 GPLv3 §7 附加许可，明确允许经由 Apple App Store、TestFlight
  等第三方平台分发（即使平台条款限制二进制重签名）。
- **LGPL §4(d)(0) 义务的履行**：Prism 本身以 GPL-3.0 开源，完整源码见本仓库，
  因此「提供可重链接的应用代码」这一义务已自动满足。

### FFmpegBuild
- **用途**：FFmpeg 二进制发行（AetherEngine 的解复用与解码后端）
- **许可证**：LGPL-3.0
- **源码**：https://github.com/superuser404notfound/FFmpegBuild
- **注意**：本项目**不启用** GPL 组件（`--enable-gpl`）。若将来启用，FFmpeg 将转为 GPL，
  而 Prism 本身已是 GPL-3.0，仍然兼容。

### LibDovi
- **用途**：Dolby Vision RPU 元数据处理
- **许可证**：LGPL-3.0
- **源码**：https://github.com/superuser404notfound/LibDovi

### LibTrueHD（可选，默认不启用）
- **用途**：TrueHD Atmos 对象音频渲染
- **许可证**：LGPL-3.0
- **源码**：https://github.com/superuser404notfound/LibTrueHD
- **说明**：仅在启用 `TrueHDObjectAudio` trait 时链接。默认关闭。

> **关于专利**：AetherEngine 的部分可选组件（TrueHD 对象音频、DTS:X、双层杜比视界）可能涉及
> 第三方专利许可。本项目**默认全部关闭**，不启用这些组件。

---

## 2. 应用依赖（计划中）

### GRDB.swift
- **用途**：SQLite 封装，用于媒体元数据与播放进度缓存
- **许可证**：MIT
- **版权**：Copyright (C) 2015-2024 Gwendal Roué
- **源码**：https://github.com/groue/GRDB.swift

### Nuke
- **用途**：图片加载与缓存（海报、背景图）
- **许可证**：MIT
- **版权**：Copyright (C) 2015-2024 Alexander Grebenyuk
- **源码**：https://github.com/kean/Nuke

### Sparkle（计划中）
- **用途**：应用自动更新
- **许可证**：MIT（含部分 BSD 风格条款）
- **源码**：https://github.com/sparkle-project/Sparkle

---

## 3. 系统框架

以下为 Apple 系统框架，随 macOS 提供，不随本项目分发：

AppKit · SwiftUI · AVFoundation · AVKit · CoreMedia · VideoToolbox · Metal · Network ·
Security（Keychain）· OSLog · Combine · Observation

---

## 4. 商标声明

- **Emby** 是 Emby LLC 的商标。Prism 是**独立开发的第三方客户端**，与 Emby LLC
  **无任何关联、未获其背书或赞助**。
- **Dolby**、**Dolby Vision**、**Dolby Atmos** 是 Dolby Laboratories 的商标。
- **Apple**、**macOS**、**Xcode**、**App Store** 是 Apple Inc. 的商标。

本项目中出现的上述名称仅用于说明兼容性与功能，不表示任何形式的关联或授权。

---

## 5. 许可证全文

各许可证完整文本可通过上述链接获取。GPL-3.0 与 LGPL-3.0 全文亦可在
https://www.gnu.org/licenses/ 获取。

Prism 自身的许可证全文见仓库根目录的 [LICENSE](LICENSE)。