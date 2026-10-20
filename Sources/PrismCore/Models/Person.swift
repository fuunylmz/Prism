import Foundation

/// 演职员 / 人物，对应 Emby `BaseItemPerson`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Dto.BaseItemPerson.html>
/// —— `Name`、`Id`、`Role`、`Type`、`PrimaryImageTag`。
///
/// 说明：`People` 字段只在**详情接口**返回（列表接口不返回），
/// 因此 `MediaItem.people` 是 `nil` 表示“没有请求该字段”，`[]` 表示“确实没有演职员”。
public struct Person: Sendable, Codable, Hashable, Identifiable {
    /// 人物 id（Emby 的 guid 字符串）。
    public let id: String
    /// 姓名。
    public let name: String
    /// 饰演的角色名（演员类为角色，导演类可能为空）。
    public let role: String?
    /// 人物类型（`Actor`、`Director`、`Writer`、`Producer`…）。
    public let type: String?
    /// 头像的 image tag。
    public let primaryImageTag: String?

    /// 完整初始化。
    public init(
        id: String,
        name: String,
        role: String? = nil,
        type: String? = nil,
        primaryImageTag: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.type = type
        self.primaryImageTag = primaryImageTag
    }

    /// 展示文案：`"角色 · 姓名"`，没有角色时只有姓名。
    public var displayName: String {
        if let role, !role.isEmpty { return "\(role) · \(name)" }
        return name
    }

    /// 是否有可用的头像。
    public var hasImage: Bool {
        primaryImageTag?.isEmpty == false
    }

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }

    /// 宽松解码：`Id` 缺失时用姓名兜底（保证 `Identifiable` 可用），姓名缺失退化为空串。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = container.decodeFlexibleString(forKey: .name) ?? ""
        let id = container.decodeFlexibleString(forKey: .id) ?? ""
        self.name = name
        self.id = id.isEmpty ? name : id
        self.role = try? container.decodeIfPresent(String.self, forKey: .role)
        self.type = try? container.decodeIfPresent(String.self, forKey: .type)
        self.primaryImageTag = try? container.decodeIfPresent(String.self, forKey: .primaryImageTag)
    }

    /// 按 Emby 的 PascalCase 字段名编码。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(primaryImageTag, forKey: .primaryImageTag)
    }
}
