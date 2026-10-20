# Emby Server HTTP API 参考（Prism / macOS Swift 客户端实现指南）

> **目标服务器**：Emby Server 4.8.x / 4.9.x
> **兼容目标**：Jellyfin 10.9+
> **客户端技术栈**：Swift + URLSession + async/await（macOS 原生）
> **文档版本**：2026-10-21
> **配套文件**：[verified-facts.md](./verified-facts.md)（主管核查的基础事实库）、[playback.md](./playback.md)、[macos-engineering.md](./macos-engineering.md)
> **编写原则**：每一条端点/参数/字段均标注来源 URL；无法从官方资料确认的一律标 `⚠️【待验证】`，并写明验证方法。

---

## 0. 阅读约定（置信度标记）

本文所有技术断言都带下列标记之一，**开发代理请按标记决定信任程度**：

| 标记 | 含义 | 处理方式 |
|---|---|---|
| ✅ | **已核实**：Emby 官方 Reference 页 / REST 文档 / 官方源码 明确写出 | 可直接实现 |
| ◐ | **社区一致**：多个真实客户端源码或抓包样例一致，但官方文档未明确 | 可实现，但需容错 |
| ⚠️ | **待验证**：仅推断或资料冲突 | 必须先实测再依赖，文中给出验证方法 |

**权威来源优先级**（本文据此判定）：

| 级别 | 来源 | 说明 |
|---|---|---|
| 1 | **Emby Reference 页**（每端点一页，由当前版本代码生成）：<https://dev.emby.media/reference/RestAPI.html> | **字段/参数冲突时的最终依据** |
| 2 | Emby REST 文档（人写的指南）：<https://dev.emby.media/doc/restapi/index.html> | 讲流程与语义，但部分页面陈旧 |
| 3 | Emby OpenAPI 规范：<https://swagger.emby.media/openapi.json> | ⚠️ **是 4.1.1.0 的旧快照**，见下 |
| 4 | Jellyfin OpenAPI：<https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json> | **仅用于交叉验证**，不可当作 Emby 文档 |

> ### 🚨 关键前提：`swagger.emby.media/openapi.json` 是一份旧快照
>
> 该文件的 `info.version` 是 **`4.1.1.0`**（不是 4.8/4.9）。实测比对发现它**落后于当前 Reference 页**：
>
> | schema | OpenAPI（4.1.1.0） | Reference 页（当前） | 差异 |
> |---|---|---|---|
> | `PlaybackStartInfo` | 21 字段 | **30 字段** | 缺 `EventName`、`SleepTimerMode`、`SleepTimerEndTime`、`Shuffle`、`PlaylistIndex`、`PlaylistLength`、`PlaylistItemIds`、`SubtitleOffset`、`PlaybackRate` |
> | `PlaybackInfoRequest` | 18 字段 | **19 字段** | 缺 `CurrentPlaySessionId`、`AllowInterlacedVideoStreamCopy`；多 `DirectPlayProtocols` |
> | `PlaybackStopInfo` | 11 字段 | **14 字段** | 缺 `IsAutomated` 等 |
>
> - 证据：<https://swagger.emby.media/openapi.json> → `info.version = "4.1.1.0"`
> - **本文所有字段表都以 Reference 页为准**，OpenAPI 只用来核对拼写与类型、以及确认"某个端点是否存在"。
> - **开发代理注意**：不要用 OpenAPI 生成的代码去反序列化 Emby 4.8/4.9 的请求体，会丢字段。

> ⚠️ **重要前提**：Jellyfin 与 Emby 同源 —— Jellyfin 源自 Emby 的 **3.5.2** 版本（2018 年 12 月 fork，之后 Emby 4.x 转为闭源）。因此两者大量端点一致，但**并不完全一致**（Emby 3.5.2 → 4.8/4.9 又演进了 5 年）。
> - ✅ 同源来源：<https://jellyfin.org/docs/general/about>（"Jellyfin is descended from Emby's 3.5.2 release and ported to the .NET Core framework"）
> - 凡是从 Jellyfin 侧确认、Emby 侧未确认的，本文一律标注 `Jellyfin 侧确认，Emby 待验证`。

---

## 1. 通用约定

### 1.1 Base URL

```
http[s]://{host}:{port}/emby/{apipath}
```

- ✅ 来源：<https://dev.emby.media/doc/restapi/index.html>（"The Emby Server API can be reached via: `http[s]://hostname:port/emby/{apipath}`"）
- 默认端口 **8096**（HTTP）、**8920**（HTTPS）。
- 官方示例 URL 均为 `/emby/...` 前缀，例如 `http://localhost:8096/emby/Users/{id}/Items`（✅ 来源：<https://dev.emby.media/doc/restapi/Browsing-the-Library.html>）。

**⚠️ 根路径回退**：Emby 实际是否同时接受**不带 `/emby` 前缀**的根路径（如 `http://host:8096/System/Info/Public`），官方文档未说明。
- 社区反向代理配置把 `/` 直接代理到 `8096` 且工作正常（◐ 来源：<https://emby.media/community/topic/40461-emby-server-with-apache-reverse-proxy>）。
- **建议实现**：以 `/emby` 为规范 base；首次连接时先试 `/emby/System/Info/Public`，若 404 再试 `/System/Info/Public`，把成功的那个 base 存进凭据。
- **验证方法**：`curl -i http://HOST:8096/System/Info/Public`，看是否 200。

### 1.2 请求/响应格式

- 支持 JSON 与 XML，由 `Content-Type` 控制，取值 `application/json` 或 `application/xml`。
- ✅ 来源：<https://dev.emby.media/doc/restapi/index.html>
- **客户端固定用 `application/json`**，并在请求头显式声明，避免服务器按 Accept 返回 XML。

### 1.3 时间与 Ticks

- `RunTimeTicks`、`PositionTicks`、`StartPositionTicks` 等均为 **.NET ticks**：**1 tick = 100 ns**，即 **10,000,000 ticks = 1 秒**。
- ✅ 换算依据（实测数据自洽）：真实样例 `RunTimeTicks: 56743358464` 对应 5674.3 秒 ≈ 94.6 分钟，符合一部电影时长（样例来源：<https://gist.github.com/kylehowells/74f538c766a244a3666319860a937030>）。
- ⚠️ **官方 Swagger 的说明是错的**：`/Videos/{Id}/stream` 的 `StartTimeTicks` 描述写作 "1 tick = 10000 ms"，按此换算 56743358464 ticks = 657 万天，显然荒谬。
  - 错误来源：<https://dev.emby.media/reference/RestAPI/VideoService/getVideosByIdStream.html>
  - **不要照抄这句话**。正确换算：

```swift
extension Int64 {
    /// Emby ticks (100ns) -> 秒
    var embySeconds: Double { Double(self) / 10_000_000.0 }
    /// 秒 -> Emby ticks
    static func embyTicks(fromSeconds s: Double) -> Int64 { Int64(s * 10_000_000.0) }
}
```

- **日期格式**：`DateCreated`、`PremiereDate`、`LastActivityDate` 等为 ISO-8601 字符串，形如 `2014-05-15T09:52:52.5898360Z`（✅ 来源：<https://dev.emby.media/doc/restapi/Remote-Control.html> 中的真实 session 样例）。
  - ⚠️ 小数位是 **7 位**（.NET "O" 格式），`ISO8601DateFormatter` 默认只吃 3 位毫秒 → **解析会失败**。必须用 `DateFormatter` 配 `yyyy-MM-dd'T'HH:mm:ss.SSSSSSSZZZZZ`，或先截断到 3 位小数。
  - 例外：`POST /Users/{UserId}/PlayedItems/{Id}` 的 `DatePlayed` 参数格式是 **`yyyyMMddHHmmss`**（✅ 来源：<https://dev.emby.media/reference/RestAPI/PlaystateService/postUsersByUseridPlayeditemsById.html>）。

### 1.4 错误码

| 码 | 含义 | 客户端处理 |
|---|---|---|
| 200 | 成功 | — |
| 400 | Bad Request | 参数错误，打日志 |
| 401 | Unauthorized，**通常表示 token 已被吊销** | 跳回登录页，清除本地 token |
| 403 | 无权限（如该用户被禁用下载） | 提示无权限 |
| 404 | 资源不存在（图片最常见） | 走回退图 |
| 429 | 限流 | 指数退避重试 |
| 500 | 服务器错误 | 重试 1 次后报错 |

- ✅ 401 语义来源：<https://dev.emby.media/doc/restapi/User-Authentication.html>（"if any http requests fail with a 401 response status code, this is generally an indication that the access token has been revoked"）
- ⚠️ **429 / RateLimit**：Emby 官方文档**没有**公布 API 速率限制。社区 FAQ 提到 429 会出现（来源：<https://emby.wiki/en/faq>，"Stop retrying; wait for rate limits"）。
  - **建议**：不要做「每秒 N 次」的硬编码假设；对 429 做指数退避（1s/2s/4s，最多 3 次）；图片与元数据批量拉取并发上限设 6。
  - **验证方法**：对真实服务器用 `for i in $(seq 1 200); do curl -s -o /dev/null -w "%{http_code}\n" ...; done` 压测观察是否出现 429。

---

## 2. 认证

### 2.1 鉴权头格式 ✅

```
Authorization: Emby UserId="<guid>", Client="<client>", Device="<device>", DeviceId="<id>", Version="<ver>", Token="<token>"
```

| 字段 | 含义 |
|---|---|
| `UserId` | 当前登录用户 Id（未登录时省略） |
| `Client` | 客户端类型（Android、Dashboard、Dlna、iOS、PC、WindowsPhone、WindowsRT、other） |
| `Device` | 设备产品名 |
| `DeviceId` | 设备唯一 Id |
| `Version` | 客户端版本 |
| `Token` | 访问令牌（登录时还没有，可省略） |

- ✅ 头部名称可以是 `Authorization` **或** `X-Emby-Authorization`，二者等价。
- ✅ 来源：<https://dev.emby.media/doc/restapi/User-Authentication.html>
- ✅ 来源（规范原文）：<https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html>（"The authorization header can be either named 'Authorization' or 'X-Emby-Authorization'. It must be of the following schema: `Emby UserId="(guid)", Client="(string)", Device="(string)", DeviceId="(string)", Version="string", Token="(string)"`"）
- ✅ Jellyfin 侧解析逻辑同样从该头里取 DeviceId/Device/Client/Version/Token，并回退到 `X-Emby-Token` → `X-MediaBrowser-Token` → `api_key` 查询参数（源码：<https://github.com/jellyfin/jellyfin/blob/79baaa7/Emby.Server.Implementations/HttpServer/Security/AuthorizationContext.cs>）

**Swift 构造**（注意：`DeviceId` 必须**持久化**，不能每次启动重新生成，否则服务器会把它当新设备，播放会话/转码复用/已看进度归属都会错乱）：

```swift
enum EmbyAuthHeader {
    static func value(client: String = "Prism",
                      device: String,
                      deviceId: String,
                      version: String,
                      userId: String? = nil,
                      token: String? = nil) -> String {
        // ⚠️ 协议名 `Emby` 与字段之间是**空格**，字段之间才是 `, `。
        // 曾经写在这里的错误示范：把 "Emby" 也放进数组再统一用 ", " 拼接，
        // 会产出 `Emby, UserId="..."`，服务端会把 scheme 解析成 `Emby,`。
        // 由 T1.2 传输层代理抓出并修正。
        var fields: [String] = []
        if let userId { fields.append("UserId=\"\(userId)\"") }
        fields.append("Client=\"\(client)\"")
        fields.append("Device=\"\(device)\"")
        fields.append("DeviceId=\"\(deviceId)\"")
        fields.append("Version=\"\(version)\"")
        if let token { fields.append("Token=\"\(token)\"") }
        return "Emby " + fields.joined(separator: ", ")
    }
}
```

> ⚠️ 两处分隔符不同：**协议名之后是空格**，**字段之间是逗号 + 空格**，且整个值**不要**加外层引号。
> 建议实现后用 `header.hasPrefix("Emby ")` 做一次断言（T1.2 的单测就是这么抓到 bug 的）。

### 2.2 用户登录 ✅

```
POST /emby/Users/AuthenticateByName
Content-Type: application/json
X-Emby-Authorization: Emby Client="Prism", Device="MacBook Pro", DeviceId="...", Version="1.0.0"
```

**请求体**（`AuthenticateUserByName`）：

```json
{
  "Username": "alice",
  "Pw": "plaintext-password"
}
```

- ✅ **密码字段名是 `Pw`，不是 `Password`**。来源：<https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html>（`AuthenticateUserByName` 定义：`Username: string`、`Pw: string`）
- ✅ 密码为**明文**传输（"The password must be sent in the body: pw - password in plain text"）。因此 **必须走 HTTPS**，否则凭据裸奔。
- ✅ `X-Emby-Authorization` 在该端点的规范中被标为 **required**。

**响应 200**（`AuthenticationResult`）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `AccessToken` | string | 后续请求的令牌 |
| `ServerId` | string | 服务器 Id（多服务器场景必须与 token 一起存） |
| `User` | UserDto | 用户对象 |
| `SessionInfo` | SessionInfo | 会话对象 |

- ✅ 来源：<https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html>

**UserDto 关键字段** ✅：`Name`、`ServerId`、`ServerName`、`Id`、`PrimaryImageTag`、`HasPassword`、`LastLoginDate`、`LastActivityDate`、`DateCreated`、`Configuration`、`Policy`。
- 其中 `Policy.EnableSync`（是否允许同步/下载）、`Policy.EnableContentDownloading`、`Policy.IsAdministrator`、`Policy.EnableMediaPlayback` 对客户端功能开关很重要（✅ 来源：同页 `UserPolicy` 定义）。

#### ⚠️ 已知文档/实现不一致：`User` 是对象还是数组？

官方 Swagger 把 `AuthenticationResult.User` 标注为 **`UserDto[]`（数组）**，但 Emby 实际返回的是**单个对象**。

- ✅ 文档侧证据：<https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html>（Definitions → AuthenticationResult → `User | UserDto[]`）
- ◐ 实现侧证据：所有真实客户端（Jellyfin Web、Swiftfin、jellyfin-apiclient-python）都按**单对象**解析。
- **结论：必须做兼容解码**，两种形态都要能吃。

```swift
/// 既能解单个对象，也能解单元素数组
struct OneOrMany<T: Decodable>: Decodable {
    let value: T

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let one = try? c.decode(T.self) {
            value = one
        } else {
            value = try c.decode([T].self)[0]
        }
    }
}

struct AuthenticationResult: Decodable {
    let accessToken: String
    let serverId: String?
    let user: UserDto
    let sessionInfo: SessionInfo?

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case serverId    = "ServerId"
        case user        = "User"
        case sessionInfo = "SessionInfo"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        serverId    = try c.decodeIfPresent(String.self, forKey: .serverId)
        user        = try c.decode(OneOrMany<UserDto>.self, forKey: .user).value
        sessionInfo = try? c.decodeIfPresent(OneOrMany<SessionInfo>.self, forKey: .sessionInfo)?.value
    }
}
```

> 同一问题也适用于 `PlaybackStartInfo.Item`、`PlaybackStopInfo.Item`（规范标为 `BaseItemDto[]`）——**同样用 `OneOrMany` 兜底**。

### 2.3 携带 Token ✅

后续所有请求用请求头：

```
X-Emby-Token: <AccessToken>
```

- ✅ 来源：<https://dev.emby.media/doc/restapi/User-Authentication.html>（"This should be included in all subsequent Http requests using the header **X-Emby-Token**"）

> 也可以把 token 拼进 `X-Emby-Authorization` 的 `Token="..."` 字段，两种都行（服务器优先读头里的 Token 字段，其次 `X-Emby-Token`）。**建议两个都发**，最大化兼容。

### 2.4 登出 ✅

```
POST /emby/Sessions/Logout
X-Emby-Token: <AccessToken>
```

- ✅ 会**吊销**该 token。来源：<https://dev.emby.media/doc/restapi/User-Authentication.html>
- 若用户只是关掉 App 没点登出，**不要**调这个接口，直接保存 token 下次复用（官方明确建议）。

### 2.5 API Key 方式 ✅

- 两种传法：
  - 请求头 `X-Emby-Token: <api_key>`
  - 查询参数 `?api_key=<api_key>`
- ✅ 来源：<https://dev.emby.media/doc/restapi/API-Key-Authentication.html>
- 用途：不绑定某个用户的服务端集成。**客户端 App 不要用 API Key**（它没有用户上下文，`/Users/{userId}/Items` 这类端点会拿不到 UserData）。
- 创建路径：Dashboard → Expert → Advanced → Security → Add。

### 2.6 公开信息（登录前探测）✅

```
GET /emby/System/Info/Public
```

**响应 `PublicSystemInfo`**：

| 字段 | 类型 | 说明 |
|---|---|---|
| `Id` | string | 服务器 Id（用于多服务器去重/绑定） |
| `ServerName` | string | 服务器显示名 |
| `Version` | string | 版本号，如 `4.8.11.0` |
| `LocalAddress` | string | 局域网地址 |
| `WanAddress` | string | 公网地址 |
| `OperatingSystem` | string | 操作系统 |

- ✅ 来源（字段全集）：<https://swagger.emby.media/openapi.json> → `/System/Info/Public` → `PublicSystemInfo`
- ✅ 来源（页面）：<https://dev.emby.media/reference/RestAPI/SystemService/getSystemInfoPublic.html>

**用途**：手动填 URL 后第一件事就是打这个接口 —— 200 即代表「这是一台 Emby/Jellyfin 服务器」，同时拿到 `ServerName`/`Version` 做展示、`Id` 做多服务器主键。**这一步不需要 token**。

**登录前的用户列表**（可选，做头像式登录页）：

```
GET /emby/Users/Public
```

- 返回 `UserDto[]`，含 `Name`、`Id`、`PrimaryImageTag`、`HasPassword`。
- ✅ 来源：<https://dev.emby.media/doc/restapi/User-Authentication.html>（"Make a call to /Users/Public to get all public users… Each user has a HasPassword property. This is used to determine if the user should be prompted to input a password. **The application must authenticate regardless of this value.**"）
- 若返回空数组 → 直接展示用户名/密码表单。

---

## 3. 服务器发现

### 3.1 局域网 UDP 广播 7359 ✅

**协议**：向 UDP 端口 **7359** 发送**广播**报文，正文**恰好**是：

```
who is EmbyServer?
```

（区分大小写，含问号，无换行）

**响应**：一个 JSON 对象，含三个属性：

| 字段 | 说明 |
|---|---|
| `Address` | 服务器地址（形如 `http://192.168.1.10:8096`） |
| `Id` | 服务器 Id |
| `Name` | 服务器名称 |

- ✅ 来源：<https://dev.emby.media/doc/restapi/Locating-the-Server.html>（"Simply send a udp broadcast message on port 7359, with the text **"who is EmbyServer?"**. You'll receive a message that is a Json structure containing three properties: Address, Id, Name."）
- ✅ 镜像来源：<https://github.com/MediaBrowser/Emby/wiki/Locating-the-Server>

**⚠️ 高频踩坑：Jellyfin 的报文不一样**

| 服务器 | 广播文本 | WebSocket 路径 |
|---|---|---|
| **Emby** | `who is EmbyServer?` | `/embywebsocket` |
| **Jellyfin** | `Who is JellyfinServer?` | `/socket` |

- Jellyfin 侧来源（源码）：<https://github.com/jellyfin/Swiftfin/blob/530bc1c/Shared/ServerDiscovery/ServerDiscovery.swift>（`try self.connection?.sendBroadcast("Who is JellyfinServer?")`）
- ⚠️ 注意：linuxserver 的 Jellyfin 文档写作 `Who is Jellyfin Server?`（带空格，<https://github.com/linuxserver/docker-jellyfin/blob/master/readme-vars.yml>），与 Swiftfin 源码**不一致**。以源码为准（无空格）；若要稳妥，两个都发。
- 若 Prism 要同时发现两类服务器，**必须分别发两种报文**，各自解析。Emby 不会回应 Jellyfin 的报文，反之亦然（◐ 由两份实现推断，建议实测）。

**实现要点**（Swift / Network.framework 或 BSD socket）：

```swift
// 关键 socket 选项（与 Jellyfin 客户端一致的做法）
// 1. SO_BROADCAST = 1
// 2. 绑定 0.0.0.0:0（随机端口），不要绑 7359 —— 7359 是服务器的监听端口
// 3. 目标地址发 255.255.255.255:7359；子网定向广播（如 192.168.1.255:7359）命中率更高
// 4. 接收超时 1~3 秒，收集这段时间内所有响应（可能有多个服务器）
```

- ◐ 参考实现（Jellyfin 客户端）：<https://github.com/jellyfin/jellyfin-apiclient-python/blob/b6561909/jellyfin_apiclient_python/connection_manager.py#L248-L284>（设置 `SO_BROADCAST`、`IP_MULTICAST_TTL`、超时 1.0s）
- ⚠️ **macOS 沙盒**：App 若开启 App Sandbox，需要 `com.apple.security.network.client`（发广播）与 `com.apple.security.network.server`（收 UDP 回包）权限。首次广播可能触发「本地网络」隐私弹窗（macOS 15+ 需要 `NSLocalNetworkUsageDescription`）。**验证方法**：在沙盒构建里跑一次发现流程，确认能收到回包。

**去重**：同一台服务器可能从多个网卡返回多次，用 `Id` 去重。

### 3.2 手动填 URL

最可靠的方式，作为兜底始终保留：

