import Foundation

/// 录制的 Emby 响应样例（JSON 字符串常量）。
///
/// ## 为什么是字符串常量而不是 `.json` 资源
///
/// `Package.swift` 没有给 `EmbyAPI` 配置 `resources:`（该文件是受保护文件，本工单不得修改），
/// 因此 `Bundle.module` 不可用。把 JSON 作为 Swift 字符串常量放进源码，是最省事且
/// 没有资源打包问题的做法：测试直接 `EmbyJSON.decode(_:from: Data(Fixtures.x.utf8))`。
///
/// ## 数据约定
///
/// 这些样例刻意贴近真实 Emby 输出：
/// - 字段名 PascalCase（`RunTimeTicks`、`UserData`、`ImageTags`…）；
/// - 时间是 .NET 的 7 位小数秒 ISO8601（`2024-04-10T04:24:53.0000000Z`）；
/// - 时长是 ticks（10,000,000 ticks = 1 秒）；
/// - 条目 id 是 32 位无连字符 hex。
///
/// 样例结构依据（已核实）：
/// - `BaseItemDto`：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>
/// - `QueryResult`：同上（`Items` + `TotalRecordCount`）
/// - `AuthenticationResult`：<https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html>
/// - `PublicSystemInfo`：<https://dev.emby.media/reference/RestAPI/SystemService/getSystemInfoPublic.html>
/// - `PlaybackInfoResponse`：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
///
/// - Note: 所有 id / 地址 / 令牌都是**虚构的**，禁止写入任何真实服务器信息。
public enum Fixtures {}

// MARK: - 系统与认证

public extension Fixtures {
    /// `GET /System/Info/Public` 的真实形态。
    static let publicInfo = """
    {
      "Id": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
      "ServerName": "Living Room Emby",
      "Version": "4.8.11.0",
      "ProductName": "Emby Server",
      "OperatingSystem": "Linux",
      "LocalAddress": "http://192.168.1.10:8096",
      "WanAddress": "https://emby.example.com",
      "LocalAddresses": [
        "http://192.168.1.10:8096",
        "http://10.0.0.5:8096"
      ],
      "RemoteAddresses": [
        "https://emby.example.com"
      ]
    }
    """

    /// `POST /Users/AuthenticateByName` —— **对象形态**（Emby 实际返回的形态）。
    static let authenticate = """
    {
      "User": {
        "Name": "alice",
        "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
        "ServerName": "Living Room Emby",
        "Id": "8a1f0b2c3d4e5f60718293a4b5c6d7e8",
        "HasPassword": true,
        "HasConfiguredPassword": true,
        "EnableAutoLogin": false,
        "PrimaryImageTag": "a1b2c3d4e5f60718293a4b5c6d7e8f90",
        "LastLoginDate": "2026-10-19T11:02:43.0000000Z",
        "LastActivityDate": "2026-10-21T00:41:12.0000000Z",
        "DateCreated": "2023-02-11T08:15:00.0000000Z",
        "Policy": {
          "IsAdministrator": true,
          "IsHidden": false,
          "IsDisabled": false,
          "EnableMediaPlayback": true,
          "EnableContentDownloading": true,
          "EnableSyncTranscoding": true
        },
        "Configuration": {
          "AudioLanguagePreference": "eng",
          "PlayDefaultAudioTrack": true,
          "SubtitleLanguagePreference": "chi",
          "DisplayMissingEpisodes": false,
          "SubtitleMode": "Smart",
          "EnableNextEpisodeAutoPlay": true
        }
      },
      "SessionInfo": {
        "PlayState": {
          "CanSeek": false,
          "IsPaused": false,
          "IsMuted": false,
          "VolumeLevel": 100,
          "PlayMethod": "DirectPlay",
          "RepeatMode": "RepeatNone"
        },
        "RemoteEndPoint": "192.168.1.24",
        "Protocol": "Http",
        "PlayableMediaTypes": ["Audio", "Video"],
        "Id": "d41f2c9e8b7a6051425364758697a8b9",
        "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
        "UserId": "8a1f0b2c3d4e5f60718293a4b5c6d7e8",
        "UserName": "alice",
        "UserPrimaryImageTag": "a1b2c3d4e5f60718293a4b5c6d7e8f90",
        "Client": "Prism",
        "LastActivityDate": "2026-10-21T00:41:12.0000000Z",
        "DeviceName": "fuunylmz的Mac Mini",
        "DeviceType": "Mac",
        "DeviceId": "3c1b2a49-7f8e-4d5c-9a0b-1c2d3e4f5061",
        "ApplicationVersion": "0.1.0",
        "SupportedCommands": ["MoveUp", "MoveDown", "VolumeUp", "VolumeDown"],
        "SupportsRemoteControl": true
      },
      "AccessToken": "f3e2d1c0b9a87f6e5d4c3b2a1908f7e6",
      "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617"
    }
    """

