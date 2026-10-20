# 已核实事实库（主管亲自核查）

> 规则：本文件只收「有官方来源 URL 支撑」的事实。团队其他文档引用事实时优先引用这里。
> 核查人：主管 ｜ 最后更新：2026-10-21

## A. Emby 认证

### A1. 鉴权头格式 ✅
```
Authorization: Emby UserId="<guid>", Client="<client>", Device="<device>", DeviceId="<id>", Version="<ver>", Token="<token>"
```
- 头部名称可以是 `Authorization` 或 `X-Emby-Authorization`，二者等价。
- 来源：https://dev.emby.media/doc/restapi/User-Authentication.html
- 来源：https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html

### A2. 登录端点 ✅
- `POST /Users/AuthenticateByName`
- 请求体：`AuthenticateUserByName { Username: string, Pw: string }`（注意密码字段名是 **`Pw`** 不是 `Password`）
- 响应 200：`AuthenticationResult { User, SessionInfo, AccessToken, ServerId }`
- 来源：https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html

### A3. 后续请求携带 token 的方式 ✅
- 返回的 `AccessToken` 用请求头 **`X-Emby-Token`** 携带（官方 User Authentication 文档明示）。
- 401 表示 token 被撤销 → 应跳回登录页。
- 登出：`POST /Sessions/Logout`（会吊销 token）。
- 来源：https://dev.emby.media/doc/restapi/User-Authentication.html

### A4. ⚠️ 官方文档与实现不一致（已记录）
- Swagger 页面把 `AuthenticationResult.User` 标为 `UserDto[]`（**数组**），但 Emby 实际返回的是**单个对象**。
- 处理方式：客户端解码要**同时容忍对象与单元素数组**（自定义 `init(from:)` 做兼容）。
- 状态：◐ 文档标注为数组，社区实现均为对象。需在真实服务器上最终确认。
- 来源（文档侧）：https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html

### A5. UserDto 关键字段 ✅
`Name`、`ServerId`、`ServerName`、`Id`、`PrimaryImageTag`、`HasPassword`、`LastLoginDate`、`LastActivityDate`、`DateCreated`、`Policy`、`Configuration`
- 来源：同上

## B. 服务器发现

### B1. UDP 7359 协议 ✅
- 向 UDP 端口 **7359** 发送**广播**消息，文本内容恰为：`who is EmbyServer?`
- 响应是一个 JSON，包含三个属性：**`Address`、`Id`、`Name`**
- 来源：https://dev.emby.media/doc/restapi/Locating-the-Server.html
- 来源（镜像）：https://github.com/MediaBrowser/Emby/wiki/Locating-the-Server

## C. 播放进度上报

### C1. `/Sessions/Playing` 请求体字段 ✅
`QueueableMediaTypes`（数组，"Audio"/"Video"）、`CanSeek`、`ItemId` 或 `Item`、`MediaSourceId`、`AudioStreamIndex`、`SubtitleStreamIndex`、`IsPaused`、`IsMuted`、`PositionTicks`、`VolumeLevel`(0-100)、`PlayMethod`（`Transcode`/`DirectStream`/`DirectPlay`）、`PlaySessionId`、`LiveStreamId`、`PlaylistIndex`、`PlaylistLength`、`SubtitleOffset`、`PlaybackRate`
- Content-Type 必须是 `application/json`
- 来源：https://github.com/MediaBrowser/Emby/wiki/Playback-Check-Ins

### C2. ItemId vs Item ✅
- 播放服务器库内条目：只传 `ItemId`，省略 `Item`。
- 播放库外内容：传 `Item` 对象描述媒体。
- 来源：同上

### C3. Item 对象字段 ✅
`Name`、`MediaType`（Audio/Video/Book/Game）、`Type`（Movie/Episode/Trailer/Video/Audio/Book/Game）、`RunTimeTicks`、`PremiereDate`、`ProductionYear`、`IndexNumber`、`IndexNumberEnd`、`ParentIndexNumber`、`SeriesName`、`Album`、`Artists`
- 来源：同上

## D. 播放协商

### D1. PlaybackInfo 端点 ✅
- `POST /Items/{Id}/PlaybackInfo`（属 MediaInfoService），返回 MediaSources 与 MediaStreams。
- 真实返回样例中 MediaStream 字段：`Codec`、`Language`、`TimeBase`、`DisplayTitle`、`DisplayLanguage`、`IsInterlaced`、`ChannelLayout`、`BitRate`、`Channels`、`SampleRate`、`IsDefault`、`IsForced`、`Profile`、`Type`（"Audio"/"Subtitle"…）、`Index`、`IsExternal`、`IsTextSubtitleStream`、`SupportsExternalStream`、`Protocol`、`AttachmentSize`、`Height`、`Width`
- 来源（社区实测样例）：https://emby.media/community/topic/99809-a-tool-for-tagging-emby-content/page/43
- 状态：◐ 社区实测，字段名可信；仍需真实服务器 curl 复核

### D2. DeviceProfile 结构 ✅
- `MediaBrowser.Model.Dlna.DeviceProfile`，属性含 `DirectPlayProfiles`（`DirectPlayProfile[]`）等。
- 来源：https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Dlna.DeviceProfile.html
- 完整字段仍需查 `DirectPlayProfile` / `TranscodingProfile` / `CodecProfile` / `SubtitleProfile` 各页

## E. 待核查清单（交 API 代理补）

- [ ] `GET /Users/{userId}/Items` 的完整 query 参数表与 `ItemFields` 枚举全集
- [ ] `PlaybackInfo` 的 POST body（`DeviceProfile`）完整 JSON schema
- [ ] `MediaSources` 中 `DirectStreamUrl` / `TranscodingUrl` / `PlaySessionId` 的确切字段名
- [ ] `/Sessions/Playing/Progress` 与 `/Sessions/Playing/Stopped` 与 `/Sessions/Playing` 的字段差异
- [ ] WebSocket `/embywebsocket` 的鉴权与消息类型
- [ ] 图片端点 `/Items/{id}/Images/{type}` 的 query 参数