1. 用户输入 `http://192.168.1.10:8096` 或 `https://emby.example.com`。
2. 规范化：补 `http://`、去尾部 `/`、去尾部 `/emby`（保存 base 时自己拼 `/emby`）。
3. 请求 `GET {base}/System/Info/Public`，200 则成功，记录 `Id`/`ServerName`/`Version`。
4. 失败给出明确错误（超时 / 非 Emby 服务器 / 证书问题）。

- ✅ 官方建议：多服务器连通性应**先**用手动地址实现，再补 Emby Connect（"we recommend that you first implement multi-server switching in your app via manual address entry, and then later supplement that with Emby Connect"）。来源：<https://dev.emby.media/doc/restapi/Emby-Connect.html>

### 3.3 Emby Connect（connect.emby.media）✅

**流程概要**（全部来自 <https://dev.emby.media/doc/restapi/Emby-Connect.html>）：

**① 登录 Connect**

```
POST https://connect.emby.media/service/user/authenticate
Content-Type: application/json
X-Application: Prism/1.0.0
```

Body：`{ "nameOrEmail": "<username>", "rawpw": "<password>" }`

响应含：`ConnectAccessToken`、`ConnectUserId`。

> 注：文档正文把第二个字段写作 `ConnectUserId`，但后续 `/service/servers?userId={ConnectUserId}` 的请求头里用的是 `X-Connect-UserToken`（值为 ConnectAccessToken）。文档用词略混乱，**以实际抓包为准** —— ⚠️【待验证】。

**② 拉服务器列表**

```
GET https://connect.emby.media/service/servers?userId={ConnectUserId}
X-Application: Prism/1.0.0
X-Connect-UserToken: {ConnectAccessToken}
```

返回数组，每项含：`AccessKey`、`SystemId`、`Name`、`Url`（远程地址）、`LocalAddress`（局域网地址）。

**③ 用 AccessKey 换本地 AccessToken**（每次连接都要换，**必须持久化原始 AccessKey**）

```
GET {serverBase}/Connect/Exchange?format=json&ConnectUserId={ConnectUserId}
X-Emby-Token: {AccessKey}
X-Emby-Authorization: Emby Client="Prism", Device="...", DeviceId="...", Version="..."
```

返回：`LocalUserId`、`AccessToken`。之后用这对凭据访问该服务器。

- ✅ 端点存在性交叉验证：Emby OpenAPI 含 `GET /Connect/Exchange`（<https://swagger.emby.media/openapi.json>）
- **MVP 建议**：P2。先做手动 URL + UDP 发现，Emby Connect 后置。

---

## 4. 媒体库

### 4.1 顶层视图：`GET /Users/{userId}/Views` ✅

```
GET /emby/Users/{userId}/Views?IncludeExternalContent=false
```

| 参数 | 类型 | 说明 |
|---|---|---|
| `userId` | path | 用户 Id |
| `IncludeExternalContent` | bool | 是否包含 channels / 直播电视等外部视图 |

**响应**：`QueryResult<BaseItemDto>`

```json
{
  "Items": [ { "Name": "Movies", "Id": "...", "CollectionType": "movies", "Type": "CollectionFolder", "IsFolder": true } ],
  "TotalRecordCount": 1
}
```

- ✅ 参数来源：<https://dev.emby.media/reference/RestAPI/UserViewsService/getUsersByUseridViews.html>
- ✅ 返回类型 `QueryResult_BaseItemDto` 来源：<https://swagger.emby.media/openapi.json> → `/Users/{UserId}/Views`

**`CollectionType` 取值** ✅（决定用哪种 UI 呈现）：

`movies`、`tvshows`、`music`、`games`、`books`、`musicvideos`、`homevideos`、`livetv`、`channels`；为 `null` 表示混合文件夹，按通用方式浏览。

- ✅ 来源：<https://dev.emby.media/doc/restapi/Browsing-the-Library.html>

### 4.2 列表查询：`GET /Users/{userId}/Items` ✅

这是整个客户端最核心的端点。

```
GET /emby/Users/{userId}/Items
    ?ParentId={viewId}
    &Recursive=true
    &IncludeItemTypes=Movie
    &Fields=PrimaryImageAspectRatio,ProductionYear,UserData,RunTimeTicks
    &SortBy=SortName&SortOrder=Ascending
    &StartIndex=0&Limit=60
```

#### 常用参数（全部 ✅，来源见下）

| 参数 | 类型 | 语义 |
|---|---|---|
| `ParentId` | string | 限定在某文件夹/视图内；**省略则从根开始** |
| `Recursive` | bool | 是否递归子文件夹 |
| `IncludeItemTypes` | string | 只返回这些类型，**逗号分隔**。如 `Movie`、`Series`、`Episode`、`Audio`、`MusicAlbum`、`BoxSet`、`Playlist` |
| `ExcludeItemTypes` | string | 排除类型，逗号分隔 |
| `Fields` | string | **额外字段**，逗号分隔（见 4.3） |
| `SortBy` | string | 排序字段，**逗号分隔可多字段**（见 4.4） |
| `SortOrder` | string | `Ascending` / `Descending`，**逗号分隔，与 SortBy 一一对应** |
| `Filters` | string | 逗号分隔，取值见下 |
| `IsPlayed` | bool | 只看已看/未看 |
| `IsFavorite` | bool | 只看收藏 |
| `Genres` | string | 类型过滤，**竖线 `\|` 分隔**（注意不是逗号！） |
| `Years` | string | 年份过滤，**逗号分隔** |
| `OfficialRatings` | string | 分级过滤，**竖线分隔** |
| `Tags` / `ExcludeTags` | string | 标签过滤，**竖线分隔** |
| `Studios` / `StudioIds` | string | 制片厂，竖线分隔 |
| `Person` / `PersonIds` / `PersonTypes` | string | 按演员过滤，逗号分隔 |
| `SearchTerm` | string | 搜索词 |
| `StartIndex` | int | 分页起点（0 基） |
| `Limit` | int | 每页条数 |
| `EnableImages` | bool | 是否返回图片信息 |
| `EnableUserData` | bool | 是否返回 `UserData` |
| `ImageTypeLimit` | int | **每种图片类型最多返回几个**（Backdrop 多图时用它限流） |
| `EnableImageTypes` | string | 只要这些图片类型，如 `Primary,Backdrop,Thumb` |
| `MediaTypes` | string | `Video` / `Audio` / `Photo` / `Book` |
| `Ids` | string | 直接按 Id 列表取，逗号分隔 |
| `MinCommunityRating` / `MinCriticRating` | number | 评分下限 |
| `HasSubtitles` | bool | 有字幕 |
| `IsHD` | bool | 高清 |
| `IsUnaired` | bool | 未播出 |
| `MinPremiereDate` / `MaxPremiereDate` | string | ISO 日期区间 |
| `GroupItemsIntoCollections` | bool | 是否把 boxset 内的条目折叠 |
| `NameStartsWith` / `NameStartsWithOrGreater` / `NameLessThan` | string | 字母索引（A-Z 快速跳转） |

- ✅ 完整参数表（**84 个**，逐个统计自 OpenAPI）：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>
- ✅ 机器可读全量：<https://swagger.emby.media/openapi.json> → `/Users/{UserId}/Items` → `get`

**`Filters` 取值** ✅：`IsFolder`、`IsNotFolder`、`IsUnplayed`、`IsPlayed`、`IsFavorite`、`IsResumable`、`Likes`、`Dislikes`
- ✅ 来源：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>（Filters 参数说明）

**`IncludeItemTypes` 取值**（常用子集，◐ **Jellyfin 侧确认，Emby 待验证**）：
`Movie`、`Series`、`Season`、`Episode`、`BoxSet`、`Playlist`、`MusicAlbum`、`MusicArtist`、`Audio`、`AudioBook`、`MusicVideo`、`Video`、`Trailer`、`Person`、`Photo`、`PhotoAlbum`、`Folder`、`CollectionFolder`、`Genre`、`Studio`、`Year`
- 来源：<https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json> → `BaseItemKind`
- ⚠️ Emby 的 OpenAPI 对 `IncludeItemTypes` **没有声明 enum**（是自由字符串），所以这份列表是从 Jellyfin 枚举推断的。Emby 的 `BaseItemDto.Type` 取值与之一致（见 4.5），但**并非每个类型名都做过实测**。
- **验证方法**：对 Emby 分别请求 `IncludeItemTypes=Movie`、`=Series`、`=Episode`、`=BoxSet`、`=Playlist`，看 `TotalRecordCount` 是否合理（非 0 且不等于全库数）。
- ◐ Emby 侧类型名与此一致（Emby 的 `Type` 字段取值同源），但**并非每个都做过实测**。

#### 响应结构 ✅

```json
{
  "Items": [ /* BaseItemDto[] */ ],
  "TotalRecordCount": 1234
}
```

- **`TotalRecordCount` 是过滤后的总数**，不是本页条数 —— 用它算总页数、判断是否还有下一页。
- ✅ 来源：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>（`QueryResult_BaseItemDto` 定义：`Items: BaseItemDto[]`、`TotalRecordCount: integer(int32)`）

### 4.3 `Fields`（ItemFields）—— ⚠️ 最大的坑

**列表接口默认只返回极简字段**，`Overview`、`People`、`MediaSources`、`Chapters` 等**全部为空**，必须显式用 `Fields=` 请求。

- ✅ 来源：<https://dev.emby.media/doc/restapi/Browsing-the-Library.html>（"When requesting lists of items, the data coming back will be much smaller… If you want to add additional fields to the items, use the fields param"）

#### ⚠️ Swagger 里的 Fields 列表是**过时的子集**

Swagger 参数说明只列了 17 个：
`Budget, Chapters, DateCreated, Genres, HomePageUrl, IndexOptions, MediaStreams, Overview, ParentId, Path, People, ProviderIds, PrimaryImageAspectRatio, Revenue, SortName, Studios, Taglines`

而 Emby 4.x 的 `MediaBrowser.Model.Querying.ItemFields` 枚举**实际有 97 个成员**。以枚举为准。

- ✅ 过时说明来源：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>
- ✅ 权威枚举来源：<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Querying.ItemFields.html>

**完整 `ItemFields` 枚举（97 项，✅ 逐字摘自上述官方页面）**：

```
AirDays, AirTime, Album, AlbumId, AlternateMediaSources, AudioCodec, AverageFrameRate,
BasicSyncInfo, Bitrate, CanDelete, CanDownload, ChannelImage, ChannelInfo,
ChannelMappingInfo, ChannelNumber, Chapters, ChildCount, CollectionName, Collections,
CommunityRating, Container, ContainerSyncStatus, CriticRating, CustomRating,
DateCreated, DateLastRefreshed, DateLastSaved, DateModified, DisplayOrder,
DisplayPreferencesId, EndDate, Etag, ExternalId, ExternalUrls, ExtraIds, ExtraType,
FileName, Genres, Guid, Height, Id, IndexNumber, IsInMixedFolder, IsPublic,
IsVirtualItem, ItemCounts, LocalTrailerCount, MediaSources, MediaStreams, MimeType,
Name, OfficialRating, OriginalTitle, Overview, ParentId, PartCount, Path, People,
PlayAccess, Prefix, PremiereDate, PresentationUniqueKey, PrimaryImageAspectRatio,
ProductionLocations, ProductionYear, ProgramFields, ProgramPrimaryImageAspectRatio,
ProviderIds, RealFrameRate, RecursiveItemCount, RemoteTrailers, RunTimeTicks,
SeasonCount, SeasonUserData, SeriesId, SeriesName, SeriesPresentationUniqueKey,
SeriesPrimaryImage, SeriesStudio, Settings, ShareLevel, Size, SortName,
SpecialEpisodeNumbers, SpecialFeatureCount, StartDate, Status, Studios, SubViews,
SyncStatus, Taglines, Tags, UserDataLastPlayedDate, UserDataPlayCount, Video3DFormat,
VideoCodec, Width
```

> 注意：`Genres` 这个 Field 同时会带出 `GenreItems`（Name/Id 对），✅ 来源：<https://dev.emby.media/doc/restapi/Item-Information.html>（"GenreItems - Request this field via Genres"）。

**Prism 推荐 Fields 组合**（按场景）：

| 场景 | Fields |
|---|---|
| 海报墙（列表） | `PrimaryImageAspectRatio,ProductionYear,UserData,RunTimeTicks,OfficialRating,CommunityRating` |
| 详情页 | `Overview,Genres,People,Studios,ProviderIds,Taglines,Chapters,MediaSources,MediaStreams,ProductionYear,PremiereDate,DateCreated,PrimaryImageAspectRatio,UserData,SeriesStudio` |
| 剧集列表 | `Overview,UserData,RunTimeTicks,PrimaryImageAspectRatio,MediaSources` |
| 音乐专辑 | `Genres,ProductionYear,UserData,ChildCount` |
| 同步/下载判断 | `CanDownload,SupportsSync,SyncStatus,BasicSyncInfo,Size` |

> `SupportsSync` 需要 `SyncInfo`/`BasicSyncInfo` 字段才返回（✅ 来源：<https://dev.emby.media/doc/restapi/Sync.html>："You will need to include SyncInfo as part of your requested fields in order to make this property available"）。
> ⚠️ 但 `ItemFields` 枚举里**没有**叫 `SyncInfo` 的成员，只有 `BasicSyncInfo` 和 `SyncStatus`。**建议请求 `BasicSyncInfo,SyncStatus`** ——【待验证】：实测 `Fields=SyncInfo` 是否被接受。

### 4.4 `SortBy` 多字段语法 ✅

```
SortBy=ProductionYear,PremiereDate,SortName&SortOrder=Descending,Descending,Ascending
```

- ✅ `SortBy` 与 `SortOrder` **都是逗号分隔，且按位置一一对应**；`SortOrder` 项数少于 `SortBy` 时，官方未说明补什么（⚠️【待验证】：建议**永远写满等长**）。
- ✅ 来源：<https://dev.emby.media/doc/restapi/Browsing-the-Library.html>（原文示例即 `SortBy=ProductionYear,PremiereDate,SortName&SortOrder=Descending,Descending,Ascending`）

**`SortBy` 可选值** ✅（Swagger 描述）：
`Album, AlbumArtist, Artist, Budget, CommunityRating, CriticRating, DateCreated, DatePlayed, PlayCount, PremiereDate, ProductionYear, SortName, Random, Revenue, Runtime`
- ✅ 来源：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>

**`SortBy` 可选值**（Jellyfin 枚举更全，◐ Emby 未必全支持）：
`Default, AiredEpisodeOrder, Album, AlbumArtist, Artist, DateCreated, OfficialRating, DatePlayed, PremiereDate, StartDate, SortName, Name, Random, Runtime, CommunityRating, ProductionYear, PlayCount, CriticRating, IsFolder, IsUnplayed, IsPlayed, SeriesSortName, VideoBitRate, AirTime, Studio, IsFavoriteOrLiked, DateLastContentAdded, SeriesDatePlayed, ParentIndexNumber, IndexNumber`
- 来源：<https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json> → `ItemSortBy`
- ⚠️ 用 Emby 未列出的值（如 `Name`、`IndexNumber`）可能被**静默忽略**（退回默认排序）。**验证方法**：对同一查询分别用 `SortBy=Name` 和 `SortBy=SortName`，比较返回顺序。

### 4.5 条目核心字段语义 ✅

以下均来自 <https://dev.emby.media/doc/restapi/Item-Information.html> 与 <https://swagger.emby.media/openapi.json> → `BaseItemDto`：

| 字段 | 类型 | 语义 |
|---|---|---|
| `Id` | string | 条目 Id（32 位无连字符 hex，如 `0f8d0805a66f7ed429ecd8890146c7c3`） |
| `Name` | string | 显示名 |
| `ServerId` | string | 服务器 Id |
| `Type` | string | 精确类型：`Movie`/`Episode`/`Season`/`Series`/`Audio`/`MusicAlbum`/`BoxSet`/`Playlist`… |
| `MediaType` | string | 粗粒度：`Video`/`Audio`/`Photo`/`Book` |
| `IsFolder` | bool | 是否是容器（决定点进去还是直接播） |
| `CollectionType` | string | 视图类型（见 4.1） |
| `RunTimeTicks` | int64 | 时长（ticks，÷10,000,000 = 秒） |
| `ProductionYear` | int | 出品年 |
| `PremiereDate` | datetime | 首播/上映日期 |
| `IndexNumber` | int | **含义随类型变化**：Episode=集号，Season=季号，Audio=音轨号 |
| `ParentIndexNumber` | int | **含义随类型变化**：Episode=季号，Audio=碟号 |
| `IndexNumberEnd` | int | 跨集文件的结束集号 |
| `SeriesId` | string | 所属剧集 Id（Episode/Season 有） |
| `SeriesName` | string | 所属剧名 |
| `SeasonId` | string | 所属季 Id（Episode 有） |
| `SeasonName` | string | 季名 |
| `Album` / `AlbumId` / `AlbumArtist` / `Artists` | string / string / string / string[] | 音乐相关 |
| `ImageTags` | object | **图片类型 → tag** 的映射，如 `{"Primary":"abc123","Logo":"def456"}` |
| `BackdropImageTags` | string[] | 背景图 tag 数组（**有几张就有几项**） |
| `ParentBackdropImageTags` | string[] | 可继承的父级背景图 tag |
| `ParentBackdropItemId` | string | 提供背景图的父级条目 Id |
| `SeriesPrimaryImageTag` | string | 所属剧集的海报 tag（Episode 上取剧海报用） |
| `PrimaryImageItemId` | string | 主图实际所属的条目 Id（可能是父级） |
| `ParentThumbItemId` / `ParentThumbImageTag` | string | 可继承的缩略图来源 |
| `ParentLogoItemId` / `ParentLogoImageTag` | string | 可继承的 Logo 来源 |
| `PrimaryImageAspectRatio` | double | 主图宽高比（**Primary 唯一不固定比例，必须用它排版**） |
| `UserData` | object | 用户数据（见下） |
| `MediaSources` | MediaSourceInfo[] | 媒体源（需 `Fields=MediaSources`） |
| `MediaStreams` | MediaStream[] | 音视频/字幕轨（需 `Fields=MediaStreams`；官方已注明**应仅用于展示**，播放请用 MediaSources） |
| `People` | BaseItemPerson[] | 演职员（需 `Fields=People`） |
| `Chapters` | ChapterInfo[] | 章节（需 `Fields=Chapters`） |
| `Overview` | string | 简介（需 `Fields=Overview`） |
| `OfficialRating` | string | 分级：`G`/`PG-13`/`R`/`TV-MA`… |
| `CommunityRating` / `CriticRating` | double | 社区/媒体评分 |
| `Genres` | string[] | 类型标签 |
| `ProviderIds` | object | 外部 Id：`{"Tmdb":"12345","Imdb":"tt1234567","Tvdb":"..."}` |
| `Path` | string | 文件路径（需 `Fields=Path`） |
| `Container` | string | 容器格式：`mkv`/`mp4`/`ts`… |
| `SortName` | string | 排序名（去掉 "The " 等前缀） |
| `ChildCount` | int | 直接子项数 |
| `RecursiveItemCount` | int | 递归子项数 |
| `LocationType` | string | `FileSystem`/`Remote`/`Virtual` |
| `CanDownload` | bool | 是否允许下载 |
| `SupportsSync` | bool | 是否支持同步（需 `BasicSyncInfo`） |
| `Etag` | string | 条目元数据版本（可用于本地缓存失效判断） |
| `Status` | string | 剧集状态：`Continuing`/`Ended` |
| `AirDays` / `AirTime` | string[] / string | 播出星期/时间（Series） |
| `Studios` | NameLongIdPair[] | 制片厂 |
| `Taglines` | string[] | 宣传语 |
| `ExternalUrls` | ExternalUrl[] | 外部链接 |
| `RemoteTrailers` | MediaUrl[] | 在线预告片 |
| `LocalTrailerCount` | int | 本地预告片数 |
| `PartCount` | int | 多文件视频的分片数 |
| `SpecialFeatureCount` | int | 花絮数 |
| `Width` / `Height` | int | 分辨率（需 `Fields=Width,Height`） |

**`UserData`（`UserItemDataDto`）字段** ✅：

| 字段 | 类型 | 语义 |
|---|---|---|
| `Played` | bool | 是否已看完 |
| `PlaybackPositionTicks` | int64 | **续播位置**（"继续观看"就靠它） |
| `PlayCount` | int | 播放次数 |
| `IsFavorite` | bool | 是否收藏 |
| `LastPlayedDate` | datetime | 最后播放时间 |
| `PlayedPercentage` | double | 已看百分比（文件夹用） |
| `UnplayedItemCount` | int | 未看子项数（文件夹用） |
| `Rating` | double | 个人评分 |
| `ItemId` | string | 对应条目 Id |
| `Key` | string | 内部键（一般忽略） |
| `ServerId` | string | 服务器 Id（官方注明"仅 Windows 应用使用"） |
| `Likes` | bool? | 喜欢/不喜欢 —— ⚠️ **见下** |

- ✅ 来源（**当前 Reference 的 11 个字段**）：<https://dev.emby.media/reference/RestAPI/UserLibraryService/postUsersByUseridItemsByIdRating.html>（`UserItemDataDto` 定义段）
- ⚠️ **`Likes` 字段存疑**：旧 OpenAPI 快照（4.1.1.0）的 `UserItemDataDto` **有** `Likes` 但**没有** `ServerId`；当前 Reference 页**有** `ServerId` 但**没有** `Likes`。
  - 说明 `Likes` 可能已在 4.x 某版本从 DTO 中移除，或改由别的机制表达。
  - **但 `Likes` 作为 `/Users/{UserId}/Items/{Id}/Rating` 的 query 参数仍然存在且必填**（✅ 同页 `*Likes | query`，必填标记 `*`）。
  - **实现建议**：`Likes` 解码为 `Bool?` 且**允许缺失**；不要用 `UserData.Likes` 驱动 UI 的"喜欢"按钮状态，改用本地状态 + 从 `Rating` 端点返回的 DTO 推断，或直接重新拉取条目详情。
  - ⚠️【待验证】：在真实 4.8/4.9 服务器上对某条目 POST 一次 `Rating?Likes=true`，看返回的 DTO 里有没有 `Likes`。