    /// 同一响应的**数组形态**（官方 Swagger 标注的 `UserDto[]` / `SessionInfo[]`）。
    ///
    /// 用于验证 ``AuthenticationResult`` 的兼容解码：两种形态都必须能解出同一个用户。
    static let authenticateArrayShape = """
    {
      "User": [
        {
          "Name": "alice",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "ServerName": "Living Room Emby",
          "Id": "8a1f0b2c3d4e5f60718293a4b5c6d7e8",
          "HasPassword": true,
          "PrimaryImageTag": "a1b2c3d4e5f60718293a4b5c6d7e8f90",
          "LastLoginDate": "2026-10-19T11:02:43.0000000Z",
          "DateCreated": "2023-02-11T08:15:00.0000000Z",
          "Policy": {
            "IsAdministrator": true,
            "IsHidden": false,
            "IsDisabled": false
          }
        }
      ],
      "SessionInfo": [
        {
          "Id": "d41f2c9e8b7a6051425364758697a8b9",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "UserId": "8a1f0b2c3d4e5f60718293a4b5c6d7e8",
          "UserName": "alice",
          "Client": "Prism",
          "DeviceName": "fuunylmz的Mac Mini",
          "DeviceId": "3c1b2a49-7f8e-4d5c-9a0b-1c2d3e4f5061",
          "ApplicationVersion": "0.1.0"
        }
      ],
      "AccessToken": "f3e2d1c0b9a87f6e5d4c3b2a1908f7e6",
      "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617"
    }
    """

    /// `GET /Users/Me` 的最小可用形态（只有必需字段）。
    static let currentUserMinimal = """
    {
      "Id": "8a1f0b2c3d4e5f60718293a4b5c6d7e8",
      "Name": "alice",
      "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617"
    }
    """
}

// MARK: - 媒体库

public extension Fixtures {
    /// `GET /Users/{userId}/Views`。
    static let views = """
    {
      "Items": [
        {
          "Name": "Movies",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "1f2e3d4c5b6a79880716253443526170",
          "Guid": "1f2e3d4c-5b6a-7988-0716-253443526170",
          "Type": "CollectionFolder",
          "CollectionType": "movies",
          "IsFolder": true,
          "ImageTags": {},
          "BackdropImageTags": [],
          "UserData": { "Played": false, "PlayCount": 0, "IsFavorite": false }
        },
        {
          "Name": "TV Shows",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "2a3b4c5d6e7f80910a2b3c4d5e6f7081",
          "Type": "CollectionFolder",
          "CollectionType": "tvshows",
          "IsFolder": true,
          "ImageTags": {},
          "BackdropImageTags": [],
          "UserData": { "Played": false, "PlayCount": 0, "IsFavorite": false }
        },
        {
          "Name": "Music",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "3b4c5d6e7f8091021b3c4d5e6f708192",
          "Type": "CollectionFolder",
          "CollectionType": "music",
          "IsFolder": true,
          "UserData": { "Played": false, "PlayCount": 0, "IsFavorite": false }
        },
        {
          "Name": "Home Videos",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "4c5d6e7f809102132c4d5e6f708192a3",
          "Type": "CollectionFolder",
          "IsFolder": true,
          "UserData": { "Played": false, "PlayCount": 0, "IsFavorite": false }
        }
      ],
      "TotalRecordCount": 4
    }
    """

