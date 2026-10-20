# 事实核查规范（团队强制）

> 用户硬性要求：**不确定的必须联网搜索，不许瞎写。**
> 违反本规范的交付一律打回，不计入完成。

## 1. 必须核查的内容类别

| 类别 | 例子 | 最低核查标准 |
|---|---|---|
| API 端点 / 参数 / 字段名 | `/Users/{id}/Items`、`PositionTicks`、`DeviceProfile` | 官方 API 文档或官方仓库源码，附 URL |
| 第三方库的许可证 | MPVKit LGPL vs GPL、GRDB MIT | 仓库 LICENSE 文件或官方页面 |
| 版本号与集成方式 | MPVKit 1.1.0-n9.0.2、Sparkle 2 的 SPM 坐标 | 官方 Release / README |
| 平台与系统限制 | AVPlayer 不支持 MKV、libmpv 无系统 PiP | Apple 官方文档 / 上游项目文档 |
| 配置项字面量 | entitlements key、Info.plist key、project.yml 字段 | 官方配置文档，逐字比对 |
| 性能与体积数字 | 「包体增加 xx MB」「滚动 60fps」 | 有实测或来源引用，否则标【待验证】 |
| 竞品功能 | Infuse 支持 PGS、Swiftfin PR #593 | App Store 页 / 官方仓库 / PR 链接 |

## 2. 证据等级与标注规则

| 标记 | 含义 | 用法 |
|---|---|---|
| ✅ 已核实 | 官方文档 / 官方源码 / 官方 Release 明确写出 | 必须附可点击 URL |
| ◐ 多方一致 | 多个独立来源一致，但无官方明文 | 列出 2 个以上来源 |
| ○ 待验证 | 无法确认，或仅凭推断 | **必须写明验证方法**，不得当作事实使用 |
| ✗ 已证伪 | 查证后确认不成立 | 写明反证来源，避免后人再踩 |

**禁止**：用肯定语气陈述 ○ 级内容；把 Jellyfin 的结论直接当 Emby 的结论；把「我记得」当证据。

## 3. 冲突处理

官方文档 > 官方仓库源码/Release Note > 厂商博客 > 社区讨论（StackOverflow/Reddit/GitHub Issue）。
出现冲突时：以官方为准，同时在文档中记录分歧点与各自来源。

## 4. 交付要求

每个代理的报告与文档末尾必须有「**事实核查记录**」一节：

```markdown
## 事实核查记录
- ✅ Emby 认证端点 `/Users/AuthenticateByName` — https://dev.emby.media/...
- ✅ MPVKit 许可证 LGPL-3.0 — https://github.com/mpvkit/MPVKit/blob/main/LICENSE
- ◐ libmpv 在 macOS 上推荐 wid 嵌入 — 来源A / 来源B
- ○ Emby 4.9 是否改动 PlaybackInfo 返回结构 — 验证方法：真实服务器 curl 对比
- ✗ altool 已废弃，改用 notarytool — https://developer.apple.com/...
```

## 5. 代码中的引用

代码注释里对关键常量、魔法值、平台 workaround 必须给文档链接，例如：

```swift
/// 1 tick = 100ns，故 10_000_000 ticks = 1s。
/// https://dev.emby.media/reference/RestAPI/... 
public struct Ticks: ...
```

## 6. 主管抽查

每波次合并前，主管随机抽查 3 条 ✅ 结论，验证 URL 是否真实支撑结论。
抽查不通过 → 整份交付打回。