**`People`（`BaseItemPerson`）字段** ✅：`Name`、`Id`、`Role`（角色名）、`Type`（`Actor`/`Director`/`Writer`/`Producer`/`GuestStar`…）、`PrimaryImageTag`

**`Chapters`（`ChapterInfo`）字段** ✅：`StartPositionTicks`、`Name`、`ImageTag`

**`MediaStream` 关键字段** ✅：`Type`（`Video`/`Audio`/`Subtitle`/`EmbeddedImage`/`Attachment`）、`Index`、`Codec`、`Language`、`DisplayTitle`、`DisplayLanguage`、`IsDefault`、`IsForced`、`IsExternal`、`IsTextSubtitleStream`、`SupportsExternalStream`、`DeliveryMethod`（`Encode`/`Embed`/`External`/`Hls`）、`DeliveryUrl`、`Width`/`Height`、`BitRate`、`Channels`、`SampleRate`、`Profile`、`Level`、`VideoRange`、`IsInterlaced`、`PixelFormat`、`AspectRatio`、`AttachmentSize`

---

## 5. 条目详情、季/集、相似、演职员、章节、媒体源

### 5.1 单条目详情 ✅

```
GET /emby/Users/{userId}/Items/{itemId}
```

**返回完整 `BaseItemDto`**（不需要 `Fields`，单条查询会返回全部字段）。

- ✅ 来源：<https://dev.emby.media/doc/restapi/Browsing-the-Library.html>（"When you request a single item using the /Users/{UserId}/Items/{Id} api, you will get back the entire item."）
- ✅ 端点：<https://dev.emby.media/reference/RestAPI/UserLibraryService/getUsersByUseridItemsById.html>
- ✅ 返回类型 `BaseItemDto`：<https://swagger.emby.media/openapi.json>

> 仍需注意：`MediaSources` 是否填充取决于服务器配置；若为空，调 5.6 的 PlaybackInfo。

### 5.2 季列表 ✅

```
GET /emby/Shows/{seriesId}/Seasons?UserId={userId}&Fields=Overview,UserData,PrimaryImageAspectRatio
```

| 参数 | 说明 |
|---|---|
| `UserId` | 用户 Id（带 UserData 必需） |
| `Fields` | 同上 |
| `IsSpecialSeason` | 只看/排除特别季 |
| `IsMissing` | 只看缺失集 |
| `EnableImages` / `ImageTypeLimit` / `EnableImageTypes` / `EnableUserData` | 同上 |

- ✅ 来源：<https://swagger.emby.media/openapi.json> → `/Shows/{Id}/Seasons`
- ✅ 页面：<https://dev.emby.media/reference/RestAPI/TvShowsService/getShowsByIdSeasons.html>
- 返回 `QueryResult<BaseItemDto>`。

### 5.3 集列表 ✅

```
GET /emby/Shows/{seriesId}/Episodes
    ?UserId={userId}
    &SeasonId={seasonId}
    &Fields=Overview,UserData,RunTimeTicks,PrimaryImageAspectRatio,MediaSources
    &SortBy=ParentIndexNumber,IndexNumber&SortOrder=Ascending,Ascending
```

| 参数 | 说明 |
|---|---|
| `UserId` | 用户 Id |
| `Season` | **季号**（int，如 `2`）—— 与 `SeasonId` 二选一 |
| `SeasonId` | **季 Id**（string） |
| `IsMissing` | 只看缺失集 |
| `AdjacentTo` | 返回某集的兄弟集（上下集） |
| `StartItemId` | 从某集开始 |
| `StartIndex` / `Limit` | 分页 |
| `Fields` | 同上 |
| `SortBy` / `SortOrder` | 同上 |
| `EnableImages` / `ImageTypeLimit` / `EnableImageTypes` / `EnableUserData` | 同上 |

- ✅ 来源：<https://dev.emby.media/reference/RestAPI/TvShowsService/getShowsByIdEpisodes.html>
- ✅ 机器可读：<https://swagger.emby.media/openapi.json> → `/Shows/{Id}/Episodes`
- 返回 `QueryResult<BaseItemDto>`。

### 5.4 NextUp（下一集）✅

```
GET /emby/Shows/NextUp?UserId={userId}&Limit=24&Fields=Overview,UserData,PrimaryImageAspectRatio
```

| 参数 | 说明 |
|---|---|
| `UserId` | 用户 Id |
| `SeriesId` | 限定某剧 |
| `ParentId` | 限定某视图/文件夹 |
| `StartIndex` / `Limit` | 分页 |
| `Fields` | 同上 |
| `EnableImages` / `ImageTypeLimit` / `EnableImageTypes` / `EnableUserData` | 同上 |

- ✅ 来源：<https://dev.emby.media/reference/RestAPI/TvShowsService/getShowsNextup.html>
- ✅ 机器可读：<https://swagger.emby.media/openapi.json> → `/Shows/NextUp`
- 语义：**"下一集"**——用户看过但没看完的剧，返回下一集；从未看过的剧通常从 S01E01 开始。返回 `QueryResult<BaseItemDto>`。

### 5.5 相似内容 ✅

```
GET /emby/Items/{itemId}/Similar?UserId={userId}&Limit=12&Fields=PrimaryImageAspectRatio,ProductionYear,UserData
```

| 参数 | 说明 |
|---|---|
| `IncludeItemTypes` | 限定类型，如 `Movie` |
| `UserId` | 带上则返回 UserData |
| `Limit` | 条数 |
| `Fields` | 同上 |
| `EnableImages` / `ImageTypeLimit` / `EnableImageTypes` / `EnableUserData` | 同上 |

- ✅ 来源：<https://dev.emby.media/reference/RestAPI/LibraryService/getItemsByIdSimilar.html>
- ✅ 机器可读：<https://swagger.emby.media/openapi.json> → `/Items/{Id}/Similar`
- 另有按类型的别名端点：`/Movies/{Id}/Similar`、`/Shows/{Id}/Similar`、`/Albums/{Id}/Similar`、`/Artists/{Id}/Similar`、`/Trailers/{Id}/Similar`、`/Games/{Id}/Similar`（✅ 均在 Emby OpenAPI 中）
- 返回 `QueryResult<BaseItemDto>`（不是数组！）

### 5.6 演职员 ✅

**方式 A（推荐）**：详情页 `Fields=People`，读 `BaseItemDto.People[]`。

**方式 B**：单独查某人

```
GET /emby/Persons/{name}?UserId={userId}
```

- ✅ 来源：<https://swagger.emby.media/openapi.json> → `/Persons/{Name}`

**人物头像**：

```
GET /emby/Persons/{name}/Images/{Type}?maxWidth=200&tag={PrimaryImageTag}
```

- ✅ 路径存在：<https://swagger.emby.media/openapi.json> → `/Persons/{Name}/Images/{Type}`
- ⚠️ **注意**：人物图片按 **Name** 寻址（不是 Id）。Name 含空格/中文时**必须 URL 编码**，且同名人物会撞车 —— 【待验证】是否有按 Id 的等价端点（Emby OpenAPI 中未见 `/Persons/{Id}/Images/...`）。

### 5.7 章节 ✅

- 在详情请求里加 `Fields=Chapters`，读 `BaseItemDto.Chapters[]`。
- 每项：`StartPositionTicks`、`Name`、`ImageTag`。
- ✅ 来源：<https://dev.emby.media/doc/restapi/Item-Information.html>（"Chapters - This is applicable to videos only. This will give you the list of chapter markers contained within the video."）
- 章节缩略图：`GET /Items/{itemId}/Images/Chapter/{index}?tag={ImageTag}`（见第 8 节）
- ⚠️ Emby 4.9 起可在库设置里**自动生成章节**（4.9.1.0 release notes："Add library options to control generation of chapters when none are embedded within video files"，<https://github.com/MediaBrowser/Emby.Releases/releases/tag/4.9.1.0>），所以 `Chapters` 可能非空但文件本身无章节标记。

### 5.8 媒体源 ✅

- 详情：`Fields=MediaSources` → `BaseItemDto.MediaSources[]`（`MediaSourceInfo`）。
- 播放：`POST /Items/{Id}/PlaybackInfo`（见第 6 节），返回的 `MediaSources` 才是**已按你的 DeviceProfile 计算过**的版本。

`MediaSourceInfo` 关键字段 ✅（<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Dto.MediaSourceInfo.html>）：

| 字段 | 类型 | 语义 |
|---|---|---|
| `Id` | string | **MediaSourceId**，后续所有播放/上报都要带 |
| `Name` | string | 版本显示名（多版本时用它做选择界面） |
| `Path` | string | 文件路径（DirectPlay 时客户端若能直读文件系统可用） |
| `Container` | string | 容器 |
| `RunTimeTicks` | int64 | **本媒体源**时长（多版本可能不同！用这个，别用条目的） |
| `Bitrate` | int | 总码率（bps） |
| `Size` | int64 | 字节数 |
| `SupportsDirectPlay` | bool | 支持直连 |
| `SupportsDirectStream` | bool | 支持直封 |
| `SupportsTranscoding` | bool | 支持转码 |
| `DirectStreamUrl` | string | 直封/直连 URL（**Emby 有，Jellyfin 无**，见 6.4） |
| `TranscodingUrl` | string | 转码 URL（相对路径） |
| `TranscodingSubProtocol` | string | `http` / `hls` |
| `TranscodingContainer` | string | 转码输出容器，如 `ts` |
| `MediaStreams` | MediaStream[] | 轨道 |
| `DefaultAudioStreamIndex` | int | 默认音轨 Index |
| `DefaultSubtitleStreamIndex` | int | 默认字幕 Index（`-1` = 无） |
| `RequiredHttpHeaders` | object | 拉流时**必须**附带的额外请求头（如 `User-Agent`） |
| `Protocol` | string | `File`/`Http`/`Rtsp`… |
| `IsRemote` | bool | 是否远程源 |
| `LiveStreamId` | string | 直播流 Id |
| `Chapters` | ChapterInfo[] | 章节（本媒体源的） |
| `MimeType` | string | 源 MIME |
| `TranscodingMimeType` | string | 转码输出 MIME |
| `ItemId` | string | 所属条目 Id（官方注明「仅 Windows 应用使用」） |
| `ContainerStartTimeTicks` | int64 | 容器起始时间 |

---

## 6. 播放协商（PlaybackInfo）

### 6.1 端点 ✅

```
POST /emby/Items/{itemId}/PlaybackInfo
Content-Type: application/json
X-Emby-Token: <token>
```

**请求体 `PlaybackInfoRequest`**（Emby 走 body）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `UserId` | string | 用户 Id |
| `MaxStreamingBitrate` | int64 | 码率上限（bps），如 `8000000` |
| `StartTimeTicks` | int64 | 起播位置 |
| `AudioStreamIndex` | int | 指定音轨 |
| `SubtitleStreamIndex` | int | 指定字幕（`-1` = 关） |
| `MaxAudioChannels` | int | 最大声道数（`2` = 立体声） |
| `MediaSourceId` | string | 指定媒体源（多版本时） |
| `LiveStreamId` | string | 直播流 |
| `DeviceProfile` | DeviceProfile | **能力描述，见 6.2** |
| `EnableDirectPlay` | bool | 允许直连 |
| `EnableDirectStream` | bool | 允许直封 |
| `EnableTranscoding` | bool | 允许转码 |
| `AllowVideoStreamCopy` | bool | 转码时允许视频流拷贝 |
| `AllowAudioStreamCopy` | bool | 转码时允许音频流拷贝 |
| `IsPlayback` | bool | 是否真实播放（`true` 时服务器会计入会话） |
| `AutoOpenLiveStream` | bool | 自动打开直播流 |
| `CurrentPlaySessionId` | string | 当前播放会话 Id（换流/纠错时传上一次的）〔仅 Reference 页有〕 |
| `AllowInterlacedVideoStreamCopy` | bool | 允许隔行视频流拷贝〔仅 Reference 页有〕 |
| `DirectPlayProtocols` | string[] | 允许的直连协议〔仅 OpenAPI 有〕 |

- ✅ 来源（**Reference 页 19 个字段**，以此为准）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
- ⚠️ 来源（OpenAPI 18 个字段，缺 `CurrentPlaySessionId`、`AllowInterlacedVideoStreamCopy`，多 `DirectPlayProtocols`）：<https://swagger.emby.media/openapi.json> → `MediaInfo.PlaybackInfoRequest`
- 两份清单**取并集**最安全（多传未知字段服务器会忽略；缺字段则功能失效）。

**⚠️ Emby vs Jellyfin 的签名差异（必须同时兼容）**：

| | Emby（OpenAPI 实测） | Jellyfin（当前 stable spec 12.2.0） |
|---|---|---|
| `POST /Items/{id}/PlaybackInfo` | **只有 `body`**，**无任何 query 参数** | **同时有** 15 个 query 参数 **和** `PlaybackInfoDto` body |
| `GET /Items/{id}/PlaybackInfo` | `?UserId=` 必填 | `?userId=` 可选 |

- ✅ Emby 侧证据（逐字段核对）：<https://swagger.emby.media/openapi.json> → `/Items/{Id}/PlaybackInfo` → `post` 的 `parameters` 只有 `Id`(path) 和 `body` 两项，**没有** query 参数。
- ✅ Jellyfin 侧证据（逐字段核对）：<https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json> → `/Items/{itemId}/PlaybackInfo` → `post` 有 15 个 query 参数（`userId`、`maxStreamingBitrate`、`startTimeTicks`、`audioStreamIndex`、`subtitleStreamIndex`、`maxAudioChannels`、`mediaSourceId`、`liveStreamId`、`autoOpenLiveStream`、`enableDirectPlay`、`enableDirectStream`、`enableTranscoding`、`allowVideoStreamCopy`、`allowAudioStreamCopy`），**并且**有 `requestBody` → `PlaybackInfoDto`。
- ⚠️ **Jellyfin 10.9 的确切形态未验证**：上面引用的是**当前** stable spec（12.2.0），比 10.9 新。10.9 时代普遍认为 POST 走 query、无 body；但 Jellyfin 后续版本加了 `PlaybackInfoDto` body。**Prism 目标是兼容两者，所以不要依赖「某一版 Jellyfin 用哪种」**。

**兼容做法**：**query 和 body 同时发**。
- 对 Emby：多余 query 参数被忽略（Emby 只读 body）。
- 对 Jellyfin：body 与 query 内容一致，取哪边都对。
- ◐ 该策略为工程推断（HTTP 服务器忽略未声明 query 参数是常规行为），**官方未承诺** ——【待验证】。建议在真机上对 Emby 4.8、Emby 4.9、Jellyfin 10.9 各验证一次。

```swift
func playbackInfo(itemId: String, userId: String, profile: DeviceProfile) async throws -> PlaybackInfoResponse {
    var comps = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/PlaybackInfo"),
                              resolvingAgainstBaseURL: false)!
    comps.queryItems = [
        .init(name: "UserId", value: userId),
        .init(name: "MaxStreamingBitrate", value: "\(profile.maxStreamingBitrate)")
    ]
    var req = URLRequest(url: comps.url!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(token, forHTTPHeaderField: "X-Emby-Token")
    req.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
    req.httpBody = try JSONEncoder().encode(PlaybackInfoRequest(userId: userId, deviceProfile: profile))
    return try await session.data(for: req).decode()
}
```

### 6.2 DeviceProfile JSON —— 完整结构与真实样例

#### 6.2.1 权威 schema（字段名逐个核实）✅

`MediaBrowser.Model.Dlna.DeviceProfile` 的属性（✅ 来源：<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Dlna.DeviceProfile.html> 与 <https://swagger.emby.media/openapi.json> → `Dlna.DeviceProfile`）：

```
Name, Id, Identification, FriendlyName, Manufacturer, ManufacturerUrl,
ModelName, ModelDescription, ModelNumber, ModelUrl, SerialNumber,
EnableAlbumArtInDidl, EnableSingleAlbumArtLimit, EnableSingleSubtitleLimit,
SupportedMediaTypes, UserId, AlbumArtPn, MaxAlbumArtWidth, MaxAlbumArtHeight,
MaxIconWidth, MaxIconHeight, MaxStreamingBitrate, MaxStaticBitrate,
MusicStreamingTranscodingBitrate, MaxStaticMusicBitrate, SonyAggregationFlags,
ProtocolInfo, TimelineOffsetSeconds, RequiresPlainVideoItems, RequiresPlainFolders,
EnableMSMediaReceiverRegistrar, IgnoreTranscodeByteRangeRequests, XmlRootAttributes,
DirectPlayProfiles, TranscodingProfiles, ContainerProfiles, CodecProfiles,
ResponseProfiles, SubtitleProfiles
```

> 对客户端而言，**只需 `DirectPlayProfiles`、`TranscodingProfiles`、`CodecProfiles`、`SubtitleProfiles`、`MaxStreamingBitrate`、`MaxStaticBitrate`、`MusicStreamingTranscodingBitrate`、`Name`**。其余（`ProtocolInfo`、`Manufacturer` 等 DLNA 字段）可全部省略 —— ✅ 官方明确："For brevity, all Dlna-specific properties such as ProtocolInfo, Manufacturer/Model, etc. can be omitted."（<https://dev.emby.media/doc/restapi/Sync.html>）

#### 6.2.2 子结构（✅ 全部字段名已核实）

**`DirectPlayProfile`**
| 字段 | 类型 | 取值 |
|---|---|---|
| `Container` | string | 逗号分隔，如 `"mp4,m4v"`、`"mkv"` |
| `AudioCodec` | string | 逗号分隔，如 `"aac,ac3,eac3,flac,alac,mp3,opus"` |
| `VideoCodec` | string | 逗号分隔，如 `"h264,hevc"` |
| `Type` | enum | `Audio` / `Video` / `Photo` |

**`TranscodingProfile`**
| 字段 | 类型 | 取值 |
|---|---|---|
| `Container` | string | `ts` / `mp4` / `aac` / `mp3` … |
| `Type` | enum | `Audio` / `Video` / `Photo` |
| `VideoCodec` | string | 如 `h264` |
| `AudioCodec` | string | 如 `aac` |
| `Protocol` | string | `hls` / `http` |
| `Context` | enum | `Streaming` / `Static` |
| `MaxAudioChannels` | string | **注意是字符串**，如 `"2"` |
| `MinSegments` | int | HLS 起播最小分片数 |
| `SegmentLength` | int | 分片时长（秒） |
| `BreakOnNonKeyFrames` | bool | 是否在非关键帧处切分 |
| `EstimateContentLength` | bool | 估算 Content-Length |
| `EnableMpegtsM2TsMode` | bool | |
| `TranscodeSeekInfo` | enum | `Auto` / `Bytes` |
| `CopyTimestamps` | bool | |
| `ManifestSubtitles` | string | 如 `"vtt"` |
| `MaxManifestSubtitles` | int | |
| `MaxWidth` / `MaxHeight` | int | |
| `FillEmptySubtitleSegments` | bool | |
| `AllowInterlacedVideoStreamCopy` | bool | |

**`CodecProfile`**
| 字段 | 类型 | 取值 |
|---|---|---|
| `Type` | enum | `Video` / `VideoAudio` / `Audio` |
| `Codec` | string | 如 `"aac"`、`"h264"`；省略表示适用所有 |
| `Container` | string | 可选 |
| `Conditions` | ProfileCondition[] | 不满足则转码 |
| `ApplyConditions` | ProfileCondition[] | 仅用于决策、不影响转码 |

**`ProfileCondition`**
| 字段 | 类型 | 取值 |
|---|---|---|
| `Condition` | enum | `Equals` / `NotEquals` / `LessThanEqual` / `GreaterThanEqual` / `EqualsAny` |
| `Property` | enum | `AudioChannels`、`AudioBitrate`、`AudioProfile`、`Width`、`Height`、`Has64BitOffsets`、`PacketLength`、`VideoBitDepth`、`VideoBitrate`、`VideoFramerate`、`VideoLevel`、`VideoProfile`、`VideoTimestamp`、`IsAnamorphic`、`RefFrames`、`NumAudioStreams`、`NumVideoStreams`、`IsSecondaryAudio`、`VideoCodecTag`、`IsAvc`、`IsInterlaced`、`AudioSampleRate`、`AudioBitDepth`（Emby 另有 `VideoRange`、`VideoRotation`、`IsExternalAudio`） |
| `Value` | string | 比较值 |
| `IsRequired` | bool | `true`=不满足即转码；`false`=不满足也可播 |

**`SubtitleProfile`**
| 字段 | 类型 | 取值 |
|---|---|---|
| `Format` | string | `vtt`、`ass`、`ssa`、`srt`、`pgssub`、`dvdsub`、`subrip`… |
| `Method` | enum | `Encode`（烧录） / `Embed`（封装） / `External`（外挂） / `Hls` |
| `Language` | string | 可选 |
| `Container` | string | 可选 |
| `DidlMode` | string | DLNA 用，客户端省略 |
| `AllowChunkedResponse` | bool | |

**`ResponseProfile`**
| 字段 | 类型 |
|---|---|
| `Container` / `AudioCodec` / `VideoCodec` / `OrgPn` / `MimeType` | string |
| `Type` | `Audio`/`Video`/`Photo` |
| `Conditions` | ProfileCondition[] |