    /// `GET /Users/{userId}/Items?IncludeItemTypes=Movie` —— 5 部电影，含完整
    /// `UserData` / `ImageTags` / `MediaSources`。
    static let itemsMovies = """
    {
      "Items": [
        {
          "Name": "Blade Runner 2049",
          "OriginalTitle": "Blade Runner 2049",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "0f8d0805a66f7ed429ecd8890146c7c3",
          "Etag": "b7e2f4a1c9d30586ae41f2739b0c8d5e",
          "DateCreated": "2024-04-10T04:24:53.0000000Z",
          "PremiereDate": "2017-10-06T00:00:00.0000000Z",
          "ProductionYear": 2017,
          "OfficialRating": "R",
          "CommunityRating": 8.1,
          "CriticRating": 81,
          "RunTimeTicks": 97800000000,
          "Overview": "K, an officer with the LAPD, unearths a long-buried secret that has the potential to plunge what is left of society into chaos.",
          "Genres": ["Science Fiction", "Drama", "Thriller"],
          "PrimaryImageAspectRatio": 0.6666666666666666,
          "ImageTags": {
            "Primary": "3a4b5c6d7e8f90a1b2c3d4e5f6071829",
            "Logo": "9f8e7d6c5b4a39281706f5e4d3c2b1a0",
            "Thumb": "1a2b3c4d5e6f708192a3b4c5d6e7f809"
          },
          "BackdropImageTags": [
            "4d5e6f708192a3b4c5d6e7f8091a2b3c",
            "5e6f708192a3b4c5d6e7f8091a2b3c4d"
          ],
          "Type": "Movie",
          "MediaType": "Video",
          "IsFolder": false,
          "Container": "mkv",
          "SortName": "Blade Runner 2049",
          "ParentId": "1f2e3d4c5b6a79880716253443526170",
          "UserData": {
            "PlaybackPositionTicks": 0,
            "PlayCount": 2,
            "IsFavorite": true,
            "Played": true,
            "LastPlayedDate": "2026-09-30T20:15:44.0000000Z"
          },
          "MediaSources": [
            {
              "Protocol": "File",
              "Id": "37bcb3827aeb2095f1b6293e9a189072",
              "Path": "/mnt/media/Movies/Blade Runner 2049 (2017)/Blade Runner 2049 (2017) - 2160p.mkv",
              "Type": "Default",
              "Container": "mkv",
              "Size": 22474836480,
              "Name": "Blade Runner 2049 - 2160p",
              "IsRemote": false,
              "RunTimeTicks": 97800000000,
              "SupportsTranscoding": true,
              "SupportsDirectStream": true,
              "SupportsDirectPlay": true,
              "MediaStreams": [
                {
                  "Codec": "hevc",
                  "Language": "eng",
                  "TimeBase": "1/1000",
                  "DisplayTitle": "4K HEVC HDR",
                  "DisplayLanguage": "English",
                  "IsInterlaced": false,
                  "BitRate": 18432000,
                  "Height": 2160,
                  "Width": 3840,
                  "VideoRange": "HDR",
                  "Profile": "Main 10",
                  "Type": "Video",
                  "Index": 0,
                  "IsDefault": true,
                  "IsExternal": false
                },
                {
                  "Codec": "eac3",
                  "Language": "eng",
                  "TimeBase": "1/1000",
                  "DisplayTitle": "English Dolby Digital Plus 5.1 (Default)",
                  "DisplayLanguage": "English",
                  "ChannelLayout": "5.1",
                  "Channels": 6,
                  "SampleRate": 48000,
                  "BitRate": 640000,
                  "Type": "Audio",
                  "Index": 1,
                  "IsDefault": true,
                  "IsExternal": false
                },
                {
                  "Codec": "subrip",
                  "Language": "chi",
                  "DisplayTitle": "Chinese Simplified (SRT)",
                  "DisplayLanguage": "Chinese (Simplified)",
                  "IsTextSubtitleStream": true,
                  "SupportsExternalStream": true,
                  "DeliveryMethod": "External",
                  "DeliveryUrl": "/Videos/0f8d0805a66f7ed429ecd8890146c7c3/0f8d0805a66f7ed429ecd8890146c7c3/Subtitles/2/0/Stream.srt",
                  "Type": "Subtitle",
                  "Index": 2,
                  "IsDefault": false,
                  "IsExternal": true
                }
              ],
              "Bitrate": 18432000,
              "DefaultAudioStreamIndex": 1,
              "DefaultSubtitleStreamIndex": -1,
              "DirectStreamUrl": "/videos/0f8d0805a66f7ed429ecd8890146c7c3/stream?Static=true&MediaSourceId=37bcb3827aeb2095f1b6293e9a189072&PlaySessionId=e643532a23ca4a60b2c70d4210c018a9&api_key=f3e2d1c0b9a87f6e5d4c3b2a1908f7e6",
              "ItemId": "0f8d0805a66f7ed429ecd8890146c7c3"
            }
          ]
        },
        {
          "Name": "Arrival",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "1a2b3c4d5e6f708192a3b4c5d6e7f809",
          "DateCreated": "2024-03-02T09:11:20.0000000Z",
          "PremiereDate": "2016-11-11T00:00:00.0000000Z",
          "ProductionYear": 2016,
          "OfficialRating": "PG-13",
          "CommunityRating": 7.9,
          "RunTimeTicks": 69600000000,
          "Overview": "A linguist is recruited by the military to assist in translating alien communications.",
          "Genres": ["Science Fiction", "Drama", "Mystery"],
          "PrimaryImageAspectRatio": 0.6666666666666666,
          "ImageTags": {
            "Primary": "aa11bb22cc33dd44ee55ff6677889900",
            "Logo": "bb22cc33dd44ee55ff6677889900aa11"
          },
          "BackdropImageTags": ["cc33dd44ee55ff6677889900aa11bb22"],
          "Type": "Movie",
          "MediaType": "Video",
          "IsFolder": false,
          "Container": "mp4",
          "SortName": "Arrival",
          "ParentId": "1f2e3d4c5b6a79880716253443526170",
          "UserData": {
            "PlaybackPositionTicks": 23400000000,
            "PlayCount": 0,
            "IsFavorite": false,
            "Played": false,
            "LastPlayedDate": "2026-10-18T21:03:11.0000000Z"
          },
          "MediaSources": [
            {
              "Protocol": "File",
              "Id": "aa11bb22cc33dd44ee55ff6677889900",
              "Path": "/mnt/media/Movies/Arrival (2016)/Arrival (2016) - 1080p.mp4",
              "Type": "Default",
              "Container": "mp4",
              "Size": 4294967296,
              "Name": "Arrival - 1080p",
              "IsRemote": false,
              "RunTimeTicks": 69600000000,
              "SupportsTranscoding": true,
              "SupportsDirectStream": true,
              "SupportsDirectPlay": true,
              "MediaStreams": [
                {
                  "Codec": "h264",
                  "Language": "eng",
                  "DisplayTitle": "1080p H264 SDR",
                  "IsInterlaced": false,
                  "BitRate": 4936000,
                  "Height": 1080,
                  "Width": 1920,
                  "VideoRange": "SDR",
                  "Profile": "High",
                  "Type": "Video",
                  "Index": 0,
                  "IsDefault": true
                },
                {
                  "Codec": "aac",
                  "Language": "eng",
                  "DisplayTitle": "English AAC stereo (Default)",
                  "ChannelLayout": "stereo",
                  "Channels": 2,
                  "SampleRate": 48000,
                  "BitRate": 192000,
                  "Type": "Audio",
                  "Index": 1,
                  "IsDefault": true
                }
              ],
              "Bitrate": 4936000,
              "DefaultAudioStreamIndex": 1,
              "DefaultSubtitleStreamIndex": -1,
              "ItemId": "1a2b3c4d5e6f708192a3b4c5d6e7f809"
            }
          ]
        },
        {
          "Name": "The Grand Budapest Hotel",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "2b3c4d5e6f708192a3b4c5d6e7f8091a",
          "DateCreated": "2023-12-24T18:45:02.0000000Z",
          "PremiereDate": "2014-03-28T00:00:00.0000000Z",
          "ProductionYear": 2014,
          "OfficialRating": "R",
          "CommunityRating": 8.1,
          "RunTimeTicks": 59400000000,
          "Overview": "A writer recounts the adventures of a legendary concierge at a famous European hotel.",
          "Genres": ["Comedy", "Drama", "Adventure"],
          "PrimaryImageAspectRatio": 0.68,
          "ImageTags": { "Primary": "dd44ee55ff6677889900aa11bb22cc33" },
          "BackdropImageTags": [],
          "Type": "Movie",
          "MediaType": "Video",
          "IsFolder": false,
          "Container": "mkv",
          "SortName": "Grand Budapest Hotel",
          "ParentId": "1f2e3d4c5b6a79880716253443526170",
          "UserData": {
            "PlaybackPositionTicks": 0,
            "PlayCount": 0,
            "IsFavorite": false,
            "Played": false
          }
        },
        {
          "Name": "Dune",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "3c4d5e6f708192a3b4c5d6e7f8091a2b",
          "DateCreated": "2024-06-18T07:30:00.0000000Z",
          "PremiereDate": "2021-10-22T00:00:00.0000000Z",
          "ProductionYear": 2021,
          "OfficialRating": "PG-13",
          "CommunityRating": 8.0,
          "RunTimeTicks": 93300000000,
          "Overview": "A noble family becomes embroiled in a war for control over the galaxy's most valuable asset.",
          "Genres": ["Science Fiction", "Adventure"],
          "PrimaryImageAspectRatio": 0.6666666666666666,
          "ImageTags": {
            "Primary": "ee55ff6677889900aa11bb22cc33dd44",
            "Logo": "ff6677889900aa11bb22cc33dd44ee55"
          },
          "BackdropImageTags": ["11223344556677889900aabbccddeeff"],
          "Type": "Movie",
          "MediaType": "Video",
          "IsFolder": false,
          "Container": "mkv",
          "SortName": "Dune",
          "ParentId": "1f2e3d4c5b6a79880716253443526170",
          "UserData": {
            "PlaybackPositionTicks": 0,
            "PlayCount": 1,
            "IsFavorite": true,
            "Played": true,
            "LastPlayedDate": "2026-08-12T19:22:05.0000000Z"
          }
        },
        {
          "Name": "Everything Everywhere All at Once",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "4d5e6f708192a3b4c5d6e7f8091a2b3c",
          "DateCreated": "2024-07-01T12:00:00.0000000Z",
          "PremiereDate": "2022-03-25T00:00:00.0000000Z",
          "ProductionYear": 2022,
          "OfficialRating": "R",
          "CommunityRating": 7.8,
          "RunTimeTicks": 83400000000,
          "Overview": "An exhausted Chinese American woman discovers she must connect with parallel universe versions of herself.",
          "Genres": ["Action", "Adventure", "Comedy"],
          "PrimaryImageAspectRatio": 0.6666666666666666,
          "ImageTags": { "Primary": "223344556677889900aabbccddeeff00" },
          "BackdropImageTags": [],
          "Type": "Movie",
          "MediaType": "Video",
          "IsFolder": false,
          "Container": "mkv",
          "SortName": "Everything Everywhere All at Once",
          "ParentId": "1f2e3d4c5b6a79880716253443526170",
          "UserData": {
            "PlaybackPositionTicks": 7800000000,
            "PlayCount": 0,
            "IsFavorite": false,
            "Played": false,
            "LastPlayedDate": "2026-10-20T22:44:00.0000000Z"
          }
        }
      ],
      "TotalRecordCount": 128
    }
    """

