# Prism

macOS 上的 Emby 客户端。SwiftUI 原生界面，AetherEngine 播放内核。

## 功能

- **连接**：手动填地址或局域网自动发现（UDP 7359），凭据存 Keychain
- **浏览**：首页（继续观看 / 接下来 / 最新）、媒体库网格、筛选排序、搜索
- **详情**：电影与剧集两套布局，季集列表，演职员，相似推荐
- **播放**：MKV/MP4 直连，H.264/HEVC/AV1 硬解，ASS/PGS 字幕，多音轨，HDR / 杜比视界
- **续播**：进度上报服务器，跨设备一致
- **双语**：中文 / English

暂不支持：音乐库、Live TV、远程控制、多用户、离线下载。

## 安装

从 [Releases](https://github.com/fuunylmz/Prism/releases) 下载 DMG，拖进 Applications。

> 当前未公证（没有 Apple 开发者证书），首次打开需要**右键 → 打开**。

## 从源码构建

需要 macOS 15+ 与 Xcode 26+。

```bash
./scripts/bootstrap.sh   # 生成 Xcode 工程
./scripts/build.sh       # 产出 build/Build/Products/Debug/Prism.app
./scripts/run.sh         # 构建并启动
```

打包：

```bash
./scripts/release.sh --skip-notarize   # 本地用，产出 release/Prism-<版本>.dmg
```

构建环境有问题先看 [docs/BUILD_ENV.md](docs/BUILD_ENV.md)。

### 没有服务器也能看界面

```bash
open -a "$PWD/build/Build/Products/Debug/Prism.app" --args -DemoMode YES
```

演示模式内置 26 部电影、8 部剧（148 集）、3 个合集，海报与视频都是代码生成的，不联网。

## 结构

```
App/                     App target：@main、Info.plist、entitlements、资源
Sources/
  PrismCore/             模型、解码、日志、设置
  EmbyAPI/               Emby 网络层、DTO、端点、服务器发现
  PrismData/             Keychain 会话、图片管线
  PrismPlayback/         播放引擎适配、协商、进度上报
  PrismUI/               设计系统与全部界面
Tests/                   按模块划分的单元测试
scripts/                 bootstrap / build / test / run / release
docs/                    架构、路线图、调研、构建环境
```

依赖只能向下：

```
PrismUI ──▶ PrismData ──▶ EmbyAPI ──▶ PrismCore
   └─────▶ PrismPlayback ──▶ EmbyAPI
```

工程文件 `Prism.xcodeproj` 由 `project.yml` 生成，**不要手改 pbxproj**——改 `project.yml` 后重跑 `bootstrap.sh`。

## 许可

[GNU GPL v3.0](LICENSE)。

播放内核 [AetherEngine](https://github.com/superuser404notfound/AetherEngine) 为 LGPL-3.0（含 App Store/DRM 例外），
其余第三方组件与商标声明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

本项目是 Emby 的第三方客户端，与 Emby LLC 无关联。