- ✅ 以上子结构字段名全部来自 <https://swagger.emby.media/openapi.json>（`Dlna.DirectPlayProfile`、`Dlna.TranscodingProfile`、`Dlna.CodecProfile`、`Dlna.ProfileCondition`、`Dlna.SubtitleProfile`、`Dlna.ResponseProfile`），并与 <https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html> 的 Definitions 段逐字一致。

#### 6.2.3 真实客户端构造样例（不是臆造）

下面两段是**真实生产客户端**的构造代码，用于证明字段用法：

**样例 A — jellyfin-web 的 `browserDeviceProfile.js`（✅ Jellyfin 官方客户端源码；仅作字段用法参考）**
来源：<https://github.com/jellyfin/jellyfin-web/blob/master/src/scripts/browserDeviceProfile.js>

```js
const profile = {
    MaxStreamingBitrate: bitrateSetting,
    MaxStaticBitrate: 100000000,
    MusicStreamingTranscodingBitrate: Math.min(bitrateSetting, 384000),
    DirectPlayProfiles: []
};

profile.DirectPlayProfiles.push({
    Container: 'mp4,m4v',
    Type: 'Video',
    VideoCodec: mp4VideoCodecs.join(','),
    AudioCodec: videoAudioCodecs.join(',')
});

profile.TranscodingProfiles.push({
    Container: enableFmp4Hls ? 'mp4' : 'ts',
    Type: 'Audio',
    AudioCodec: 'aac',
    Context: 'Streaming',
    Protocol: 'hls',
    MaxAudioChannels: physicalAudioChannels.toString(),
    MinSegments: browser.iOS || browser.osx ? '2' : '1',
    BreakOnNonKeyFrames: hlsBreakOnNonKeyFrames,
    EnableAudioVbrEncoding: !appSettings.disableVbrAudio()
});

profile.CodecProfiles.push({
    Type: 'VideoAudio',
    Codec: 'aac',
    Conditions: [{
        Condition: 'NotEquals',
        Property: 'AudioProfile',
        Value: 'HE-AAC'
    }]
});

profile.SubtitleProfiles.push({ Format: 'vtt', Method: 'External' });
profile.SubtitleProfiles.push({ Format: 'ass', Method: 'External' });
```

> ⚠️ **注意**：上面是 **Jellyfin Web** 的代码，其中 `EnableAudioVbrEncoding`、`MinSegments` 用字符串 `'2'` 等细节属于 Jellyfin 侧实现。`EnableAudioVbrEncoding` **不在** Emby 的 `Dlna.TranscodingProfile` schema 中（Emby 侧无此字段），照抄到 Emby 请求里会被忽略。**Prism 请以 6.2.1/6.2.2 的字段表为准**，样例 A 只用于理解"这些字段怎么组合"。

**样例 B — 真实 PlaybackInfo 响应片段（◐ Emby 服务器实际返回，第三方抓包，字段名与官方 schema 一致）**
来源：<https://github.com/AkimioJR/MediaWarp/blob/main/docs/DEV.md>

```json
{
  "MediaSources": [{
    "Protocol": "File",
    "Id": "37bcb3827aeb2095f1b6293e9a189072",
    "Type": "Default",
    "Container": "mkv",
    "SupportsTranscoding": true,
    "SupportsDirectStream": false,
    "SupportsDirectPlay": false,
    "DirectStreamUrl": "/videos/61162/master.m3u8?DeviceId=e12ab84a-...&MediaSourceId=37bcb3827aeb...&PlaySessionId=e643532a...&api_key=e824c422...&VideoCodec=h264,h265,hevc,av1&VideoBitrate=1400000&TranscodingMaxAudioChannels=2&SegmentContainer=ts&MinSegments=1&BreakOnNonKeyFrames=True&SubtitleStreamIndexes=-1&ManifestSubtitles=vtt&h264-profile=high,main,baseline,constrainedbaseline,high10&h264-level=62&hevc-codectag=hvc1,hev1,hevc,hdmv&TranscodeReasons=ContainerBitrateExceedsLimit",
    "TranscodingUrl": "/videos/61162/master.m3u8?DeviceId=...&MediaSourceId=...&PlaySessionId=...&api_key=...&VideoCodec=h264,h265,hevc,av1&VideoBitrate=1400000&...",
    "TranscodingSubProtocol": "hls",
    "TranscodingContainer": "ts",
    "ReadAtNativeFramerate": false,
    "ItemId": "61162"
  }],
  "PlaySessionId": "e643532a23ca4a60b2c70d4210c018a9"
}
```

> 注意 `TranscodeReasons=ContainerBitrateExceedsLimit` —— 这个 query 参数**直接告诉你为什么转码**，调试时非常有用（见 6.6）。

#### 6.2.4 Prism 用的 macOS DeviceProfile（可直接用）

字段名全部经上表核实；**具体取值是按 macOS/AVFoundation 能力给的建议值，需在真机上按解码实测微调**。

```json
{
  "Name": "Prism macOS",
  "MaxStreamingBitrate": 120000000,
  "MaxStaticBitrate": 140000000,
  "MusicStreamingTranscodingBitrate": 384000,
  "DirectPlayProfiles": [
    {
      "Container": "mp4,m4v,mov",
      "Type": "Video",
      "VideoCodec": "h264,hevc",
      "AudioCodec": "aac,ac3,eac3,alac,mp3,flac,opus"
    },
    {
      "Container": "mkv",
      "Type": "Video",
      "VideoCodec": "h264,hevc",
      "AudioCodec": "aac,ac3,eac3,flac,alac,mp3,opus,vorbis"
    },
    {
      "Container": "mp3",
      "Type": "Audio",
      "AudioCodec": "mp3"
    },
    {
      "Container": "aac,m4a",
      "Type": "Audio",
      "AudioCodec": "aac,alac"
    },
    {
      "Container": "flac",
      "Type": "Audio",
      "AudioCodec": "flac"
    },
    {
      "Container": "ogg,oga,opus",
      "Type": "Audio",
      "AudioCodec": "vorbis,opus"
    },
    {
      "Container": "wav",
      "Type": "Audio",
      "AudioCodec": "pcm_s16le,pcm_s24le"
    }
  ],
  "TranscodingProfiles": [
    {
      "Container": "ts",
      "Type": "Video",
      "VideoCodec": "h264",
      "AudioCodec": "aac",
      "Protocol": "hls",
      "Context": "Streaming",
      "MaxAudioChannels": "6",
      "MinSegments": 1,
      "SegmentLength": 6,
      "BreakOnNonKeyFrames": false,
      "ManifestSubtitles": "vtt"
    },
    {
      "Container": "mp4",
      "Type": "Video",
      "VideoCodec": "h264",
      "AudioCodec": "aac",
      "Protocol": "http",
      "Context": "Streaming",
      "MaxAudioChannels": "6"
    },
    {
      "Container": "ts",
      "Type": "Audio",
      "AudioCodec": "aac",
      "Protocol": "hls",
      "Context": "Streaming",
      "MaxAudioChannels": "2",
      "MinSegments": 1,
      "SegmentLength": 6,
      "BreakOnNonKeyFrames": false
    },
    {
      "Container": "mp3",
      "Type": "Audio",
      "AudioCodec": "mp3",
      "Protocol": "http",
      "Context": "Streaming",
      "MaxAudioChannels": "2"
    }
  ],
  "CodecProfiles": [
    {
      "Type": "Video",
      "Codec": "h264",
      "Conditions": [
        { "Condition": "LessThanEqual", "Property": "VideoLevel", "Value": "51", "IsRequired": false }
      ]
    },
    {
      "Type": "VideoAudio",
      "Conditions": [
        { "Condition": "LessThanEqual", "Property": "AudioChannels", "Value": "6", "IsRequired": false }
      ]
    },
    {
      "Type": "Video",
      "Conditions": [
        { "Condition": "NotEquals", "Property": "IsAnamorphic", "Value": "true", "IsRequired": false }
      ]
    }
  ],
  "SubtitleProfiles": [
    { "Format": "vtt",    "Method": "External" },
    { "Format": "srt",    "Method": "External" },
    { "Format": "ass",    "Method": "External" },
    { "Format": "ssa",    "Method": "External" },
    { "Format": "subrip", "Method": "External" },
    { "Format": "pgssub", "Method": "Encode" },
    { "Format": "dvdsub", "Method": "Encode" }
  ],
  "ResponseProfiles": [
    { "Type": "Video", "Container": "m4v", "MimeType": "video/mp4" }
  ]
}
```

**取舍说明**：
- `pgssub`/`dvdsub` 用 `Encode`（烧录）而不是 `External`：AVFoundation 不支持 PGS 图形字幕的旁路渲染，必须烧进画面。jellyfin-web 之所以能 `External` 是因为它用 canvas 自己画 —— macOS 原生播放器没有等价能力。
- `ass`/`ssa` 用 `External`：拿到字幕后自行用 CoreText 渲染样式；若要保真度，也可改成 `Encode`（代价：必然触发视频转码）。
- `MaxStreamingBitrate` 给 120 Mbps 是**局域网直连**场景的宽松值；远程播放时应按用户「质量设置」下调（如 8 Mbps / 4 Mbps / 2 Mbps）。

### 6.3 返回结构 ✅

`PlaybackInfoResponse`：

| 字段 | 类型 | 说明 |
|---|---|---|
| `MediaSources` | MediaSourceInfo[] | 可用的媒体源列表 |
| `PlaySessionId` | string | **本次播放会话 Id**，后续进度上报与转码 URL 都要用 |
| `ErrorCode` | string | 失败原因，如 `NotAllowed` |

- ✅ 来源：<https://swagger.emby.media/openapi.json> → `MediaInfo.PlaybackInfoResponse`

**`PlaySessionId` 的用法（关键）**：
1. 服务器生成，**每次 PlaybackInfo 调用一个新值**。
2. 必须原样带到 `/Sessions/Playing`、`/Sessions/Playing/Progress`、`/Sessions/Playing/Stopped` 的 `PlaySessionId` 字段。
3. 转码 URL 里已经内嵌了这个值 —— **不要改它**，否则服务器找不到对应的转码任务。

### 6.4 三种播放方式的判定

#### 官方定义 ✅

| 方式 | 定义 |
|---|---|
| **Direct Play（直连）** | 客户端**直接读文件系统**（用 `Path`），服务器被绕过 |
| **Direct Stream（直封）** | 客户端从服务器**原样拉流**，不编码不重封装 |
| **Transcode（转码）** | 服务器编码后再给客户端 |

- ✅ 来源：<https://dev.emby.media/doc/restapi/Playback-Guidelines.html>

#### 官方推荐算法 ✅

1. **Step 1 — Direct Play**：算出能直连的 MediaSource 数量。0 个 → 进 Step 2；1 个 → 播它；多个 → 弹选择框（用 `MediaSource.Name` 显示）。
2. **Step 2 — Direct Stream**：结合用户设定的最大码率，找第一个能直封且在码率内的源。
3. **Step 3 — Transcode**：音频取第一个源；视频优先取「视频编码客户端原生支持」的源（通常 h264），转码效率更高。

- ✅ 来源：<https://dev.emby.media/doc/restapi/Playback-Guidelines.html>

#### Prism 的实际做法（推荐）

**不要自己实现这套算法**。把 DeviceProfile 交给服务器，让 `PlaybackInfo` 直接告诉你结果：

```
读 MediaSources[i].SupportsDirectPlay  → 为 true 且容器/编码在本地白名单 → DirectPlay
否则读 SupportsDirectStream            → 为 true                       → DirectStream
否则                                                                     → Transcode
```

> ⚠️ **注意**：这三个 `Supports*` 标志是**服务器根据你提交的 DeviceProfile 算出来的**，不是文件的固有属性。DeviceProfile 写错了，标志就会错，进而选错播放方式。
> 所以调试顺序永远是：**先看 `TranscodeReasons`（6.6）→ 再改 DeviceProfile → 再看标志**。

**本地白名单**（macOS + AVFoundation，需实测校准）：
- 容器：`mp4`、`m4v`、`mov`（AVPlayer 原生）；`mkv` 需要自研 demux 或用第三方（如 libmpv/VLCKit）—— **若用 AVPlayer，mkv 一律不能 DirectPlay**。
- 视频：`h264` 全档；`hevc` 视机型（Apple Silicon 全支持，Intel 需 6 代+）。
- 音频：`aac`、`ac3`、`eac3`、`alac`、`mp3`；`flac` 在 macOS 11+ 支持；`opus` 在 AVFoundation 支持有限（建议转码）。
- 字幕：文本字幕（`srt`/`ass`/`vtt`）外挂；图形字幕（`pgssub`/`dvdsub`）必须烧录。

> ⚠️ 上述「AVFoundation 支持矩阵」是工程经验，**不是 Emby 文档**，需在目标 macOS 版本上用真实片源验证。

#### `DirectStreamUrl` vs `TranscodingUrl`

| 字段 | Emby | Jellyfin | 说明 |
|---|---|---|---|
| `DirectStreamUrl` | ✅ **有** | ❌ **OpenAPI 中无此字段** | Emby 会给出完整直封 URL（含 `api_key`、`MediaSourceId`、`PlaySessionId`） |
| `TranscodingUrl` | ✅ 有 | ✅ 有 | 转码 URL（HLS 时为 `master.m3u8`） |

- ✅ Emby 有 `DirectStreamUrl`：<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Dto.MediaSourceInfo.html>（`public string DirectStreamUrl { get; set; }`）+ 真实样例（6.2.3 样例 B）
- ✅ Jellyfin 无该字段：<https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json> → `MediaSourceInfo` 的 properties 里**没有** `DirectStreamUrl`

**⚠️ 重大实践陷阱：不要用 `DirectStreamUrl` 是否存在来判断「能不能直封」。**

实测抓包显示：**当需要转码时，Emby 依然会返回 `DirectStreamUrl`，而且它的值往往与 `TranscodingUrl` 完全相同**（都是 `master.m3u8?...&TranscodeReasons=...`）。

- ◐ 证据（Emby 真实会话 JSON）：<https://emby.media/community/topic/92430-session-playstate-mediasourceid-session-fullplayingitemgetmediasources>
  - 该样例中 `"SupportsDirectStream": false`、`"SupportsDirectPlay": false`，但 `DirectStreamUrl` 仍然存在，内容为 `/videos/58234/master.m3u8?...&TranscodeReasons=ContainerBitrateExceedsLimit`，与 `TranscodingUrl` 一致。
- **正确判定顺序**：
  1. 看 `SupportsDirectPlay` → true 且本地解码器支持该容器/编码 → **DirectPlay**
  2. 否则看 `SupportsDirectStream` → true → **DirectStream**（用 `DirectStreamUrl` 或自拼 `stream?static=true`）
  3. 否则 → **Transcode**（用 `TranscodingUrl`）
- `DirectStreamUrl` 只能当作「Emby 建议的拉流 URL」来用，**不能当能力标志**。

- **结论**：
  - 连 Emby → `SupportsDirectStream == true` 时优先用服务器返回的 `DirectStreamUrl`；否则用 `TranscodingUrl`。
  - 连 Jellyfin（或 Emby 没返回该字段）→ **自行拼**：

```
{base}/Videos/{itemId}/stream?static=true&MediaSourceId={msId}&PlaySessionId={psid}&DeviceId={deviceId}&api_key={token}
```

  - ◐ 自行拼接的模板来自 Jellyfin 生态通行写法（如 <https://github.com/AkimioJR/MediaWarp> 中 `"/videos/%s/stream?MediaSourceId=%s&Static=true"`），非官方文档明示 ——【待验证】。

### 6.5 播放 URL 的构成

**直封（不转码）** ✅：

```
GET /emby/Videos/{itemId}/stream?static=true&MediaSourceId={id}&PlaySessionId={psid}&DeviceId={did}&api_key={token}
```

- `static=true` 即「原样流式传输」—— ✅ 官方原文："To direct stream a video file, simply use the **static=true** parameter."（<https://dev.emby.media/doc/restapi/Video-Streaming.html>）
- 也可用带扩展名的别名（部分播放器更友好）：`/Videos/{Id}/stream.mp4`、`.mkv`、`.ts`、`.webm` 等。**扩展名应按输出格式写，不是输入格式** ✅。

**转码（HLS）** ✅：

```
GET /emby/Videos/{itemId}/master.m3u8?MediaSourceId=...&DeviceId=...&PlaySessionId=...&api_key=...
```

- 必需参数：`Id`（path）、`MediaSourceId`、`DeviceId`。
- ✅ 来源：<https://dev.emby.media/doc/restapi/Http-Live-Streaming.html>
- 分片路径：`/Videos/{Id}/hls/{PlaylistId}/{SegmentId}.{SegmentContainer}`（✅ <https://dev.emby.media/reference/RestAPI/VideoHlsService/getVideosByIdHlsByPlaylistidBySegmentidBySegmentcontainer.html>）

**转码（渐进式 HTTP）**：

```
GET /emby/Videos/{itemId}/stream?Container=ts&VideoCodec=h264&AudioCodec=aac&VideoBitrate=...&AudioBitrate=...&api_key=...
```

- 必需参数：`Id`、`MediaSourceId`、`PlaySessionId`（✅ <https://dev.emby.media/doc/restapi/Video-Streaming.html>：`PlaySessionId` 来自 PlaybackInfo 响应；若不用 MediaSource API，则自己生成随机字母数字串）

### 6.6 转码原因诊断（实用技巧）

Emby 会在 `TranscodingUrl` 里附加 `TranscodeReasons=` 参数，值是逗号分隔的原因列表（◐ 真实抓包样例，见 6.2.3 样例 B；官方文档未单独说明该参数）。

Jellyfin 的 `TranscodeReason` 枚举（◐ Emby 取值高度一致，但官方未公布完整枚举）：

```
ContainerNotSupported, VideoCodecNotSupported, AudioCodecNotSupported,
SubtitleCodecNotSupported, AudioIsExternal, SecondaryAudioNotSupported,
VideoProfileNotSupported, VideoLevelNotSupported, VideoResolutionNotSupported,
VideoBitDepthNotSupported, VideoFramerateNotSupported, RefFramesNotSupported,
AnamorphicVideoNotSupported, InterlacedVideoNotSupported, AudioChannelsNotSupported,
AudioProfileNotSupported, AudioSampleRateNotSupported, AudioBitDepthNotSupported,
ContainerBitrateExceedsLimit, VideoBitrateNotSupported, AudioBitrateNotSupported,
UnknownVideoStreamInfo, UnknownAudioStreamInfo, DirectPlayError,
VideoRangeTypeNotSupported, VideoCodecTagNotSupported, StreamCountExceedsLimit,
VideoRotationNotSupported
```

- 来源（Jellyfin）：<https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json> → `TranscodeReason`
- **用途**：转码不符合预期时，把 `TranscodeReasons` 打到日志，一眼看出是 DeviceProfile 写错了哪一项。这是调试 DeviceProfile 的最高效手段。

---

## 7. 播放进度上报

### 7.1 三个端点 ✅

| 端点 | 时机 |
|---|---|
| `POST /emby/Sessions/Playing` | 开始播放 |
| `POST /emby/Sessions/Playing/Progress` | 播放中（定时 + 用户交互） |
| `POST /emby/Sessions/Playing/Stopped` | 停止播放 |

- ✅ 来源：<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>
- ✅ 页面：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlaying.html>、`postSessionsPlayingProgress.html`、`postSessionsPlayingStopped.html`
- `Content-Type: application/json` ✅

### 7.2 字段逐个核实

#### `PlaybackStartInfo`（`/Sessions/Playing`）✅

| 字段 | 类型 | 说明 |
|---|---|---|
| `ItemId` | string | 条目 Id（库内条目用这个） |
| `Item` | BaseItemDto | 库外内容才用（**与 ItemId 二选一**） |
| `MediaSourceId` | string | 媒体源 Id |
| `PlaySessionId` | string | PlaybackInfo 返回的会话 Id |
| `PlayMethod` | enum | `Transcode` / `DirectStream` / `DirectPlay` |
| `PositionTicks` | int64 | 起播位置 |
| `IsPaused` | bool | 是否暂停 |
| `IsMuted` | bool | 是否静音 |
| `VolumeLevel` | int | 音量 0–100 |
| `CanSeek` | bool | 是否可 seek |
| `AudioStreamIndex` | int | 当前音轨 Index |
| `SubtitleStreamIndex` | int | 当前字幕 Index（`-1`=关） |
| `RepeatMode` | enum | `RepeatNone` / `RepeatAll` / `RepeatOne` |
| `PlaybackRate` | double | 倍速 |
| `SubtitleOffset` | int | 字幕延迟 |
| `PlaylistIndex` | int | 播放队列当前位置 |
| `PlaylistLength` | int | 队列总长 |
| `PlaylistItemId` | string | 队列项 Id |
| `PlaylistItemIds` | string[] | 队列全部项 Id |
| `NowPlayingQueue` | QueueItem[] | 队列内容 |
| `RunTimeTicks` | int64 | 时长 |
| `PlaybackStartTimeTicks` | int64 | 起播时刻 |
| `SessionId` | string | 会话 Id |
| `LiveStreamId` | string | 直播流 Id |
| `Brightness` / `AspectRatio` | int / string | 画面调整 |
| `EventName` | enum | 见下方 `ProgressEvent` |
| `SleepTimerMode` | enum | `None` / `AfterItem` / `AtTime` |
| `SleepTimerEndTime` | datetime | 睡眠定时结束时间 |
| `Shuffle` | bool | 是否随机播放 |