    /// `GET /Users/{userId}/Items?IncludeItemTypes=Episode` —— 剧集条目。
    static let itemsEpisodes = """
    {
      "Items": [
        {
          "Name": "Pilot",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "5e6f708192a3b4c5d6e7f8091a2b3c4d",
          "SeriesId": "6f708192a3b4c5d6e7f8091a2b3c4d5e",
          "SeriesName": "Severance",
          "SeasonId": "708192a3b4c5d6e7f8091a2b3c4d5e6f",
          "SeasonName": "Season 1",
          "IndexNumber": 1,
          "ParentIndexNumber": 1,
          "Type": "Episode",
          "MediaType": "Video",
          "IsFolder": false,
          "Container": "mkv",
          "RunTimeTicks": 34200000000,
          "PremiereDate": "2022-02-18T00:00:00.0000000Z",
          "Overview": "Mark leads a team of office workers whose memories have been surgically divided.",
          "PrimaryImageAspectRatio": 1.7777777777777777,
          "ImageTags": { "Primary": "3344556677889900aabbccddeeff0011" },
          "BackdropImageTags": [],
          "UserData": {
            "PlaybackPositionTicks": 0,
            "PlayCount": 1,
            "IsFavorite": false,
            "Played": true,
            "LastPlayedDate": "2026-10-01T20:00:00.0000000Z"
          }
        },
        {
          "Name": "Half Loop",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "607192a3b4c5d6e7f8091a2b3c4d5e6f",
          "SeriesId": "6f708192a3b4c5d6e7f8091a2b3c4d5e",
          "SeriesName": "Severance",
          "SeasonId": "708192a3b4c5d6e7f8091a2b3c4d5e6f",
          "SeasonName": "Season 1",
          "IndexNumber": 2,
          "ParentIndexNumber": 1,
          "Type": "Episode",
          "MediaType": "Video",
          "IsFolder": false,
          "Container": "mkv",
          "RunTimeTicks": 32400000000,
          "Overview": "Irving and Dylan try to make sense of what they have seen.",
          "PrimaryImageAspectRatio": 1.7777777777777777,
          "ImageTags": { "Primary": "44556677889900aabbccddeeff001122" },
          "BackdropImageTags": [],
          "UserData": {
            "PlaybackPositionTicks": 12500000000,
            "PlayCount": 0,
            "IsFavorite": false,
            "Played": false,
            "LastPlayedDate": "2026-10-19T22:31:07.0000000Z"
          }
        }
      ],
      "TotalRecordCount": 9
    }
    """