- ✅ 来源（**Reference 页共 30 个字段**，以此为准）：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlaying.html>
- ⚠️ 来源（OpenAPI 快照只有 21 个，缺 `EventName`、`SleepTimerMode`、`SleepTimerEndTime`、`Shuffle`、`PlaylistIndex`、`PlaylistLength`、`PlaylistItemIds`、`SubtitleOffset`、`PlaybackRate`）：<https://swagger.emby.media/openapi.json> → `PlaybackStartInfo`

> **⚠️ 为什么两份清单不一样**：`swagger.emby.media/openapi.json` 的 `info.version` 是 **`4.1.1.0`**，是一份**旧快照**；而 dev.emby.media 的 Reference 页由当前版本代码生成。**冲突时以 Reference 页为准**，OpenAPI 仅用来核对字段名拼写与类型。
> - 证据：<https://swagger.emby.media/openapi.json> → `info.version = "4.1.1.0"`
> - 建议：实现时**按 Reference 页的 30 字段发**，多出来的字段对旧服务器无害。

**⚠️ `QueueableMediaTypes` 不要发**：官方 Playback-Check-ins 文档列了它（`Array[string] - Audio,Video`），但 **Reference 页与 OpenAPI 的 `PlaybackStartInfo` 里都没有**。
- 文档侧：<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>
- schema 侧：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlaying.html>
- **处理**：不发。该字段在 3.x 时代存在，4.x 已移除。

#### `PlaybackProgressInfo`（`/Sessions/Playing/Progress`）✅

**字段与 `PlaybackStartInfo` 完全相同**（Reference 页两者都是 30 个字段，逐项比对无差异）。`EventName` 在两者中都有，但在 Progress 里才是必填语义。

| 字段 | 类型 | 说明 |
|---|---|---|
| `EventName` | enum | 上报原因（见下），Progress 场景必填 |

**`EventName`（`ProgressEvent`）取值** ✅：

```
TimeUpdate, Pause, Unpause, VolumeChange, RepeatModeChange,
AudioTrackChange, SubtitleTrackChange, PlaylistItemMove,
PlaylistItemRemove, PlaylistItemAdd, QualityChange,
StateChange, SubtitleOffsetChange, PlaybackRateChange,
ShuffleChange, SleepTimerChange
```

- ✅ 来源：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingProgress.html>（`ProgressEvent` 枚举）
- ✅ 文档侧说明：<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>（列了 13 个值，比 schema 少 `StateChange`、`ShuffleChange`、`SleepTimerChange`）

> **注意**：`Pause` / `Unpause` 是 `EventName` 的取值，**不是**单独的端点。暂停时发 Progress 且 `EventName="Pause"`、`IsPaused=true`。

#### `PlaybackStopInfo`（`/Sessions/Playing/Stopped`）✅

| 字段 | 类型 | 说明 |
|---|---|---|
| `ItemId` | string | 条目 Id |
| `MediaSourceId` | string | 媒体源 Id |
| `PlaySessionId` | string | 会话 Id |
| `PositionTicks` | int64 | **停止位置（写进度就靠它）** |
| `Failed` | bool | 是否因失败而停止 |
| `IsAutomated` | bool | 是否由系统自动触发（非用户操作） |
| `NextMediaType` | string | 下一个媒体类型 |
| `LiveStreamId` | string | |
| `PlaylistIndex` / `PlaylistLength` / `PlaylistItemId` / `NowPlayingQueue` | | 队列信息 |
| `SessionId` | string | |
| `Item` | BaseItemDto | 库外内容 |

- ✅ 来源（**Reference 页共 14 个字段**）：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingStopped.html>
- ✅ 交叉核对（OpenAPI 快照的 11 个字段是其子集）：<https://swagger.emby.media/openapi.json> → `PlaybackStopInfo`

**⚠️ 重要差异（已核实，三份来源逐一比对）**：`PlaybackStopInfo` **确实没有** `PlayMethod`、`IsPaused`、`RepeatMode`、`CanSeek`、`VolumeLevel`、`AudioStreamIndex`、`SubtitleStreamIndex`、`RunTimeTicks`、`EventName` 等字段 —— Reference 页与 OpenAPI 一致。
但官方 Playback-Check-ins 文档说 "The contents of the request are identical to the playback start message"。
- 文档侧：<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>
- Reference 侧：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingStopped.html>（14 字段）
- **处理建议**：**按 Reference 的 14 字段发**（`ItemId`、`MediaSourceId`、`PlaySessionId`、`PositionTicks`、`Failed`、`IsAutomated`、`NextMediaType`、`LiveStreamId`、`PlaylistIndex`、`PlaylistLength`、`PlaylistItemId`、`NowPlayingQueue`、`SessionId`、`Item`）。
  这 14 个字段已足够服务器写进度（关键是 `ItemId` + `MediaSourceId` + `PlaySessionId` + `PositionTicks`）。
- ⚠️【待验证】：若服务器依赖 `PlayMethod` 来区分"看完"判定，可尝试额外附带；.NET 反序列化默认忽略未知字段，但**未在 Emby 文档确认**。先按 14 字段实现。

### 7.3 上报节奏 ✅

官方明确：

- **每 10 秒**自动上报一次 Progress。
- **用户每次交互后立即上报**（暂停、恢复、音量、切轨等）。
- 服务器自身**每秒**递增进度，客户端**不需要**比 10 秒更频繁。
- 客户端上报的作用是**校准**服务器的自动递增。

- ✅ 来源：<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>（"Playback progress should be reported at the following times: Automatically every 10 seconds; Immediately following any user interaction… The server will automatically increment playback progress every second, so it is not necessary to automatically report more often than at 10 second intervals."）

**Prism 建议实现**：

| 事件 | 动作 |
|---|---|
| 开始播放 | `POST /Sessions/Playing`（带 `PlayMethod`、`PlaySessionId`、`MediaSourceId`、`PositionTicks`） |
| 每 10s | `POST /Sessions/Playing/Progress`，`EventName="TimeUpdate"` |
| 暂停 | 立即 Progress，`EventName="Pause"`，`IsPaused=true` |
| 恢复 | 立即 Progress，`EventName="Unpause"`，`IsPaused=false` |
| 拖动进度 | 立即 Progress，`EventName="TimeUpdate"`（seek 完成后） |
| 切音轨/字幕 | 立即 Progress，`EventName="AudioTrackChange"`/`"SubtitleTrackChange"` |
| 切倍速 | 立即 Progress，`EventName="PlaybackRateChange"` |
| 停止/关闭 | `POST /Sessions/Playing/Stopped`，带最终 `PositionTicks` |
| App 退到后台 | 继续每 10s 上报（若系统允许）；被挂起前务必发一次 Progress |
| App 崩溃/断电 | 无法保证 —— 服务器会保留最后一次 Progress 位置，续播点会略旧 |

**必须做的容错**：
- 上报请求**失败不要阻塞播放**（fire-and-forget + 后台队列）。
- 网络恢复后补发一次最新状态。
- `PlaySessionId` 丢失 → 进度会记到错误会话，务必在 PlaybackInfo 返回后立刻存下来。

### 7.4 WebSocket 上报（可选加速）✅

进度也可以通过 WebSocket 发，消息体与 HTTP 完全一致：

```json
{ "MessageType": "ReportPlaybackProgress", "Data": { /* PlaybackProgressInfo */ } }
```

- ✅ 来源：<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>
- **MVP 不建议**：HTTP 已经够用，WebSocket 上报增加复杂度且难调试。

### 7.5 旧版上报 API（不推荐）

Emby 还保留了按用户维度的旧接口：

```
POST /emby/Users/{userId}/PlayingItems/{itemId}?MediaSourceId=...&PositionTicks=...
POST /emby/Users/{userId}/PlayingItems/{itemId}/Progress
DELETE /emby/Users/{userId}/PlayingItems/{itemId}
```

- ✅ 端点存在：<https://swagger.emby.media/openapi.json> → `/Users/{UserId}/PlayingItems/{Id}` 等
- **不要用**：`/Sessions/Playing*` 是新版，字段更全（`PlayMethod`、`PlaySessionId`），且与转码会话绑定。

---

## 8. 图片

### 8.1 端点 ✅

```
GET /emby/Items/{itemId}/Images/{Type}
GET /emby/Items/{itemId}/Images/{Type}/{Index}
```

**`Type` 取值** ✅：
`Primary`、`Art`、`Backdrop`、`Banner`、`Logo`、`Thumb`、`Disc`、`Box`、`BoxRear`、`Screenshot`、`Menu`、`Chapter`

- ✅ 来源（枚举）：<https://swagger.emby.media/openapi.json> → `/Items/{Id}/Images/{Type}` 的 `Type` 参数 enum
- ✅ 来源（文档）：<https://dev.emby.media/doc/restapi/Images.html>

**`Index`**：Backdrop / Screenshot / Chapter 有多个，必须指定（`0` 基）。其余类型可省略。

**用户头像**：`GET /Users/{userId}/Images/{Type}`，`{Type}` 取 `Primary` ✅
**人物头像**：`GET /Persons/{name}/Images/{Type}`，`{Type}` 取 `Primary` ✅

> 说明：`{Type}` 是**路径段**（不是 query 参数），所以实际 URL 形如 `/emby/Users/abc123/Images/Primary`。两者均在 Emby OpenAPI 中有 `get`/`head`（<https://swagger.emby.media/openapi.json> → `/Users/{Id}/Images/{Type}`、`/Persons/{Name}/Images/{Type}`）。

### 8.2 查询参数 ✅

| 参数 | 类型 | 说明 |
|---|---|---|
| `maxWidth` | int | 最大宽度（等比缩放） |
| `maxHeight` | int | 最大高度 |
| `width` | int | **固定**宽度（高度按比例） |
| `height` | int | **固定**高度 |
| `quality` | int | 0–100，**默认 90**，一般够用 |
| `tag` | string | **缓存 tag**，传了才有强缓存头 |
| `format` | string | `original`/`gif`/`jpg`/`png`/`bmp` |
| `cropWhitespace` | bool | 裁掉空白（Logo 默认裁） |
| `enableImageEnhancers` | bool | 是否应用 Cover Art 等增强插件 |
| `addPlayedIndicator` | bool | 叠加"已看"角标 |
| `percentPlayed` | number | 叠加已看百分比 |
| `unplayedCount` | int | 叠加未看数量角标 |
| `backgroundColor` | string | 透明图背景色，如 `#000000` |
| `foregroundLayer` | string | 前景图层 |
| `autoOrient` | bool | 自动纠正方向 |
| `keepAnimation` | bool | 保留动图 |

- ✅ 来源：<https://dev.emby.media/reference/RestAPI/ImageService/getItemsByIdImagesByType.html>
- ✅ 机器可读：<https://swagger.emby.media/openapi.json> → `/Items/{Id}/Images/{Type}`
- ⚠️ 注意：`autoOrient`、`keepAnimation`、`enableImageEnhancers` 在 Emby 的 Reference 页面有，但**部分不在 OpenAPI 里**（`autoOrient`/`keepAnimation` 是 4.8+ 新增）。用不到就别传。

### 8.3 缓存策略（tag 机制）✅

**核心规则：`tag` 变化即 URL 失效。**

- 条目对象里的 `ImageTags`（`{"Primary":"abc","Logo":"def"}`）和 `BackdropImageTags`（`["t1","t2"]`）就是缓存 tag。
- 请求时带上 `?tag={tag}` → 服务器返回**强缓存头**（`Cache-Control: public, max-age=...`），客户端可以**永久缓存这个 URL**。
- **不带 `tag`** → 只有条件缓存（`ETag`/`If-None-Match`）。
- 图片变了 → tag 也变 → URL 变 → 自然重新下载，旧缓存可丢弃。

- ✅ 来源：<https://dev.emby.media/doc/restapi/Images.html>（"The image tag on the item object also doubles as a caching value. If you add this parameter back onto your image url, you will receive strong http caching headers. This allows you to cache the image forever, unconditionally, based on the url. If the image changes, the tag will also change, thus creating a whole new url."）

**官方缓存键建议** ✅：缓存键应**去掉 hostname 和 port**，这样局域网和公网访问能共用同一份缓存。
- ✅ 来源：同上（"It is recommended to cache based on the url after the hostname and port. This will allow the same cache to be utilized whether connected internally (lan/wifi) or externally (mobile)."）

**Prism 实现建议**：

```swift
struct ImageRequest {
    let itemId: String
    let type: String        // "Primary" / "Backdrop" / ...
    let index: Int?
    let maxWidth: Int?
    let tag: String?        // 来自 ImageTags / BackdropImageTags
}

// 缓存键（去掉 host:port）
func cacheKey(_ r: ImageRequest) -> String {
    "\(r.itemId)/\(r.type)/\(r.index ?? 0)/\(r.maxWidth ?? 0)/\(r.tag ?? "notag")"
}
```

- 用 `URLCache`（磁盘 + 内存）+ 自定义键，或直接用 `NSCache<NSString, NSImage>` + 磁盘目录。
- **海报墙尺寸**：列表用 `maxWidth=300`（Retina 下 600px 足够），详情页 `maxWidth=800`，背景图 `maxWidth=1920`。
- **不要请求原图**：官方明确提醒（"Users will often download high resolution images. Steps should be taken to ensure that you are not retrieving these at full size."）

### 8.4 404 回退链 ✅

**规则：只有对象里指示了图片存在，才去下载；否则必然 404。**

- ✅ 来源：<https://dev.emby.media/doc/restapi/Images.html>（"An image should only downloaded if the object indicates the presence of an image. For example, you will receive a 404 error if you attempt to download a logo image for an item that doesn't have one."）

**回退顺序（Prism 建议）**：

| 目标 | 回退链 |
|---|---|
| 海报（Primary） | 自身 `ImageTags["Primary"]` → 父级 `SeriesPrimaryImage`/`ParentThumbItemId` → 占位图 |
| 背景（Backdrop） | 自身 `BackdropImageTags[0]` → `ParentBackdropItemId` + `ParentBackdropImageTags[0]` → 用 Primary 模糊放大 |
| Logo | 自身 `ImageTags["Logo"]` → `ParentLogoItemId` + `ParentLogoImageTag` → 不显示 |
| 缩略图（Thumb） | 自身 `ImageTags["Thumb"]` → `ParentThumbItemId` + `ParentThumbImageTag` → 用 Primary |
| 人物 | `People[].PrimaryImageTag` 为空 → 首字母圆形占位 |

**继承字段** —— **当前版本（Reference 实测）`BaseItemDto` 上的字段** ✅：

`ParentLogoItemId`、`ParentLogoImageTag`、`ParentBackdropItemId`、`ParentBackdropImageTags`、`ParentThumbItemId`、`ParentThumbImageTag`、`PrimaryImageItemId`、`SeriesPrimaryImageTag`

> ⚠️ **`ParentArtItemId` / `ParentArtImageTag` 已不在当前 `BaseItemDto` 中**。
> - Images 文档页仍列着它们（<https://dev.emby.media/doc/restapi/Images.html>），属**旧版残留**。
> - 当前 Reference 的 `BaseItemDto` 里搜不到这两个字段（已逐字段核对 <https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>）。
> - 旧 OpenAPI 快照（4.1.1.0）里**有** `ParentArtItemId`/`ParentArtImageTag` —— 说明这两个字段在 4.1 之后被移除或改名。
> - **实现建议**：解码时保留这两个 key 但允许缺失；不要依赖它们做 Art 图回退，改用 `Backdrop`。

> 这些字段**默认可能不返回**，需要 `Fields` 或 `EnableImages=true`。若拿不到，说明要在请求里加 `EnableImages=true`（默认值未在文档明确，⚠️【待验证】）。

---

## 9. 实时事件（WebSocket）

### 9.1 连接 ✅

```
ws(s)://{host}:{port}/embywebsocket?api_key={token}&deviceId={deviceId}
```

- 构造方式：**把 http URL 的协议替换为 ws / https 替换为 wss**，不要手工拼 host（会丢掉端口和路径）。
- ✅ 来源：<https://dev.emby.media/doc/restapi/Web-Socket.html>（"Once connected to the server, simply take the server's http address, and change the protocol to ws:// or wss://. `ws://{host}?api_key={authenticationtoken}&deviceId={deviceId}`"）

**⚠️ 三处易错**：

1. **Emby 的路径是 `/embywebsocket`，Jellyfin 是 `/socket`**。
   - Jellyfin 侧证据（源码）：<https://github.com/jellyfin/jellyfin-apiclient-python/blob/b6561909/jellyfin_apiclient_python/ws_client.py>（`wsc_url = "%s/socket?api_key=%s&device_id=%s"`）
   - Emby 侧证据：官方文档 + 社区日志 `ws://{emby-server}/embywebsocket?api_key=...&device_id=...`（<https://emby.media/community/topic/80061-httpconnectionpool-read-timed-out>）
   - **实现建议**：先试 `/embywebsocket`，握手失败（HTTP 404/400）再试 `/socket`。⚠️【待验证】：有博客称 Emby 服务器也接受 `/socket`（<https://stevenwinkelman.com/projects/emby-plugin>，2026-08 实测），但非官方来源。

2. **参数名 `deviceId` vs `device_id`**：
   - 官方文档写 `deviceId`。
   - 但 Emby 生态的 Kodi 插件实际用的是 `device_id`，且能连上（日志见上条）。
   - **实现建议**：**两个都带上**：`?api_key=X&deviceId=Y&device_id=Y`。◐ 冗余参数无害。

3. **鉴权方式**：query 参数 `api_key`。也可以用 `X-Emby-Token` 头（Jellyfin 新版支持，Emby ⚠️【待验证】）。

### 9.2 消息格式 ✅

所有收发消息都是：

```json
{ "MessageType": "<名称>", "Data": <字符串或对象> }
```

- ✅ 来源：<https://dev.emby.media/doc/restapi/Web-Socket.html>

### 9.3 订阅机制（关键，官方文档没写全）◐

**「按间隔批量推送」的流（`Sessions`、`ScheduledTasksInfo`）必须先订阅**，否则一条都收不到。订阅方式是发 `<Name>Start`，取消是 `<Name>Stop`：

```json
{"MessageType": "SessionsStart", "Data": "0,1500"}
{"MessageType": "SessionsStop",  "Data": ""}
```

- `Data` 的格式是 `"<初始延迟ms>,<间隔ms>"`。
- ◐ 来源（社区实测，多个独立来源一致）：
  - <https://emby.media/community/topic/42452-websocket-usage-workflow>（"`{"MessageType":"SessionsStart", "Data": "0,1500"}` / `{"MessageType":"SessionsStop", "Data": ""}`"，并说明 "The 1500 is the interval in milliseconds"）
  - <https://emby.media/community/topic/56851-web-socket>（Emby 团队人员回复，指向 emby-webcomponents 的 sessionplayer.js）
  - Jellyfin Web 源码同样发 `sendMessage('SessionsStart', '0,1500')`：<https://github.com/jellyfin/jellyfin-web/commit/8cc88fb08c7ef3b4fb3874eb8e2d7346b4c10445>
- ⚠️ **官方 Web-Socket 文档页没有写订阅机制** —— 这是文档缺口。但所有实现都这么做，且不订阅就收不到 `Sessions`。

**Prism 需要的订阅**：

| 订阅 | 用途 |
|---|---|
| `SessionsStart "0,1500"` | 播放状态、谁在看什么、远程控制 |
| `ScheduledTasksInfoStart "1000,1000"` | 库扫描进度（可选，P2） |

> **哪些需要订阅**：只有「按间隔批量推送」的流（`Sessions`、`ScheduledTasksInfo`）需要 `*Start` 订阅。
> 事件型消息（`UserDataChanged`、`LibraryChanged`、`UserUpdated` 等）属于**连上即推** —— 官方文档把它们列在 "Once connected and identified, you'll be able to receive the following MessageTypes from the web socket" 之下，没有任何订阅前置条件（✅ <https://dev.emby.media/doc/restapi/Web-Socket.html>）。
> 实践上建议：**仍显式订阅 `SessionsStart`**，因为 `Sessions` 是唯一能可靠反映「谁在播什么」的通道（见 9.4 关于 `PlaybackStopped` 的说明）。

### 9.4 消息类型

#### 默认推送 ✅

| MessageType | Data | 说明 |
|---|---|---|
| `UserDataChanged` | `{ UserId, UserDataList: [...] }` | 用户改了评分/播放状态 |
| `UserDeleted` | 用户 Id 字符串 | 用户被删 |
| `UserUpdated` | 用户对象 | 用户信息更新 |
| `LibraryChanged` | `{ ItemsAdded, ItemsRemoved, ItemsUpdated, FoldersAddedTo, FoldersRemovedFrom, CollectionFolders }` ◐ | 媒体库变化 |
| `RestartRequired` | 无 | 需要重启服务器 |
| `ServerRestarting` / `ServerShuttingDown` | 无 | 服务器重启/关机 |
| `NotificationAdded` | 通知对象 | 新通知 |
| `NotificationsMarkedRead` | | 通知已读 |
| `Play` | `{ ItemIds, PlayCommand, StartPositionTicks, MediaSourceId, AudioStreamIndex, SubtitleStreamIndex, StartIndex }` | 远程控制：播放 |
| `Playstate` | `{ Command, SeekPositionTicks }` | 远程控制：`Stop`/`Pause`/`Unpause`/`NextTrack`/`PreviousTrack`/`Seek` |
| `GeneralCommand` | `{ Name, Arguments }` | 通用遥控指令 |

- ✅ **MessageType 名称**来源：<https://dev.emby.media/doc/restapi/Web-Socket.html>（逐条列出，Data 内层结构多数未展开）
- ◐ `LibraryChanged` 的 **Data 内层字段**（社区抓包，多个来源一致）：
  - <https://emby.media/community/topic/19933-emby-wont-sync-after-deleting-items-on-server>
  - <https://emby.media/community/topic/48414-issue-with-updating-ratings-for-movies>
  - 原文样例：`{"MessageType":"LibraryChanged","Data":{"FoldersAddedTo":[],"FoldersRemovedFrom":[],"ItemsAdded":[],"ItemsRemoved":[],"ItemsUpdated":["2556d2615bbf0250117c7d1dd33825cf"]}}`
  - ◐ 部分版本还带 `CollectionFolders`（<https://emby.media/community/topic/56750-error-getting-cast>）

#### 需订阅 ✅/◐

| MessageType | 说明 |
|---|---|
| `Sessions` | 完整会话列表（等同 `GET /Sessions` 的返回） |
| `SessionsStart` / `SessionsStop` | 订阅控制（客户端→服务器） |
| `ScheduledTasksInfo` | 计划任务进度 |
| `ActivityLogEntry` | 活动日志 |

- ◐ 来源：Jellyfin 的 `SessionMessageType` 枚举（Emby 同源）：<https://github.com/jellyfin/jellyfin/blob/master/MediaBrowser.Model/Session/SessionMessageType.cs>
  ```
  ForceKeepAlive, GeneralCommand, UserDataChanged, Sessions, Play, SyncPlayCommand,
  SyncPlayGroupUpdate, Playstate, RestartRequired, ServerShuttingDown, ServerRestarting,
  LibraryChanged, UserDeleted, UserUpdated, SeriesTimerCreated, TimerCreated,
  SeriesTimerCancelled, TimerCancelled, RefreshProgress, ScheduledTaskEnded,
  PackageInstallationCancelled, PackageInstallationFailed, PackageInstallationCompleted,
  PackageInstalling, PackageUninstalled, ActivityLogEntry, ScheduledTasksInfo,
  ActivityLogEntryStart, ActivityLogEntryStop, SessionsStart, SessionsStop,
  ScheduledTasksInfoStart, ScheduledTasksInfoStop, KeepAlive
  ```

#### ⚠️ `PlaybackStopped` / `PlaybackStart` —— 不要依赖

需求里提到 `PlaybackStopped`，但**核实结果如下**：

- ❌ Emby 官方 Web-Socket 文档的 MessageType 列表里**没有** `PlaybackStart` / `PlaybackStopped`。
- ◐ 但社区代码里确实出现过：Kodi 插件脚本判断 `job['MessageType'] == "PlaybackStopped"` / `"PlaybackStart"`，并读 `Data.NowPlayingItem.Type/SeriesName/IndexNumber`（来源：<https://emby.media/community/topic/52903-library-information>，2017 年）。
- 可能是**旧版本**的消息类型，或第三方插件自造。

**结论**：⚠️【待验证】。
- **正确做法**：订阅 `Sessions`，通过比对 `Sessions[].PlayState`（`PositionTicks` 归零 / 会话消失 / `NowPlayingItem` 变化）来判断播放开始与停止。
- **验证方法**：连上 WebSocket，订阅 `SessionsStart`，在另一台设备上播一个视频再停掉，把收到的所有 `MessageType` 打成日志，看是否真的出现 `PlaybackStopped`。

### 9.5 保活与重连 ⚠️

- 服务器会发 `KeepAlive`（Jellyfin 枚举中有，Emby 未在文档列出）—— 【待验证】。
- **建议**：客户端每 30s 主动发 `{"MessageType":"KeepAlive","Data":""}`；连续 2 次无响应则重连。
- 重连采用指数退避：1s → 2s → 4s → 8s，上限 30s。
- 重连成功后**必须重新发 `SessionsStart`**（订阅状态不跨连接保留）。

### 9.6 Swift 实现提示

- 用 `URLSessionWebSocketTask`（macOS 10.15+）。
- `receive()` 是拉模式，要**递归/循环调用**才能持续收消息。
- 消息可能是 `.string` 也可能是 `.data`，两种都要处理。
- 建议用 `AsyncStream<EmbySocketMessage>` 包装，上层 `for await`。

---

## 10. 音乐

### 10.1 Universal Audio 端点 ✅

```
GET /emby/Audio/{itemId}/universal
    ?UserId={userId}
    &DeviceId={deviceId}
    &api_key={token}
    &MaxStreamingBitrate=140000000
    &Container=mp3,aac,m4a,flac,wav,ogg,opus
    &TranscodingProtocol=hls
    &TranscodingContainer=ts
    &AudioCodec=aac
    &MaxSampleRate=48000
    &PlaySessionId={clientGeneratedId}
```

**参数** ✅（<https://dev.emby.media/doc/restapi/Audio-Streaming.html>）：

| 参数 | 必填 | 说明 |
|---|---|---|
| `UserId` | ✅ | 用户 Id |
| `DeviceId` | ✅ | 设备 Id |
| `api_key` | ✅ | token |
| `MaxStreamingBitrate` | ✅ | 码率上限 |
| `Container` | | 支持的容器，逗号分隔 |
| `MaxSampleRate` | | 最大采样率，如 `48000` |
| `PlaySessionId` | ✅ | **客户端自己生成**，每个流 URL 唯一 |
| `TranscodingProtocol` | | `hls` 或省略（=渐进式） |
| `TranscodingContainer` | | HLS 音频支持 `ts`/`aac`/`mp3` |
| `AudioCodec` | | 转码目标编码 |
| `EnableRedirection` | | 是否允许重定向到外部流 |
| `EnableRemoteMedia` | | 是否允许远程媒体重定向 |

- ✅ 官方原文："Emby has a single Universal Audio API Endpoint that supports both direct play as well as transcoding. You specify your supported formats as part of the URL, and the server will decide between direct play and transcoding."

> ⚠️ **文档与 OpenAPI 不一致**：Emby 的 OpenAPI 里 `/Audio/{Id}/universal` 只声明了 3 个参数（`Id`、`DeviceId`、`StartTimeTicks`），而文档页列了 12 个。
> - OpenAPI：<https://swagger.emby.media/openapi.json> → `/Audio/{Id}/universal`
> - 文档：<https://dev.emby.media/doc/restapi/Audio-Streaming.html>
> - **以文档页为准**（这些参数是运行时读取 query string，Swagger 生成器没抓到）。⚠️【待验证】：建议在真机上用完整参数 curl 一次，确认 200 且返回音频流。

**推荐用 HLS** ✅：

> "It is highly recommended that client players support HLS audio. HLS audio will guarantee that seeking is always client-side. Using progressive transcoding will result in much more complicated seeking."

- 即：`TranscodingProtocol=hls&TranscodingContainer=ts&AudioCodec=aac`。

### 10.2 直连音乐（更简单，优先用）

如果文件格式本地能播（mp3/aac/flac/alac/wav），**直接走直连**，不要用 universal：

```
GET /emby/Audio/{itemId}/stream?static=true&MediaSourceId={id}&DeviceId={did}&api_key={token}
```

或带扩展名（兼容性更好）：

```
GET /emby/Audio/{itemId}/stream.mp3?static=true&api_key={token}
GET /emby/Audio/{itemId}/stream.flac?static=true&api_key={token}
```

- ✅ `static=true` 直连：<https://dev.emby.media/doc/restapi/Audio-Streaming.html>（"To direct stream an audio file, simply use the static=true parameter."）
- ✅ 扩展名别名列表：`.mp3`、`.aac`、`.ogg`、`.oga`、`.webma`、`.wma`、`.flac`
- ✅ 必需参数：`Id`、`MediaSourceId`（文档："Item Id and MediaSourceId are the only required parameters"）

### 10.3 播放队列

Emby 的「队列」有两套：

**A. 客户端自管队列（推荐）**
- 客户端自己维护数组，逐首调用 `/Audio/{id}/stream`。
- 进度上报时用 `PlaylistIndex` / `PlaylistLength` / `PlaylistItemId` 让服务器知道队列状态。
- 优点：完全可控，无服务器状态。

**B. 服务器侧 PlayQueue**
```
GET /emby/Sessions/PlayQueue?Id={sessionId}&DeviceId={deviceId}
```
- ✅ 端点存在：<https://dev.emby.media/reference/RestAPI/SessionsService/getSessionsPlayqueue.html>（返回 `QueryResult<BaseItemDto>`）
- 用途：远程控制场景（另一台设备查看/修改你正在播的队列）。**MVP 不需要**。

### 10.4 播放列表 `/Playlists` ✅

**创建**：
```
POST /emby/Playlists?Name={name}&Ids={id1,id2}&MediaType=Audio&UserId={userId}
```
- `MediaType`（`Audio`/`Video`）与 `Ids` **二者必须给一个**；给了 `Ids` 可以省略 `MediaType`。
- ✅ 来源：<https://dev.emby.media/doc/restapi/Playlists.html>

**查询**：播放列表就是普通条目，`IncludeItemTypes=Playlist` 查即可。

**取列表项**：
```
GET /emby/Playlists/{id}/Items?UserId={userId}&StartIndex=0&Limit=100&Fields=...
```
- ✅ 返回 `QueryResult<BaseItemDto>`，每项带 `PlaylistItemId`（删除时必需）。

**加项**：
```
POST /emby/Playlists/{id}/Items?Ids={id1,id2}&UserId={userId}
```

**删项**：
```
DELETE /emby/Playlists/{id}/Items?EntryIds={playlistItemId1,playlistItemId2}
```
- ⚠️ 注意参数名是 **`EntryIds`**，值是 `PlaylistItemId`（不是条目 Id）。
- ✅ 来源：<https://dev.emby.media/doc/restapi/Playlists.html>

**移动项**：
```
POST /emby/Playlists/{id}/Items/{itemId}/Move/{newIndex}
```
- ✅ 端点存在：<https://swagger.emby.media/openapi.json> → `/Playlists/{Id}/Items/{ItemId}/Move/{NewIndex}`

### 10.5 音乐库浏览

- 专辑列表：`GET /Users/{userId}/Items?IncludeItemTypes=MusicAlbum&Recursive=true&ParentId={musicViewId}`
- 专辑内曲目：`GET /Users/{userId}/Items?ParentId={albumId}&IncludeItemTypes=Audio&SortBy=ParentIndexNumber,IndexNumber&SortOrder=Ascending,Ascending`
- 艺术家：`GET /Artists?UserId={userId}&ParentId={musicViewId}` 或 `IncludeItemTypes=MusicArtist`
- 即时混音（类似电台）：`GET /Items/{id}/InstantMix?UserId=&Limit=50` ✅（<https://swagger.emby.media/openapi.json> → `/Items/{Id}/InstantMix`）

---

## 11. 下载 / 离线

### 11.1 现状

**命名**：官方支持文档的产品名已是 **"Downloads & Sync"**（该页标题为 `Downloads & Sync > Download Options`），但**服务端 API 仍然叫 `/Sync/*`**。

- ✅ 命名来源（官方支持站）：<https://support.emby.media/support/articles/Sync.html>
- ✅ API 未改名：Emby OpenAPI 中仍是 `/Sync/Jobs`、`/Sync/JobItems` 等（<https://swagger.emby.media/openapi.json>）
- ⚠️ **"从哪个版本开始改名"未在官方资料中说明** —— 本文只能说"当前（4.8/4.9 时期）官方文档用 Downloads & Sync 这个名字"。若需要确切版本号，需查各版本 release notes。

**⚠️ 路径名纠正**：需求里写的 `/Sync/Job`（单数）**不存在**。实际是复数 **`/Sync/Jobs`**（已逐一比对 OpenAPI 的 356 条 path）。

**前置条件**：Sync 需要客户端声明 `SupportsSync=true` 并提供 `DeviceProfile`，且用户 `Policy.EnableSync=true`。

- ✅ 来源：<https://dev.emby.media/doc/restapi/Sync.html>

### 11.2 官方 Sync API（重量级，不推荐 MVP 用）

| 端点 | 说明 |
|---|---|
| `POST /Sync/Jobs` | 创建同步任务 |
| `GET /Sync/Jobs` | 列出任务 |
| `GET /Sync/Jobs/{id}` | 任务详情 |
| `DELETE /Sync/Jobs/{id}` | 删除任务 |
| `GET /Sync/JobItems` | 任务项 |
| `GET /Sync/JobItems/{id}/File` | **下载任务项文件** |
| `GET /Sync/JobItems/{id}/AdditionalFiles` | 附加文件（字幕等） |
| `POST /Sync/JobItems/{id}/Transferred` | 标记已传输 |
| `POST /Sync/JobItems/{id}/MarkForRemoval` | 标记待删 |
| `GET /Sync/Targets?UserId=` | 可用目标设备 |
| `GET /Sync/Options?UserId=&ItemIds=&TargetId=` | 可选项（画质等） |

- ✅ 全部路径来源：<https://swagger.emby.media/openapi.json>
- ✅ 页面：<https://dev.emby.media/reference/RestAPI/SyncService.html>

**`POST /Sync/Jobs` 请求体 `SyncJobRequest`** ✅：

| 字段 | 类型 | 说明 |
|---|---|---|
| `TargetId` | string | **客户端的 DeviceId** |
| `ItemIds` | string[] | 要同步的条目 |
| `Category` | string | 类别（`Latest`/`Resume`/`NextUp` 等） |
| `ParentId` | string | 限定范围（同步类别时必填） |
| `Quality` | string | 画质 |
| `Profile` | string | 设备配置名 |
| `Name` | string | 任务名（多选时才给） |
| `UserId` | string | 用户 |
| `UnwatchedOnly` | bool | 只同步未看 |
| `SyncNewContent` | bool | 自动同步新内容 |
| `ItemLimit` | int | 条目上限 |
| `Bitrate` | int | 码率 |

- ✅ 来源：<https://swagger.emby.media/openapi.json> → `Sync.Model.SyncJobRequest`
- ✅ 语义来源：<https://dev.emby.media/doc/restapi/Sync.html>

**⚠️ Sync 的坑**：
- 服务器会**先转码**再等设备来取（"the download job will initially do any requested conversion and then it will be ready to be transferred"）→ 任务有「准备中」状态，客户端要轮询。
- 设备不在线时任务一直挂着。
- `GET /Sync/JobItems/{id}/File` 的返回是**文件流**，不是 JSON。
- 整套流程官方文档明说 "Client-side sync management: Coming soon" / "Offline access: Coming soon" —— **官方没有给出完整客户端实现指南**。

### 11.3 自建下载管理器（✅ 推荐路径）

对 macOS 客户端，**自建下载管理器远比接 Sync 简单可控**：

**① 单条目下载原始文件**

```
GET /emby/Items/{itemId}/Download
```

- ✅ 端点存在，语义 "Downloads item media"：<https://dev.emby.media/reference/RestAPI/LibraryService/getItemsByIdDownload.html>
- ⚠️ 返回什么格式官方未说明（可能是转码后的流，也可能是原文件）——【待验证】。**验证方法**：`curl -OJ -H "X-Emby-Token: X" ".../Items/ID/Download"`，看文件名与 Content-Type。

**② 下载原始文件（更明确）**

```
GET /emby/Items/{itemId}/File
```

- ✅ 语义 "Gets the original file of an item"：<https://swagger.emby.media/openapi.json> → `/Items/{Id}/File`；页面 <https://dev.emby.media/reference/RestAPI/LibraryService/getItemsByIdFile.html>
- 这个明确是**原文件**，适合离线保真。

**③ 直接用直连流（最通用）**

```
GET /emby/Videos/{itemId}/stream?static=true&MediaSourceId={id}&api_key={token}
```

- 加 `Range` 头即可断点续传（直连是静态文件服务，支持 Range）。
- ✅ `static=true` 语义：<https://dev.emby.media/doc/restapi/Video-Streaming.html>

**④ 音频**

```
GET /emby/Audio/{itemId}/stream?static=true&api_key={token}
```

**⑤ 转码下载（可选，用于省流量）**

用 PlaybackInfo 拿 `TranscodingUrl`（HLS），把分片拼成文件 —— 复杂且易错，**不建议**。若要转码版，用渐进式：
```
GET /emby/Videos/{id}/stream?Container=mp4&VideoCodec=h264&AudioCodec=aac&VideoBitrate=2000000&api_key=...
```

**自建管理器要点**：

| 关注点 | 做法 |
|---|---|
| 断点续传 | 用 `Range: bytes=N-` + `URLSessionDownloadTask` 的 resumeData |
| 并发 | 同时最多 2–3 个下载任务（服务器转码/IO 压力） |
| 存储布局 | `~/Library/Application Support/Prism/Downloads/{serverId}/{itemId}/` |
| 元数据 | 本地存一份精简 `BaseItemDto` JSON（`Id/Name/Type/RunTimeTicks/ImageTags/MediaSources[0].Id`） |
| 图片离线 | 同时缓存 Primary/Backdrop 到本地，否则离线时海报空白 |
| 进度记录 | 离线播放的进度存本地，联网后补发 `/Sessions/Playing/Stopped` |
| 权限判断 | `UserData`/`Policy.EnableContentDownloading`；条目上 `CanDownload` 字段 |
| 失效检测 | 服务器返回 404/403 时标记为失效，提示用户重下 |

- ◐ 上表是工程实践建议，非 Emby 官方规定。
- ✅ `CanDownload` 字段确实存在于 `BaseItemDto`：<https://swagger.emby.media/openapi.json>

---

## 12. 标记已看 / 收藏 / 评分

### 12.1 标记已看 ✅

```
POST   /emby/Users/{userId}/PlayedItems/{itemId}          → 标记已看
DELETE /emby/Users/{userId}/PlayedItems/{itemId}          → 标记未看
```

- 可选 query：`DatePlayed`，格式 **`yyyyMMddHHmmss`**（如 `20261021143000`）
- 返回：`UserItemDataDto`（更新后的用户数据，可直接用来刷新 UI）
- ✅ 来源：<https://dev.emby.media/reference/RestAPI/PlaystateService/postUsersByUseridPlayeditemsById.html>
- ✅ 删除：<https://dev.emby.media/reference/RestAPI/PlaystateService/deleteUsersByUseridPlayeditemsById.html>
- ✅ 返回类型 `UserItemDataDto`：<https://swagger.emby.media/openapi.json>

> 对 **Series** 标记已看会级联到所有集（◐ 社区一致行为，官方未明说）。⚠️【待验证】：在剧集详情页点"标记已看"后，检查 `UserData.Played` 与各集的 `UserData.Played`。

### 12.2 收藏 ✅

```
POST   /emby/Users/{userId}/FavoriteItems/{itemId}   → 收藏
DELETE /emby/Users/{userId}/FavoriteItems/{itemId}   → 取消收藏
```

- 返回 `UserItemDataDto`
- ✅ 来源：<https://dev.emby.media/reference/RestAPI/UserLibraryService/postUsersByUseridFavoriteitemsById.html>
- ✅ 删除：`/Users/{UserId}/FavoriteItems/{Id}` 的 `delete`（<https://swagger.emby.media/openapi.json>）

### 12.3 评分（喜欢/不喜欢）✅

```
POST   /emby/Users/{userId}/Items/{itemId}/Rating?Likes=true    → 喜欢
POST   /emby/Users/{userId}/Items/{itemId}/Rating?Likes=false   → 不喜欢
DELETE /emby/Users/{userId}/Items/{itemId}/Rating                → 清除评分
```

- 参数名是 **`Likes`**（bool），不是 `Rating`。
- 返回 `UserItemDataDto`
- ✅ 来源：<https://swagger.emby.media/openapi.json> → `/Users/{UserId}/Items/{Id}/Rating`（`post` 有 `Likes` query 参数；`delete` 无参数）
- ✅ 页面：<https://dev.emby.media/reference/RestAPI/UserLibraryService/postUsersByUseridItemsByIdRating.html>

> ⚠️ **路径纠正**：需求里写的 `/Items/{id}/Rating` 在 Emby 4.x 的 OpenAPI 中**不存在**（已逐一比对 356 条 path）。正确路径必须带 `Users/{userId}` 前缀：`/Users/{UserId}/Items/{Id}/Rating`。

### 12.4 统一更新用户数据（批量）✅

```
POST /emby/Users/{userId}/Items/{itemId}/UserData
```

Body 是 `UserItemDataDto`（与 GET 返回的结构相同），可含：`Played`、`PlaybackPositionTicks`、`IsFavorite`、`Likes`、`PlayCount`、`LastPlayedDate`、`Rating`、`PlayedPercentage`、`UnplayedItemCount`、`ItemId`

- ✅ 端点与请求体类型：<https://dev.emby.media/reference/RestAPI/PlaystateService/postUsersByUseridItemsByItemidUserdata.html>（"Updates userdata for an item"，body = `UserItemDataDto`）
- ✅ 响应：**200 + 空 body**（不返回更新后的对象，需自行 GET 回读或本地更新）
- 用途：离线播放后同步本地状态；或一次性修改多个属性。
- ⚠️ 该端点**不在** Emby OpenAPI 快照（<https://swagger.emby.media/openapi.json>）中，但官方 Reference 页存在。哪些字段真正生效未在文档明示 ——【待验证】。**建议优先用 12.1–12.3 的专用端点**，此端点仅作离线批量补同步的兜底。

### 12.5 反向同步：WebSocket 通知

标记已看/收藏后，服务器会向**所有**连接推送 `UserDataChanged`：

```json
{
  "MessageType": "UserDataChanged",
  "Data": {
    "UserId": "...",
    "UserDataList": [ { "ItemId": "...", "Played": true, "PlayCount": 1, ... } ]
  }
}
```

- ✅ MessageType 来源：<https://dev.emby.media/doc/restapi/Web-Socket.html>
- ◐ Data 内层结构：文档只说 "Data = a json object with the following properties: UserId, UserDataList - a list of updated user data objects"，**内层字段名未列出**。按 `UserItemDataDto` 推断。
- **用途**：多端同步 —— 在 iPhone 上标记已看，Mac 上的海报墙立刻更新。