    /// `GET /Users/{userId}/Items/Resume` —— 继续观看。
    static let resume = """
    {
      "Items": [
        {
          "Name": "Half Loop",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "607192a3b4c5d6e7f8091a2b3c4d5e6f",
          "SeriesId": "6f708192a3b4c5d6e7f8091a2b3c4d5e",
          "SeriesName": "Severance",
          "SeasonId": "708192a3b4c5d6e7f8091a2b3c4d5e6f",
          "IndexNumber": 2,
          "ParentIndexNumber": 1,
          "Type": "Episode",
          "MediaType": "Video",
          "IsFolder": false,
          "RunTimeTicks": 32400000000,
          "PrimaryImageAspectRatio": 1.7777777777777777,
          "ImageTags": { "Primary": "44556677889900aabbccddeeff001122" },
          "BackdropImageTags": [],
          "UserData": {
            "PlaybackPositionTicks": 12500000000,
            "PlayCount": 0,
            "IsFavorite": false,
            "Played": false,
            "LastPlayedDate": "2026-10-19T22:31:07.0000000Z"
          }
        },
        {
          "Name": "Everything Everywhere All at Once",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "4d5e6f708192a3b4c5d6e7f8091a2b3c",
          "Type": "Movie",
          "MediaType": "Video",
          "IsFolder": false,
          "ProductionYear": 2022,
          "RunTimeTicks": 83400000000,
          "PrimaryImageAspectRatio": 0.6666666666666666,
          "ImageTags": { "Primary": "223344556677889900aabbccddeeff00" },
          "BackdropImageTags": [],
          "UserData": {
            "PlaybackPositionTicks": 7800000000,
            "PlayCount": 0,
            "IsFavorite": false,
            "Played": false,
            "LastPlayedDate": "2026-10-20T22:44:00.0000000Z"
          }
        }
      ],
      "TotalRecordCount": 2
    }
    """

    /// `GET /Shows/NextUp` —— 下一集。
    static let nextUp = """
    {
      "Items": [
        {
          "Name": "Half Loop",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "607192a3b4c5d6e7f8091a2b3c4d5e6f",
          "SeriesId": "6f708192a3b4c5d6e7f8091a2b3c4d5e",
          "SeriesName": "Severance",
          "SeasonId": "708192a3b4c5d6e7f8091a2b3c4d5e6f",
          "IndexNumber": 2,
          "ParentIndexNumber": 1,
          "Type": "Episode",
          "MediaType": "Video",
          "IsFolder": false,
          "RunTimeTicks": 32400000000,
          "Overview": "Irving and Dylan try to make sense of what they have seen.",
          "PrimaryImageAspectRatio": 1.7777777777777777,
          "ImageTags": { "Primary": "44556677889900aabbccddeeff001122" },
          "BackdropImageTags": [],
          "UserData": {
            "PlaybackPositionTicks": 0,
            "PlayCount": 0,
            "IsFavorite": false,
            "Played": false
          }
        }
      ],
      "TotalRecordCount": 1
    }
    """

    /// 空库（`Items: []`，`TotalRecordCount: 0`）。
    static let emptyLibrary = """
    {
      "Items": [],
      "TotalRecordCount": 0
    }
    """
}

// MARK: - 详情