---

## 13. 用户数据同步（Resume / Latest / NextUp）

### 13.1 继续观看：`GET /Users/{userId}/Items/Resume` ✅

```
GET /emby/Users/{userId}/Items/Resume
    ?Limit=20
    &Fields=PrimaryImageAspectRatio,ProductionYear,UserData
    &MediaTypes=Video
    &Recursive=true
```

- 返回 `QueryResult<BaseItemDto>`，按 `UserData.LastPlayedDate` 倒序。
- 每项 `UserData.PlaybackPositionTicks` 即续播点。
- ✅ 端点：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItemsResume.html>
- ✅ 支持参数与 `/Users/{userId}/Items` **基本相同**（`Limit`、`Fields`、`MediaTypes`、`ParentId`、`Recursive`、`IncludeItemTypes`、`EnableUserData`…）—— 见 <https://swagger.emby.media/openapi.json> 中该端点的参数列表

> ⚠️ 注意：`Resume` 返回的是**有播放进度但未完成**的条目。若用户看到 95% 就停了，Emby 会在接近结尾时自动标记为已看并移出 Resume（具体阈值未在文档说明，⚠️【待验证】）。

### 13.2 最新添加：`GET /Users/{userId}/Items/Latest` ✅

```
GET /emby/Users/{userId}/Items/Latest
    ?ParentId={viewId}
    &Limit=20
    &Fields=PrimaryImageAspectRatio,ProductionYear,UserData
    &IncludeItemTypes=Movie
    &GroupItems=false
```

| 参数 | 说明 |
|---|---|
| `ParentId` | 限定某视图/文件夹 |
| `Limit` | 条数（**注意：没有 `StartIndex`**，见下） |
| `Fields` | 同上 |
| `IncludeItemTypes` | 限定类型 |
| `IsFolder` | 只看文件夹 |
| `IsPlayed` | 只看已看/未看 |
| `GroupItems` | **默认 true**：同一容器的条目合并成一个（如最新剧集按剧聚合），`ChildCount` 存组内数量 |
| `EnableImages` / `ImageTypeLimit` / `EnableImageTypes` / `EnableUserData` | 同上 |

- ✅ 来源：<https://dev.emby.media/reference/RestAPI/UserLibraryService/getUsersByUseridItemsLatest.html>
- ✅ 文档（含 `GroupItems` 语义与示例）：<https://dev.emby.media/doc/restapi/Latest-Items.html>

**⚠️ 返回类型不是 QueryResult！** Emby OpenAPI 标为 `array`（直接是 `BaseItemDto[]`），**没有 `TotalRecordCount`**。
- ✅ 证据：<https://swagger.emby.media/openapi.json> → `/Users/{UserId}/Items/Latest` → 200 → `array`
- 这意味着：**Latest 不能分页**。要"加载更多"只能加大 `Limit`。
- ⚠️ 但官方文档页 `Latest-Items.html` 说支持 `StartIndex` —— 与 OpenAPI 冲突。**以 OpenAPI 为准**，`StartIndex` 大概率被忽略。⚠️【待验证】：实测传 `StartIndex=20` 看返回是否变化。

**`GroupItems` 的用法** ✅（官方示例）：
- 最新电影：`?IncludeItemTypes=Movie&Limit=20&IsPlayed=false`
- 最新剧集（按剧聚合）：`?IncludeItemTypes=Episode&Limit=20&IsPlayed=false&GroupItems=true` → 返回 Series 列表
- 点开某剧看具体几集：`?Limit=4&IsPlayed=false&GroupItems=false&ParentId={SeriesId}`

### 13.3 下一集：`GET /Shows/NextUp` ✅

见 5.4。返回 `QueryResult<BaseItemDto>`。

### 13.4 首页组合建议

| 首页行 | 数据来源 |
|---|---|
| 继续观看 | `GET /Users/{id}/Items/Resume?Limit=20&Fields=...` |
| 下一集 | `GET /Shows/NextUp?UserId={id}&Limit=20&Fields=...` |
| 最新电影 | `GET /Users/{id}/Items/Latest?ParentId={moviesView}&IncludeItemTypes=Movie&Limit=20` |
| 最新剧集 | `GET /Users/{id}/Items/Latest?ParentId={tvView}&IncludeItemTypes=Episode&Limit=20&GroupItems=true` |
| 我的媒体（各库入口） | `GET /Users/{id}/Views` |
| 推荐 | `GET /Movies/Recommendations?UserId={id}&Limit=20` ✅（端点存在：<https://swagger.emby.media/openapi.json> → `/Movies/Recommendations`） |

- ✅ 官方 HomeSections 端点：`GET /Users/{userId}/HomeSections`，返回的是**首页各行的配置**（显示哪些行、顺序），**不是数据**。
  - ✅ 文档页：<https://dev.emby.media/reference/RestAPI/ContentService/getUsersByUseridHomesections.html>
  - ⚠️ 该端点**不在** Emby OpenAPI 快照（<https://swagger.emby.media/openapi.json>）里，参数/返回结构未公开 ——【待验证】实际用法与字段。MVP 阶段直接硬编码首页行顺序即可。

---

## 14. 常见坑（逐条带证据）

### 14.1 Ticks 单位 ⚠️ 最坑

- **正确**：1 tick = 100 ns，**10,000,000 ticks = 1 秒**。
- **错误来源**：Emby Swagger 里 `StartTimeTicks` 的描述写 "1 tick = 10000 ms"，**完全错误**，照抄会导致进度条算成几百万天。
  - <https://dev.emby.media/reference/RestAPI/VideoService/getVideosByIdStream.html>
- **自检方法**：拿一部 90 分钟的电影，`RunTimeTicks` 应该约 `54,000,000,000`。若你算出 90 分钟对应 `540,000`，说明用错了单位。

### 14.2 `SortBy` 多字段语法

- `SortBy=A,B,C&SortOrder=Descending,Descending,Ascending` —— 逗号分隔，**位置一一对应**。
- ✅ <https://dev.emby.media/doc/restapi/Browsing-the-Library.html>
- 坑：只写 `SortOrder=Ascending` 配 3 个 `SortBy`，官方没说会怎样 —— **写满等长**。

### 14.3 `Fields` 不传就为空

- 列表接口默认极简，`Overview`/`People`/`MediaSources`/`Chapters` 全是 `null`。
- 单条查询 `GET /Users/{id}/Items/{itemId}` 才返回全量。
- ✅ <https://dev.emby.media/doc/restapi/Browsing-the-Library.html>
- 坑：Swagger 的 Fields 说明只有 17 项，**实际枚举有 97 项**（见 4.3）。

### 14.4 分页与 `TotalRecordCount`

- 用 `StartIndex` + `Limit` 分页；`TotalRecordCount` 是**过滤后总数**。
- 坑 1：`Latest` 端点**没有** `TotalRecordCount`，返回裸数组，**不能分页**。
- 坑 2：`Limit` 过大（如 10000）会导致服务器超时/内存暴涨。**建议 ≤ 200**。
- 坑 3：不带 `Limit` 时服务器有默认上限（⚠️【待验证】具体值官方未说明，社区经验在 100–1000 之间）—— **永远显式传 `Limit`**。
- 坑 4：`StartIndex` 超过 `TotalRecordCount` 时返回空数组而非报错，不要据此判断接口出错。

### 14.5 转码 URL 里的 `api_key` 与 `deviceId` 必须一致

- `TranscodingUrl` 里已经内嵌了 `api_key`、`DeviceId`、`MediaSourceId`、`PlaySessionId`。
- **不要替换/删除其中任何一个**：转码任务是按 `(DeviceId, PlaySessionId)` 索引的，改了服务器就找不到任务 → 404 或重新起一个转码。
- ✅ 真实样例见 6.2.3；`DeviceId` 用于「停止编码进程」：<https://dev.emby.media/reference/RestAPI/HlsSegmentService/deleteVideosActiveencodings.html>（`DELETE /Videos/ActiveEncodings?DeviceId=&PlaySessionId=`）

**播放结束务必清理转码进程** ✅：

```
DELETE /emby/Videos/ActiveEncodings?DeviceId={deviceId}&PlaySessionId={playSessionId}
```

- ✅ 来源：<https://dev.emby.media/doc/restapi/Http-Live-Streaming.html>（"After playback is complete, it is necessary to inform the server to stop any related HLS transcoding. This is accomplished via an HTTP DELETE to: /Videos/ActiveEncodings?DeviceId=xxx"）
- 坑：不调这个，服务器会一直转码直到超时，CPU 白烧。

### 14.6 `DirectStreamUrl` 存在 ≠ 能直封

- Emby 在**需要转码**时仍会返回 `DirectStreamUrl`，其值常常就是 `TranscodingUrl`（带 `TranscodeReasons=`）。
- **判断直封能力只看 `SupportsDirectStream`**，不要看 URL 是否存在。
- ◐ 证据：<https://emby.media/community/topic/92430-session-playstate-mediasourceid-session-fullplayingitemgetmediasources>（`SupportsDirectStream:false` 但 `DirectStreamUrl` 有值）
- 详见 6.4。

### 14.7 HLS 分片与 seek

- HLS 转码**不能**客户端 seek（不是静态文件）。
- **seek 方法**：停止当前流，用新的 `StartTimeTicks` 重新请求 `master.m3u8`。
- ✅ 来源：<https://dev.emby.media/doc/restapi/Video-Streaming.html>（"When transcoding, this will not be possible. In order to seek you'll have to stop the stream and start a new one using the StartTimeTicks parameter."）
- 直连/直封（`static=true`）**可以**客户端 seek（支持 Range）。
- 音频 HLS 例外：官方说 HLS 音频「seek 永远是客户端侧的」✅（<https://dev.emby.media/doc/restapi/Audio-Streaming.html>）。

**坑**：seek 后 `PlaySessionId` 要不要换？—— 不要换，复用同一个，否则服务器会当成新会话。⚠️【待验证】：实测 seek 后进度上报是否正常。

### 14.8 图片 404 回退

- 对象没指示图片存在就去请求 → 必然 404。
- 必须先查 `ImageTags` / `BackdropImageTags` / `Parent*ImageTag`。
- ✅ <https://dev.emby.media/doc/restapi/Images.html>
- 坑：`Backdrop` 的 `Index` 超范围也 404；`BackdropImageTags.Count` 才是可用数量。

### 14.9 时区 / 日期格式

- 所有 `date-time` 是 **UTC + 7 位小数秒 + Z**，如 `2014-05-15T09:52:52.5898360Z`。
- `ISO8601DateFormatter` 默认不支持 7 位小数 → **解析失败**。
- `DatePlayed` 参数格式完全不同：**`yyyyMMddHHmmss`**（无时区、无分隔符）。
- ✅ 两种格式来源：<https://dev.emby.media/reference/RestAPI/PlaystateService/postUsersByUseridPlayeditemsById.html>（DatePlayed）；<https://dev.emby.media/doc/restapi/Remote-Control.html>（7 位小数样例）

```swift
// 7 位小数秒的解析
let f = DateFormatter()
f.locale = Locale(identifier: "en_US_POSIX")
f.timeZone = TimeZone(secondsFromGMT: 0)
f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSZZZZZ"
// 兜底：无小数秒
let f2 = DateFormatter()
f2.locale = Locale(identifier: "en_US_POSIX")
f2.timeZone = TimeZone(secondsFromGMT: 0)
f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
```

### 14.10 RateLimit

- Emby 官方**未公布**速率限制。
- 429 可能出现（社区 FAQ：<https://emby.wiki/en/faq>）。
- **建议**：并发 ≤ 6；429 时指数退避；海报墙滚动时取消不可见图片请求（`URLSessionTask.cancel()`）。
- ⚠️【待验证】：真实阈值需压测。

### 14.11 其他坑

| 坑 | 说明 | 来源 |
|---|---|---|
| `AuthenticationResult.User` 是对象不是数组 | 需兼容解码 | 见 2.2（◐ 文档标数组、实现为对象） |
| `PlaySessionId` 每次 PlaybackInfo 都变 | 必须重新取，不能缓存 | <https://swagger.emby.media/openapi.json> |
| `MediaSource.RunTimeTicks` ≠ `BaseItemDto.RunTimeTicks` | 多版本时长可能不同，播放器用 MediaSource 的 | <https://dev.emby.media/doc/restapi/Playback-Guidelines.html>（"make sure to use the runtime value from the MediaSource and not the containing item"） |
| `MediaStreams` 已过时 | 播放决策用 `MediaSources`，`MediaStreams` 仅展示 | <https://dev.emby.media/doc/restapi/Item-Information.html> |
| 条目 Id 无连字符 | 是 32 位 hex，不是 UUID 格式 | 样例见 4.5 |
| `Person` 图片按 Name 寻址 | 需 URL 编码，同名会撞 | <https://swagger.emby.media/openapi.json> → `/Persons/{Name}/Images/{Type}` |
| `Latest` 返回数组非 QueryResult | 无 TotalRecordCount | 见 13.2 |
| `Playlist` 删项参数是 `EntryIds` 且值是 `PlaylistItemId` | 不是条目 Id | <https://dev.emby.media/doc/restapi/Playlists.html> |
| `POST /Users/{id}/PlayedItems/{id}` 的日期格式是 `yyyyMMddHHmmss` | 与其他接口不同 | 见 14.9 |
| Emby WebSocket 路径 ≠ Jellyfin | `/embywebsocket` vs `/socket` | 见 9.1 |
| UDP 发现报文 Emby ≠ Jellyfin | `who is EmbyServer?` vs `Who is JellyfinServer?` | 见 3.1 |

---

## 15. MVP 端点清单

> 优先级定义：**P0** = 没有它 App 不能跑；**P1** = 完整体验必需；**P2** = 增强。

| 端点 | 用途 | 优先级 | 备注 |
|---|---|---|---|
| `GET /System/Info/Public` | 验证服务器、取 ServerName/Id/Version | **P0** | 无需 token；手动填 URL 后的第一枪 |
| `POST /Users/AuthenticateByName` | 登录换 token | **P0** | body 字段是 `Pw`；需 `X-Emby-Authorization` 头 |
| `GET /Users/Public` | 登录页用户列表 | P2 | 可选，做头像登录页才用 |
| `POST /Sessions/Logout` | 登出吊销 token | P1 | 只在用户主动登出时调 |
| `GET /Users/{userId}/Views` | 媒体库入口 | **P0** | 用 `CollectionType` 决定 UI |
| `GET /Users/{userId}/Items` | 列表/搜索/筛选 | **P0** | 最核心；`Fields` 必传 |
| `GET /Users/{userId}/Items/{itemId}` | 详情页 | **P0** | 返回全量字段 |
| `GET /Users/{userId}/Items/Resume` | 继续观看 | **P0** | 首页第一行 |
| `GET /Users/{userId}/Items/Latest` | 最新添加 | P1 | 裸数组，不能分页 |
| `GET /Shows/NextUp` | 下一集 | P1 | 剧集首页 |
| `GET /Shows/{seriesId}/Seasons` | 季列表 | P1 | |
| `GET /Shows/{seriesId}/Episodes` | 集列表 | **P0** | `SeasonId` 或 `Season` 二选一 |
| `GET /Items/{itemId}/Similar` | 相似推荐 | P2 | 返回 QueryResult |
| `POST /Items/{itemId}/PlaybackInfo` | 播放协商 | **P0** | DeviceProfile 是成败关键 |
| `POST /Sessions/Playing` | 开始播放上报 | **P0** | 带 PlayMethod/PlaySessionId |
| `POST /Sessions/Playing/Progress` | 进度上报 | **P0** | 10s + 交互触发 |
| `POST /Sessions/Playing/Stopped` | 停止上报 | **P0** | 带最终 PositionTicks |
| `DELETE /Videos/ActiveEncodings` | 停止转码进程 | **P0** | 不调会一直烧 CPU |
| `GET /Items/{itemId}/Images/{Type}` | 所有图片 | **P0** | 必须带 `tag` + `maxWidth` |
| `GET /Users/{userId}/Images/{Type}` | 用户头像（Type=Primary） | P1 | Type 是路径段 |
| `GET /Persons/{name}/Images/{Type}` | 演员头像（Type=Primary） | P2 | Name 需 URL 编码 |
| `GET /Videos/{itemId}/stream` | 视频直连/直封/转码流 | **P0** | `static=true` 走直封 |
| `GET /Videos/{itemId}/master.m3u8` | HLS 转码 | **P0** | 或直接用 PlaybackInfo 的 TranscodingUrl |
| `POST /Users/{userId}/PlayedItems/{itemId}` | 标记已看 | **P0** | 播放完成自动调 |
| `DELETE /Users/{userId}/PlayedItems/{itemId}` | 标记未看 | P1 | |
| `POST /Users/{userId}/FavoriteItems/{itemId}` | 收藏 | P1 | |
| `DELETE /Users/{userId}/FavoriteItems/{itemId}` | 取消收藏 | P1 | |
| `POST /Users/{userId}/Items/{itemId}/Rating` | 喜欢/不喜欢 | P2 | 参数 `Likes` |
| `GET /Audio/{itemId}/stream` | 音乐直连 | P1 | 音乐 MVP 优先走直连 |
| `GET /Audio/{itemId}/universal` | 音乐转码 | P2 | HLS 音频；参数以文档页为准 |
| `GET /Playlists/{id}/Items` | 播放列表内容 | P2 | |
| `POST /Playlists` | 创建播放列表 | P2 | |
| `POST /Playlists/{id}/Items` | 加入列表 | P2 | |
| `DELETE /Playlists/{id}/Items` | 移出列表 | P2 | 参数 `EntryIds` |
| `ws://.../embywebsocket` | 实时事件 | P1 | 订阅 `SessionsStart`；用于多端同步 |
| `GET /Items/{itemId}/File` | 下载原文件 | P1 | 离线功能核心 |
| `GET /Items/{itemId}/Download` | 下载条目 | P2 | 返回格式待确认 |
| `GET /Sync/Jobs` / `POST /Sync/Jobs` | 官方同步 | P2 | 复杂，自建下载器优先 |
| `GET /Sessions` | 会话列表/远程控制 | P2 | |
| `POST /Sessions/Capabilities` | 声明客户端能力 | P2 | 声明 `SupportsSync` 才可用 Sync |
| `GET /Users/{userId}/HomeSections` | 首页行配置 | P2 | 不在 OpenAPI 中，返回结构待验证；MVP 可硬编码 |
| `GET /Movies/Recommendations` | 推荐 | P2 | |
| `GET /Items/{itemId}/ThemeMedia` | 主题曲/片头 | P2 | 需 `InheritFromParent` |
| `GET /Connect/Exchange` | Emby Connect 换 token | P2 | 先做手动 URL |
| UDP 7359 广播 | 局域网自动发现 | P1 | 报文 `who is EmbyServer?` |

**排期建议（3 个迭代）**：

- **迭代 1（能看片）**：`System/Info/Public` → `AuthenticateByName` → `Views` → `Items` → `Items/{id}` → `PlaybackInfo` → `stream`/`master.m3u8` → 三个 Playing 上报 → 图片。
- **迭代 2（好用）**：Resume / Latest / NextUp / Episodes / 已看收藏 / WebSocket / UDP 发现 / 音频直连。
- **迭代 3（增强）**：下载离线 / 播放列表 / 相似推荐 / Emby Connect / 远程控制。

---

## 16. 来源与置信度

### 16.1 已核实（有官方 URL 直接支撑）