public extension Fixtures {
    /// `GET /Users/{userId}/Items/{itemId}` —— 电影详情（含 `People` / `Studios` / `Taglines`）。
    static let itemDetailMovie = """
    {
      "Name": "Blade Runner 2049",
      "OriginalTitle": "Blade Runner 2049",
      "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
      "Id": "0f8d0805a66f7ed429ecd8890146c7c3",
      "Etag": "b7e2f4a1c9d30586ae41f2739b0c8d5e",
      "DateCreated": "2024-04-10T04:24:53.0000000Z",
      "PremiereDate": "2017-10-06T00:00:00.0000000Z",
      "ProductionYear": 2017,
      "OfficialRating": "R",
      "CommunityRating": 8.1,
      "CriticRating": 81,
      "RunTimeTicks": 97800000000,
      "Overview": "K, an officer with the LAPD, unearths a long-buried secret that has the potential to plunge what is left of society into chaos.",
      "Taglines": ["There is an order to things.", "The key to the future is finally unearthed."],
      "Genres": ["Science Fiction", "Drama", "Thriller"],
      "GenreItems": [
        { "Name": "Science Fiction", "Id": "0a1b2c3d4e5f60718293a4b5c6d7e8f9" },
        { "Name": "Drama", "Id": "1b2c3d4e5f60718293a4b5c6d7e8f90" }
      ],
      "Studios": [
        { "Name": "Alcon Entertainment", "Id": "2c3d4e5f60718293a4b5c6d7e8f9012" },
        { "Name": "Columbia Pictures", "Id": "3d4e5f60718293a4b5c6d7e8f90123" }
      ],
      "ProviderIds": {
        "Tmdb": "335984",
        "Imdb": "tt1856101"
      },
      "PrimaryImageAspectRatio": 0.6666666666666666,
      "ImageTags": {
        "Primary": "3a4b5c6d7e8f90a1b2c3d4e5f6071829",
        "Logo": "9f8e7d6c5b4a39281706f5e4d3c2b1a0",
        "Thumb": "1a2b3c4d5e6f708192a3b4c5d6e7f809"
      },
      "BackdropImageTags": [
        "4d5e6f708192a3b4c5d6e7f8091a2b3c",
        "5e6f708192a3b4c5d6e7f8091a2b3c4d"
      ],
      "Type": "Movie",
      "MediaType": "Video",
      "IsFolder": false,
      "Container": "mkv",
      "SortName": "Blade Runner 2049",
      "ParentId": "1f2e3d4c5b6a79880716253443526170",
      "People": [
        {
          "Name": "Ryan Gosling",
          "Id": "4e5f60718293a4b5c6d7e8f9012345ab",
          "Role": "K",
          "Type": "Actor",
          "PrimaryImageTag": "ab12cd34ef5678901234567890abcdef"
        },
        {
          "Name": "Harrison Ford",
          "Id": "5f60718293a4b5c6d7e8f9012345ab6c",
          "Role": "Rick Deckard",
          "Type": "Actor",
          "PrimaryImageTag": "cd34ef5678901234567890abcdefab12"
        },
        {
          "Name": "Ana de Armas",
          "Id": "60718293a4b5c6d7e8f9012345ab6c7d",
          "Role": "Joi",
          "Type": "Actor"
        },
        {
          "Name": "Denis Villeneuve",
          "Id": "718293a4b5c6d7e8f9012345ab6c7d8e",
          "Type": "Director"
        },
        {
          "Name": "Hampton Fancher",
          "Id": "8293a4b5c6d7e8f9012345ab6c7d8e9f",
          "Type": "Writer"
        }
      ],
      "UserData": {
        "PlaybackPositionTicks": 0,
        "PlayCount": 2,
        "IsFavorite": true,
        "Played": true,
        "LastPlayedDate": "2026-09-30T20:15:44.0000000Z"
      },
      "MediaSources": [
        {
          "Protocol": "File",
          "Id": "37bcb3827aeb2095f1b6293e9a189072",
          "Path": "/mnt/media/Movies/Blade Runner 2049 (2017)/Blade Runner 2049 (2017) - 2160p.mkv",
          "Type": "Default",
          "Container": "mkv",
          "Size": 22474836480,
          "Name": "Blade Runner 2049 - 2160p",
          "IsRemote": false,
          "RunTimeTicks": 97800000000,
          "SupportsTranscoding": true,
          "SupportsDirectStream": true,
          "SupportsDirectPlay": true,
          "Bitrate": 18432000,
          "DefaultAudioStreamIndex": 1,
          "DefaultSubtitleStreamIndex": -1,
          "MediaStreams": [
            {
              "Codec": "hevc",
              "Language": "eng",
              "DisplayTitle": "4K HEVC HDR",
              "IsInterlaced": false,
              "BitRate": 18432000,
              "Height": 2160,
              "Width": 3840,
              "VideoRange": "HDR",
              "Profile": "Main 10",
              "Type": "Video",
              "Index": 0,
              "IsDefault": true
            },
            {
              "Codec": "eac3",
              "Language": "eng",
              "DisplayTitle": "English Dolby Digital Plus 5.1 (Default)",
              "ChannelLayout": "5.1",
              "Channels": 6,
              "SampleRate": 48000,
              "BitRate": 640000,
              "Type": "Audio",
              "Index": 1,
              "IsDefault": true
            }
          ],
          "ItemId": "0f8d0805a66f7ed429ecd8890146c7c3"
        }
      ]
    }
    """

    /// `GET /Users/{userId}/Items/{itemId}` —— 剧集详情（`People` 里只有主创）。
    static let itemDetailSeries = """
    {
      "Name": "Severance",
      "OriginalTitle": "Severance",
      "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
      "Id": "6f708192a3b4c5d6e7f8091a2b3c4d5e",
      "DateCreated": "2024-05-02T10:00:00.0000000Z",
      "PremiereDate": "2022-02-18T00:00:00.0000000Z",
      "ProductionYear": 2022,
      "OfficialRating": "TV-MA",
      "CommunityRating": 8.7,
      "RunTimeTicks": 30600000000,
      "Overview": "Mark leads a team of office workers whose memories have been surgically divided between their work and personal lives.",
      "Taglines": ["Who are you at work?"],
      "Genres": ["Drama", "Mystery", "Science Fiction"],
      "Studios": [
        { "Name": "Red Hour Films", "Id": "9f8e7d6c5b4a39281706f5e4d3c2b1a0" }
      ],
      "ProviderIds": { "Tmdb": "95396", "Tvdb": "371980" },
      "Status": "Continuing",
      "AirDays": ["Friday"],
      "AirTime": "21:00",
      "ChildCount": 9,
      "RecursiveItemCount": 19,
      "SeasonCount": 2,
      "PrimaryImageAspectRatio": 0.6666666666666666,
      "ImageTags": {
        "Primary": "6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3",
        "Logo": "7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4",
        "Thumb": "8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5"
      },
      "BackdropImageTags": ["9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6"],
      "Type": "Series",
      "MediaType": "Video",
      "IsFolder": true,
      "SortName": "Severance",
      "ParentId": "2a3b4c5d6e7f80910a2b3c4d5e6f7081",
      "People": [
        {
          "Name": "Ben Stiller",
          "Id": "0e1f2a3b4c5d6e7f8091a2b3c4d5e6f7",
          "Type": "Director"
        },
        {
          "Name": "Dan Erickson",
          "Id": "1f2a3b4c5d6e7f8091a2b3c4d5e6f708",
          "Type": "Writer"
        },
        {
          "Name": "Adam Scott",
          "Id": "2a3b4c5d6e7f8091a2b3c4d5e6f70819",
          "Role": "Mark Scout",
          "Type": "Actor",
          "PrimaryImageTag": "ef5678901234567890abcdefab12cd34"
        }
      ],
      "UserData": {
        "PlaybackPositionTicks": 0,
        "PlayCount": 0,
        "IsFavorite": false,
        "Played": false,
        "UnplayedItemCount": 8
      }
    }
    """

    /// `GET /Shows/{seriesId}/Episodes` —— 一季的集列表。
    static let episodes = """
    {
      "Items": [
        {
          "Name": "Pilot",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "5e6f708192a3b4c5d6e7f8091a2b3c4d",
          "SeriesId": "6f708192a3b4c5d6e7f8091a2b3c4d5e",
          "SeriesName": "Severance",
          "SeasonId": "708192a3b4c5d6e7f8091a2b3c4d5e6f",
          "IndexNumber": 1,
          "ParentIndexNumber": 1,
          "Type": "Episode",
          "MediaType": "Video",
          "IsFolder": false,
          "RunTimeTicks": 34200000000,
          "Overview": "Mark leads a team of office workers whose memories have been surgically divided.",
          "ImageTags": { "Primary": "3344556677889900aabbccddeeff0011" },
          "BackdropImageTags": [],
          "UserData": { "PlaybackPositionTicks": 0, "PlayCount": 1, "IsFavorite": false, "Played": true }
        },
        {
          "Name": "Half Loop",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "607192a3b4c5d6e7f8091a2b3c4d5e6f",
          "SeriesId": "6f708192a3b4c5d6e7f8091a2b3c4d5e",
          "SeriesName": "Severance",
          "SeasonId": "708192a3b4c5d6e7f8091a2b3c4d5e6f",
          "IndexNumber": 2,
          "ParentIndexNumber": 1,
          "Type": "Episode",
          "MediaType": "Video",
          "IsFolder": false,
          "RunTimeTicks": 32400000000,
          "Overview": "Irving and Dylan try to make sense of what they have seen.",
          "ImageTags": { "Primary": "44556677889900aabbccddeeff001122" },
          "BackdropImageTags": [],
          "UserData": { "PlaybackPositionTicks": 12500000000, "PlayCount": 0, "IsFavorite": false, "Played": false }
        },
        {
          "Name": "In Perpetuity",
          "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
          "Id": "718293a4b5c6d7e8f9012345ab6c7d80",
          "SeriesId": "6f708192a3b4c5d6e7f8091a2b3c4d5e",
          "SeriesName": "Severance",
          "SeasonId": "708192a3b4c5d6e7f8091a2b3c4d5e6f",
          "IndexNumber": 3,
          "ParentIndexNumber": 1,
          "Type": "Episode",
          "MediaType": "Video",
          "IsFolder": false,
          "RunTimeTicks": 31800000000,
          "ImageTags": { "Primary": "556677889900aabbccddeeff00112233" },
          "BackdropImageTags": [],
          "UserData": { "PlaybackPositionTicks": 0, "PlayCount": 0, "IsFavorite": false, "Played": false }
        }
      ],
      "TotalRecordCount": 3
    }
    """
}

// MARK: - 播放协商

public extension Fixtures {
    /// `POST /Items/{itemId}/PlaybackInfo` —— 直连播放（`SupportsDirectPlay = true`）。
    static let playbackInfoDirectPlay = """
    {
      "MediaSources": [
        {
          "Protocol": "File",
          "Id": "37bcb3827aeb2095f1b6293e9a189072",
          "Path": "/mnt/media/Movies/Blade Runner 2049 (2017)/Blade Runner 2049 (2017) - 2160p.mkv",
          "Type": "Default",
          "Container": "mkv",
          "Size": 22474836480,
          "Name": "Blade Runner 2049 - 2160p",
          "IsRemote": false,
          "RunTimeTicks": 97800000000,
          "SupportsTranscoding": true,
          "SupportsDirectStream": true,
          "SupportsDirectPlay": true,
          "Bitrate": 18432000,
          "DefaultAudioStreamIndex": 1,
          "DefaultSubtitleStreamIndex": -1,
          "DirectStreamUrl": "/videos/0f8d0805a66f7ed429ecd8890146c7c3/stream?Static=true&MediaSourceId=37bcb3827aeb2095f1b6293e9a189072&PlaySessionId=e643532a23ca4a60b2c70d4210c018a9&DeviceId=3c1b2a49-7f8e-4d5c-9a0b-1c2d3e4f5061&api_key=f3e2d1c0b9a87f6e5d4c3b2a1908f7e6",
          "MediaStreams": [
            {
              "Codec": "hevc",
              "Language": "eng",
              "DisplayTitle": "4K HEVC HDR",
              "IsInterlaced": false,
              "BitRate": 18432000,
              "Height": 2160,
              "Width": 3840,
              "VideoRange": "HDR",
              "Profile": "Main 10",
              "Type": "Video",
              "Index": 0,
              "IsDefault": true,
              "IsExternal": false
            },
            {
              "Codec": "eac3",
              "Language": "eng",
              "DisplayTitle": "English Dolby Digital Plus 5.1 (Default)",
              "ChannelLayout": "5.1",
              "Channels": 6,
              "SampleRate": 48000,
              "BitRate": 640000,
              "Type": "Audio",
              "Index": 1,
              "IsDefault": true,
              "IsExternal": false
            },
            {
              "Codec": "subrip",
              "Language": "chi",
              "DisplayTitle": "Chinese Simplified (SRT)",
              "IsTextSubtitleStream": true,
              "SupportsExternalStream": true,
              "DeliveryMethod": "External",
              "DeliveryUrl": "/Videos/0f8d0805a66f7ed429ecd8890146c7c3/0f8d0805a66f7ed429ecd8890146c7c3/Subtitles/2/0/Stream.srt",
              "Type": "Subtitle",
              "Index": 2,
              "IsDefault": false,
              "IsExternal": true
            }
          ],
          "ItemId": "0f8d0805a66f7ed429ecd8890146c7c3"
        }
      ],
      "PlaySessionId": "e643532a23ca4a60b2c70d4210c018a9"
    }
    """