| # | 结论 | 来源 |
|---|---|---|
| 1 | API base 为 `http[s]://host:port/emby/{apipath}` | <https://dev.emby.media/doc/restapi/index.html> |
| 2 | 鉴权头格式 `Emby UserId="", Client="", Device="", DeviceId="", Version="", Token=""`，头名可为 `Authorization` 或 `X-Emby-Authorization` | <https://dev.emby.media/doc/restapi/User-Authentication.html>；<https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html> |
| 3 | 登录 `POST /Users/AuthenticateByName`，body `{Username, Pw}`，返回 `AuthenticationResult{AccessToken, ServerId, User, SessionInfo}` | <https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html> |
| 4 | 后续请求用 `X-Emby-Token` 头；401 = token 被吊销 | <https://dev.emby.media/doc/restapi/User-Authentication.html> |
| 5 | 登出 `POST /Sessions/Logout`（吊销 token） | 同上 |
| 6 | API Key 可用 `X-Emby-Token` 头或 `api_key` 查询参数 | <https://dev.emby.media/doc/restapi/API-Key-Authentication.html> |
| 7 | `GET /System/Info/Public` 返回 `PublicSystemInfo{Id, ServerName, Version, LocalAddress, WanAddress, OperatingSystem}` | <https://swagger.emby.media/openapi.json>；<https://dev.emby.media/reference/RestAPI/SystemService/getSystemInfoPublic.html> |
| 8 | UDP 7359 广播文本 `who is EmbyServer?`，响应 `{Address, Id, Name}` | <https://dev.emby.media/doc/restapi/Locating-the-Server.html> |
| 9 | Emby Connect 流程（authenticate → servers → Connect/Exchange） | <https://dev.emby.media/doc/restapi/Emby-Connect.html> |
| 10 | `GET /Users/{userId}/Views` 返回 `QueryResult<BaseItemDto>`，`CollectionType` 取值枚举 | <https://dev.emby.media/doc/restapi/Browsing-the-Library.html>；<https://swagger.emby.media/openapi.json> |
| 11 | `GET /Users/{userId}/Items` 完整参数表（84 个） | <https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>；<https://swagger.emby.media/openapi.json> |
| 12 | `ItemFields` 枚举全集（97 项） | <https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Querying.ItemFields.html> |
| 13 | `Filters` 取值 `IsFolder/IsNotFolder/IsUnplayed/IsPlayed/IsFavorite/IsResumable/Likes/Dislikes` | <https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html> |
| 14 | `SortBy`/`SortOrder` 逗号分隔且位置对应 | <https://dev.emby.media/doc/restapi/Browsing-the-Library.html> |
| 15 | 列表默认字段被裁剪，需 `Fields` 显式请求 | 同上 |
| 16 | `QueryResult` 含 `Items` + `TotalRecordCount` | <https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html> |
| 17 | `BaseItemDto` / `UserItemDataDto` / `BaseItemPerson` / `ChapterInfo` 字段 | <https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>（当前版本，163 个 BaseItemDto 字段）；<https://dev.emby.media/reference/RestAPI/UserLibraryService/postUsersByUseridItemsByIdRating.html>（UserItemDataDto） |
| 18 | 条目字段语义（`IndexNumber`、`ParentIndexNumber`、`SeriesId`、`ImageTags`、`BackdropImageTags`、`UserData`…） | <https://dev.emby.media/doc/restapi/Item-Information.html> |
| 19 | `POST /Items/{Id}/PlaybackInfo` 请求体 `PlaybackInfoRequest` 字段全集；**Emby 侧只接受 body，无 query 参数** | <https://swagger.emby.media/openapi.json>；<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html> |
| 20 | `DeviceProfile` 及其子结构（`DirectPlayProfile`/`TranscodingProfile`/`CodecProfile`/`ProfileCondition`/`SubtitleProfile`/`ResponseProfile`）字段与枚举 | <https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Dlna.DeviceProfile.html>；<https://swagger.emby.media/openapi.json> |
| 21 | DeviceProfile 的 DLNA 专属属性可省略 | <https://dev.emby.media/doc/restapi/Sync.html> |
| 22 | `PlaybackInfoResponse{MediaSources, PlaySessionId, ErrorCode}` | <https://swagger.emby.media/openapi.json> |
| 23 | `MediaSourceInfo` 含 `DirectStreamUrl`、`TranscodingUrl`、`TranscodingSubProtocol`、`TranscodingContainer`、`Chapters`（共 49 个字段） | <https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Dto.MediaSourceInfo.html>；<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html> |
| 24 | Direct Play / Direct Stream / Transcode 定义与选择算法 | <https://dev.emby.media/doc/restapi/Playback-Guidelines.html> |
| 25 | `static=true` 表示直封；转码时 seek 需用 `StartTimeTicks` 重新请求 | <https://dev.emby.media/doc/restapi/Video-Streaming.html> |
| 26 | HLS 入口 `/Videos/{Id}/master.m3u8`，必需 `MediaSourceId`、`DeviceId` | <https://dev.emby.media/doc/restapi/Http-Live-Streaming.html> |
| 27 | 播完需 `DELETE /Videos/ActiveEncodings?DeviceId=` | 同上 |
| 28 | HLS 分片路径 `/Videos/{Id}/hls/{PlaylistId}/{SegmentId}.{SegmentContainer}` | <https://dev.emby.media/reference/RestAPI/VideoHlsService/getVideosByIdHlsByPlaylistidBySegmentidBySegmentcontainer.html> |
| 29 | `/Sessions/Playing`、`/Progress`、`/Stopped` 三端点及 `PlayMethod` 取值 | <https://dev.emby.media/doc/restapi/Playback-Check-ins.html> |
| 30 | `PlaybackStartInfo`（30 字段）/ `PlaybackProgressInfo`（30 字段，与前者完全相同）/ `PlaybackStopInfo`（14 字段） | <https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlaying.html>；<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingProgress.html>；<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingStopped.html> |
| 31 | `ProgressEvent` 枚举（16 值） | <https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingProgress.html> |
| 32 | 进度上报节奏：10s + 交互即时；服务器每秒自增 | <https://dev.emby.media/doc/restapi/Playback-Check-ins.html> |
| 33 | `ItemId` 与 `Item` 二选一 | 同上 |
| 34 | 图片端点参数（maxWidth/maxHeight/width/height/quality/tag/format/…） | <https://dev.emby.media/reference/RestAPI/ImageService/getItemsByIdImagesByType.html> |
| 35 | 图片 `Type` 枚举（Primary/Art/Backdrop/Banner/Logo/Thumb/Disc/Box/BoxRear/Screenshot/Menu/Chapter） | <https://swagger.emby.media/openapi.json> |
| 36 | tag 即缓存键；建议按去掉 host:port 的 URL 缓存 | <https://dev.emby.media/doc/restapi/Images.html> |
| 37 | 无图必 404；有 `Parent*ItemId`/`Parent*ImageTag` 继承机制 | 同上 |
| 38 | WebSocket 地址 `ws://{host}?api_key=&deviceId=`，消息格式 `{MessageType, Data}` | <https://dev.emby.media/doc/restapi/Web-Socket.html> |
| 39 | WebSocket 消息类型列表（GeneralCommand/UserDataChanged/UserDeleted/UserUpdated/NotificationAdded/NotificationsMarkedRead/RestartRequired/ServerRestarting/ServerShuttingDown/Play/Playstate） | 同上 |
| 40 | `/Audio/{Id}/universal` 参数表与 HLS 音频建议 | <https://dev.emby.media/doc/restapi/Audio-Streaming.html> |
| 41 | 音频直连 `static=true`；`/Audio/{Id}/stream.{Container}` 别名 | 同上 |
| 42 | Playlists 创建/取项/加项/删项（`EntryIds`） | <https://dev.emby.media/doc/restapi/Playlists.html> |
| 43 | Sync 需 `SupportsSync=true` + DeviceProfile；用户需 `Policy.EnableSync` | <https://dev.emby.media/doc/restapi/Sync.html> |
| 44 | `POST /Sync/Jobs` body `SyncJobRequest` 字段全集 | <https://swagger.emby.media/openapi.json> |
| 45 | `GET /Items/{Id}/Download`（Downloads item media）、`GET /Items/{Id}/File`（original file） | <https://dev.emby.media/reference/RestAPI/LibraryService/getItemsByIdDownload.html>；<https://swagger.emby.media/openapi.json> |
| 46 | `PlayedItems` POST/DELETE、`DatePlayed` 格式 `yyyyMMddHHmmss` | <https://dev.emby.media/reference/RestAPI/PlaystateService/postUsersByUseridPlayeditemsById.html> |
| 47 | `FavoriteItems` POST/DELETE | <https://dev.emby.media/reference/RestAPI/UserLibraryService/postUsersByUseridFavoriteitemsById.html> |
| 48 | `Items/{Id}/Rating` 的 `Likes` 参数 | <https://swagger.emby.media/openapi.json> |
| 49 | `Items/Resume`、`Items/Latest`、`Shows/NextUp` 参数与返回 | <https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItemsResume.html>；<https://dev.emby.media/reference/RestAPI/UserLibraryService/getUsersByUseridItemsLatest.html>；<https://dev.emby.media/reference/RestAPI/TvShowsService/getShowsNextup.html> |
| 50 | `GroupItems` 默认 true 及分组语义 | <https://dev.emby.media/doc/restapi/Latest-Items.html> |
| 51 | 播完条目用 MediaSource 的 RunTimeTicks 而非条目的 | <https://dev.emby.media/doc/restapi/Playback-Guidelines.html> |
| 52 | `MediaStreams` 已被 `MediaSources` 取代，仅用于展示 | <https://dev.emby.media/doc/restapi/Item-Information.html> |
| 53 | `Genres` field 会带出 `GenreItems` | 同上 |
| 54 | 多服务器场景 token 必须与 ServerId 一起存 | <https://dev.emby.media/doc/restapi/User-Authentication.html> |
| 55 | 官方建议先做手动 URL 再做 Emby Connect | <https://dev.emby.media/doc/restapi/Emby-Connect.html> |

### 16.2 社区一致但官方未明确

| # | 结论 | 依据 |
|---|---|---|
| 1 | `AuthenticationResult.User` 实际是**对象**而非数组（与 Swagger 标注冲突） | 所有真实客户端实现（Jellyfin Web、Swiftfin、jellyfin-apiclient-python）均按对象解析；官方 Swagger 标 `UserDto[]` |
| 2 | WebSocket 需 `SessionsStart "0,1500"` 订阅才推 `Sessions` | <https://emby.media/community/topic/42452-websocket-usage-workflow>；<https://emby.media/community/topic/56851-web-socket>（Emby 团队成员回复）；Jellyfin Web 源码同做法 |
| 3 | `LibraryChanged` 的 `Data` 结构为 `{ItemsAdded, ItemsRemoved, ItemsUpdated, FoldersAddedTo, FoldersRemovedFrom, CollectionFolders}` | 多个 Emby 抓包日志：<https://emby.media/community/topic/19933-emby-wont-sync-after-deleting-items-on-server>、<https://emby.media/community/topic/56750-error-getting-cast> |
| 4 | `TranscodingUrl` 内含 `TranscodeReasons=` 便于诊断 | 真实响应样例：<https://github.com/AkimioJR/MediaWarp/blob/main/docs/DEV.md> |
| 5 | Emby 也接受 `device_id`（下划线）参数 | Kodi 插件日志：<https://emby.media/community/topic/80061-httpconnectionpool-read-timed-out> |
| 6 | 自建直封 URL 模板 `/Videos/{id}/stream?static=true&MediaSourceId=...` | 多个第三方客户端实现，如 <https://github.com/AkimioJR/MediaWarp> |
| 7 | 官方 Swagger 的 "1 tick = 10000 ms" 是错的，正确为 100ns | 由 `RunTimeTicks` 实测量级反证（90 分钟电影 ≈ 5.4e10 ticks） |
| 8 | 官方支持站产品名已是 "Downloads & Sync"，但 API 仍是 `/Sync/*`（改名起始版本未查到） | <https://support.emby.media/support/articles/Sync.html> + OpenAPI 仍含 `/Sync/*` |
| 9 | 对 Series 标记已看会级联到所有集 | 社区普遍行为，官方文档未写 |
| 10 | `POST /Sessions/Playing/Stopped` 发多余字段不会报错 | .NET `System.Text.Json` 默认忽略未知字段（推断，未实测） |
| 15 | `swagger.emby.media/openapi.json` 版本是 4.1.1.0，落后于当前 Reference | 文件自身 `info.version`；与 Reference 逐 schema 比对得出字段数差异 |
| 11 | 根路径（无 `/emby` 前缀）也可访问 API | 反向代理配置把 `/` 直接代理到 8096 且工作：<https://emby.media/community/topic/40461-emby-server-with-apache-reverse-proxy> |
| 12 | Emby 服务器也接受 `/socket` 路径 | 第三方实测博客：<https://stevenwinkelman.com/projects/emby-plugin>（2026-08） |
| 13 | **`DirectStreamUrl` 在需要转码时也会返回**，且常与 `TranscodingUrl` 相同 → 不能当作直封能力标志 | Emby 真实会话 JSON：<https://emby.media/community/topic/92430-session-playstate-mediasourceid-session-fullplayingitemgetmediasources>（`SupportsDirectStream:false` 却有 `DirectStreamUrl`） |
| 14 | `TranscodeReasons` query 参数可读出转码原因 | 同一抓包样例 + <https://github.com/AkimioJR/MediaWarp/blob/main/docs/DEV.md> |

### 16.3 待验证（必须在真实服务器上确认后再依赖）

| # | 待验证项 | 风险 | 验证方法 |
|---|---|---|---|
| 1 | `POST /Items/{id}/PlaybackInfo` 在 Emby 上是否也接受 **query 参数**（Emby OpenAPI 只声明 body；Jellyfin 声明了 query+body） | 高：若 Emby 严格校验未知 query 会 400 | 分别用「只 body」「只 query」「两者都发」请求 Emby 4.8 / 4.9 / Jellyfin 10.9，对比返回的 MediaSources 是否按 DeviceProfile 变化 |
| 2 | `DirectStreamUrl` 在 **Emby 4.9.x** 是否仍返回（4.8 及更早已确认有，schema 里也在） | 中：不返回则需自行拼 URL | 对同一 item 打 PlaybackInfo，`jq '.MediaSources[0].DirectStreamUrl'`；分别在 4.8 与 4.9 服务器上各跑一次 |
| 3 | `PlaybackStopInfo` 是否接受 `PlayMethod` 等 schema 外字段 | 中：若 400 则要裁剪 | 发完整字段，看返回码；再用 `Failed=true` 场景测 |
| 4 | `Latest` 端点是否支持 `StartIndex` | 中：影响"加载更多" | 传 `StartIndex=20&Limit=20`，比较返回的第一条是否变化 |
| 5 | Emby 的 `PlaybackStart`/`PlaybackStopped` WebSocket 消息是否还存在 | 中：影响"停止即刷新" | 连 WS 订阅 `SessionsStart`，另一设备播放/停止，记录全部 MessageType |
| 6 | `/Audio/{Id}/universal` 的完整 query 参数（文档 12 个 vs OpenAPI 3 个） | 中：音乐转码可能不生效 | 用文档页的完整参数 curl，确认 200 且 Content-Type 为音频/`application/vnd.apple.mpegurl` |
| 7 | `Fields=SyncInfo` 是否被接受（枚举里只有 `BasicSyncInfo`） | 低 | 分别传 `SyncInfo` 与 `BasicSyncInfo`，看 `SupportsSync` 是否填充 |
| 8 | Emby 是否接受 `/socket` WebSocket 路径 | 低：可只支持 `/embywebsocket` | 用 `websocat` 分别连两个路径 |
| 9 | Emby API 的实际速率限制阈值 | 中：批量拉取可能被 429 | 并发压测，记录首次 429 的 QPS |
| 10 | `POST /Users/{id}/Items/{itemId}/UserData` 哪些字段可写 | 低 | 逐字段 POST 后 GET 回读比对 |
| 11 | `GET /Items/{Id}/Download` 返回原文件还是转码流 | 中：影响离线画质 | `curl -OJ` 看文件名与 Content-Type；对比 `Size` 与 `MediaSource.Size` |
| 12 | `EnableImages` 默认值 | 低：影响图片字段是否返回 | 不传 vs 传 `true` 对比 `ImageTags` |
| 13 | 人物头像是否有按 Id 的端点（现只有 `/Persons/{Name}/...`） | 低 | 试 `/Persons/{personId}/Images/Primary` |
| 14 | Emby 4.9 是否仍保留 `GET /Items/{Id}/PlaybackInfo`（GET 版本） | 低 | 直接 GET 一次 |
| 15 | Series 标记已看是否级联 | 低 | 标记后查各集 `UserData.Played` |
| 16 | Resume 的"看完"判定阈值 | 低 | 播到 90%/95%/99% 分别停止，看是否移出 Resume |
| 17 | HLS seek 后 `PlaySessionId` 是否应复用 | 中：复用错会导致进度错乱 | seek 后用同一/新 PlaySessionId 各测一次，看 dashboard 与进度 |
| 18 | WebSocket `KeepAlive` 消息是否由 Emby 发出 | 低 | 空转 5 分钟，记录收到的心跳 |
| 19 | `UserItemDataDto.Likes` 在 4.8/4.9 是否仍返回 | 中：影响「喜欢」按钮状态 | POST `/Users/{id}/Items/{id}/Rating?Likes=true`，检查返回 DTO 的 keys |
| 20 | `ParentArtItemId`/`ParentArtImageTag` 在 4.8/4.9 是否仍返回 | 低：Art 图回退 | 拉一个 Season 详情，`jq '.ParentArtItemId'` |

### 16.4 已知文档缺陷汇总（供后续维护）

| 缺陷 | 位置 | 影响 |
|---|---|---|
| **`swagger.emby.media/openapi.json` 是 4.1.1.0 旧快照**，比当前 Reference 少字段（`PlaybackStartInfo` 21 vs 30） | <https://swagger.emby.media/openapi.json>（`info.version`） | **严重**：据此生成模型会丢字段 |
| Ticks 单位写成 "1 tick = 10000 ms" | <https://dev.emby.media/reference/RestAPI/VideoService/getVideosByIdStream.html> | 严重：进度条全错 |
| `AuthenticationResult.User` 标为数组 | <https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html> | 解码崩溃 |
| `Fields` 参数说明只列 17 项（实际 97 项） | <https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html> | 漏字段 |
| `/Audio/{Id}/universal` OpenAPI 只列 3 个参数 | <https://swagger.emby.media/openapi.json> | 音乐转码参数找不到 |
| Web-Socket 文档未写订阅机制 | <https://dev.emby.media/doc/restapi/Web-Socket.html> | 收不到 Sessions |
| `PlaybackStopInfo` 只有 14 字段，但文档说与 Start「完全相同」 | <https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingStopped.html> vs <https://dev.emby.media/doc/restapi/Playback-Check-ins.html> | 不知道发什么 |
| `UserItemDataDto` 里 `Likes` 在 Reference 中缺失、在 OpenAPI 中存在 | <https://dev.emby.media/reference/RestAPI/UserLibraryService/postUsersByUseridItemsByIdRating.html> vs <https://swagger.emby.media/openapi.json> | 喜欢状态读不到 |
| `ParentArtItemId`/`ParentArtImageTag` 已不在当前 `BaseItemDto`，但 Images 文档仍列 | <https://dev.emby.media/doc/restapi/Images.html> vs <https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html> | Art 图回退失效 |
| Sync 客户端实现文档 "Coming soon" | <https://dev.emby.media/doc/restapi/Sync.html> | 无官方实现指南 |
| `PlaybackStartInfo` 文档有 `QueueableMediaTypes`，schema 无 | 同上 | 多发字段 |
| Latest 文档说支持 StartIndex，OpenAPI 标为数组 | <https://dev.emby.media/doc/restapi/Latest-Items.html> | 分页歧义 |

---

## 附录 A：Swift 客户端骨架建议

```swift
// MARK: - 凭据
struct EmbyCredentials: Codable {
    let serverId: String
    let serverURL: URL       // 含 /emby 的 base
    let userId: String
    let accessToken: String
    let deviceId: String     // 必须持久化
}

// MARK: - 客户端
actor EmbyClient {
    private let base: URL
    private let token: String
    private let deviceId: String
    private let authHeader: String
    private let session: URLSession

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        req.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp)
        return try JSONDecoder.emby.decode(T.self, from: data)
    }

    private static func validate(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        switch http.statusCode {
        case 200...299: return
        case 401: throw EmbyError.tokenRevoked
        case 404: throw EmbyError.notFound
        case 429: throw EmbyError.rateLimited
        default:  throw EmbyError.http(http.statusCode)
        }
    }
}

// MARK: - JSON 解码器（日期容错）
extension JSONDecoder {
    static var emby: JSONDecoder {
        let d = JSONDecoder()
        let f1 = DateFormatter()
        f1.locale = Locale(identifier: "en_US_POSIX")
        f1.timeZone = TimeZone(secondsFromGMT: 0)
        f1.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSZZZZZ"
        let f2 = DateFormatter()
        f2.locale = Locale(identifier: "en_US_POSIX")
        f2.timeZone = TimeZone(secondsFromGMT: 0)
        f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let d = f1.date(from: s) ?? f2.date(from: s) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Bad date: \(s)"))
        }
        return d
    }
}
```

**实现顺序建议**：

1. `URLSession` 配置：`waitsForConnectivity = true`、`timeoutIntervalForRequest = 30`、`timeoutIntervalForResource = 3600`（长视频流需要）。
2. 播放流请求**不要**用默认超时，`URLSessionConfiguration` 单独给播放器一份。
3. 图片走 `URLCache`（`memoryCapacity = 100MB`，`diskCapacity = 2GB`）。
4. 进度上报用独立 `actor` + `Task` 定时器，避免阻塞 UI。
5. 播放器建议：AVPlayer（mp4/mov/h264/hevc）或 libmpv/VLCKit（mkv/更多编码）。**这决定了 DeviceProfile 里的 DirectPlayProfiles 白名单**。

---

## 附录 B：快速自检清单

开发代理在联调前逐项打勾：

- [ ] base URL 拼接正确（`/emby` 前缀、无重复斜杠）
- [ ] `X-Emby-Authorization` 与 `X-Emby-Token` 两个头都发
- [ ] `DeviceId` 持久化（重装才变）
- [ ] 登录 body 用 `Pw`
- [ ] `AuthenticationResult.User` 兼容对象/数组
- [ ] 日期解析支持 7 位小数秒
- [ ] Ticks 换算用 10,000,000/秒
- [ ] 所有列表请求都传 `Fields` 与 `Limit`
- [ ] 图片请求都带 `tag` 与 `maxWidth`
- [ ] PlaybackInfo 的 `PlaySessionId` 全程透传
- [ ] 转码 URL 不手工改动
- [ ] 播放结束调 `DELETE /Videos/ActiveEncodings`
- [ ] 进度上报 10s 一次 + 交互即时
- [ ] WebSocket 连上后发 `SessionsStart`
- [ ] 直封判定用 `SupportsDirectStream`，**不是** `DirectStreamUrl` 是否存在
- [ ] `PlaybackStopInfo` 按 14 字段发（不要塞 `PlayMethod`）
- [ ] `UserData.Likes` 解码为 `Bool?` 且允许缺失
- [ ] 解码模型用 Reference 字段表，**不要**用 `swagger.emby.media/openapi.json`（4.1.1.0 旧快照）
- [ ] 401 统一跳登录页

---

*本文档基于 2026-10-21 可访问的官方资料编写。Emby 版本迭代较快，若服务器升级到 4.10+，请重新核对 `ItemFields` 枚举与 `DeviceProfile` 字段。*