    /// `POST /Items/{itemId}/PlaybackInfo` —— 需要转码。
    ///
    /// 刻意保留「`SupportsDirectStream: false` 但仍有 `DirectStreamUrl`」这一真实特征，
    /// 用来固化「不能靠 `DirectStreamUrl` 是否存在判断直封」这条结论。
    static let playbackInfoTranscode = """
    {
      "MediaSources": [
        {
          "Protocol": "File",
          "Id": "aa11bb22cc33dd44ee55ff6677889900",
          "Path": "/mnt/media/Movies/Arrival (2016)/Arrival (2016) - 1080p.mp4",
          "Type": "Default",
          "Container": "mp4",
          "Size": 4294967296,
          "Name": "Arrival - 1080p",
          "IsRemote": false,
          "RunTimeTicks": 69600000000,
          "SupportsTranscoding": true,
          "SupportsDirectStream": false,
          "SupportsDirectPlay": false,
          "Bitrate": 4936000,
          "DefaultAudioStreamIndex": 1,
          "DefaultSubtitleStreamIndex": -1,
          "DirectStreamUrl": "/videos/1a2b3c4d5e6f708192a3b4c5d6e7f809/master.m3u8?DeviceId=3c1b2a49-7f8e-4d5c-9a0b-1c2d3e4f5061&MediaSourceId=aa11bb22cc33dd44ee55ff6677889900&PlaySessionId=7c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f&api_key=f3e2d1c0b9a87f6e5d4c3b2a1908f7e6&VideoCodec=h264&VideoBitrate=4936000&AudioCodec=aac&TranscodeReasons=VideoCodecNotSupported",
          "TranscodingUrl": "/videos/1a2b3c4d5e6f708192a3b4c5d6e7f809/master.m3u8?DeviceId=3c1b2a49-7f8e-4d5c-9a0b-1c2d3e4f5061&MediaSourceId=aa11bb22cc33dd44ee55ff6677889900&PlaySessionId=7c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f&api_key=f3e2d1c0b9a87f6e5d4c3b2a1908f7e6&VideoCodec=h264&VideoBitrate=4936000&AudioCodec=aac&TranscodeReasons=VideoCodecNotSupported",
          "TranscodingSubProtocol": "hls",
          "TranscodingContainer": "ts",
          "MediaStreams": [
            {
              "Codec": "vc1",
              "Language": "eng",
              "DisplayTitle": "1080p VC-1",
              "IsInterlaced": false,
              "BitRate": 4936000,
              "Height": 1080,
              "Width": 1920,
              "VideoRange": "SDR",
              "Type": "Video",
              "Index": 0,
              "IsDefault": true
            },
            {
              "Codec": "dts",
              "Language": "eng",
              "DisplayTitle": "English DTS 5.1 (Default)",
              "ChannelLayout": "5.1",
              "Channels": 6,
              "SampleRate": 48000,
              "BitRate": 1536000,
              "Type": "Audio",
              "Index": 1,
              "IsDefault": true
            }
          ],
          "ItemId": "1a2b3c4d5e6f708192a3b4c5d6e7f809"
        }
      ],
      "PlaySessionId": "7c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f"
    }
    """
}

// MARK: - 容错样例

public extension Fixtures {
    /// 最小 `BaseItemDto`：只有 `Id` / `Name` / `Type`，其余全缺。
    static let minimalItem = """
    {
      "Id": "0f8d0805a66f7ed429ecd8890146c7c3",
      "Name": "Minimal",
      "Type": "Movie"
    }
    """

    /// 未知枚举值 + 缺失 `UserData` + 缺 `ImageTags`。
    static let itemWithUnknownEnums = """
    {
      "Id": "1a2b3c4d5e6f708192a3b4c5d6e7f809",
      "Name": "Weird Item",
      "Type": "HolographicNovel",
      "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617",
      "ProductionYear": "2024",
      "RunTimeTicks": "7200000000",
      "Genres": null,
      "ImageTags": { "Primary": "", "CustomArt": "abc123" },
      "BackdropImageTags": null,
      "MediaSources": [
        {
          "Id": "ms-1",
          "MediaStreams": [
            { "Index": 0, "Type": "Brainwave", "Codec": "neural" }
          ]
        }
      ]
    }
    """

    /// 播放协商返回错误码（`ErrorCode`）。
    static let playbackInfoNotAllowed = """
    {
      "MediaSources": [],
      "PlaySessionId": null,
      "ErrorCode": "NotAllowed"
    }
    """

    /// 最小 `QueryResult`（只有 `Items`，没有 `TotalRecordCount`）。
    static let queryResultWithoutTotal = """
    {
      "Items": [
        { "Id": "0f8d0805a66f7ed429ecd8890146c7c3", "Name": "One", "Type": "Movie" }
      ]
    }
    """

    /// 登录响应的最小形态（只有 `AccessToken` 与 `User` 的必需字段）。
    static let authenticateMinimal = """
    {
      "User": {
        "Id": "8a1f0b2c3d4e5f60718293a4b5c6d7e8",
        "Name": "alice",
        "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617"
      },
      "AccessToken": "f3e2d1c0b9a87f6e5d4c3b2a1908f7e6",
      "ServerId": "6f1a2c3d4e5b6789a0b1c2d3e4f50617"
    }
    """
}
