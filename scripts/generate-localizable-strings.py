#!/usr/bin/env python3
"""从 .xcstrings 生成 App 级的 Localizable.strings（中文原文作 key）。

## 为什么用中文原文作 key，而不是语义 key

`Text("继续观看")` 里的字符串字面量在 SwiftUI 里是 `LocalizedStringKey`，
渲染时会在 **`Bundle.main`** 里查表。所以只要 App 的 lproj 里有一张
`"继续观看" = "Continue watching"` 的表，英文用户就能看到英文——
**一行代码都不用改**。

对比「语义 key」方案（`Text("home.continueWatching")`）：
- 需要改 360 处 / 33 个文件，每处都可能改错
- 改错的表现是**用户看到裸 key**（`home.continueWatching`），很难看
- 而本方案漏改的表现是**继续显示中文**——优雅降级

代价：同一中文在不同语境下只能有一个英文译文（见 CONFLICT_OVERRIDES）。
中文文案改动会使对应译文失效（需重新生成）。

## 输出
- `App/en.lproj/Localizable.strings`
- `App/zh-Hans.lproj/Localizable.strings`（key = value，等价于不翻译）

用法：`python3 scripts/generate-localizable-strings.py`
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOGS = [
    ROOT / "Sources/PrismUI/Resources/Localizable.xcstrings",
    ROOT / "Sources/PrismCore/Resources/Localizable.xcstrings",
]

# 同一中文有多种英文时，人工指定取哪一个（其余丢弃）。
# 选择依据：优先选界面上最常见的用法（单数/短形式）。
CONFLICT_OVERRIDES = {
    "播放": "Play",
    "继续观看": "Continue watching",
    "收藏": "Favorite",
    "剧集": "TV Shows",
    "下一集": "Next Episode",
    "媒体库": "Media Libraries",
    "电影": "Movies",
    "单集": "Episode",
    "人物": "People",
    "服务器": "Server",
}


def collect() -> dict[str, set[str]]:
    """返回 {中文: {英文...}}。"""
    table: dict[str, set[str]] = {}
    for path in CATALOGS:
        if not path.exists():
            print(f"warning: 找不到 {path}", file=sys.stderr)
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        for _key, entry in data.get("strings", {}).items():
            locs = entry.get("localizations", {})
            zh = locs.get("zh-Hans", {}).get("stringUnit", {}).get("value")
            en = locs.get("en", {}).get("stringUnit", {}).get("value")
            if zh and en:
                table.setdefault(zh, set()).add(en)
    return table


def escape(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )


def write_lproj(table: dict[str, set[str]]) -> None:
    en_lines = []
    zh_lines = []
    conflicts = []
    for zh in sorted(table):
        candidates = table[zh]
        if len(candidates) > 1:
            en = CONFLICT_OVERRIDES.get(zh)
            if en is None:
                conflicts.append((zh, sorted(candidates)))
                en = sorted(candidates)[0]
        else:
            en = next(iter(candidates))
        en_lines.append(f'"{escape(zh)}" = "{escape(en)}";')
        # 中文表：key 与 value 相同（等价于不翻译，但保证 lproj 存在且完整）
        zh_lines.append(f'"{escape(zh)}" = "{escape(zh)}";')

    if conflicts:
        print("warning: 以下中文有多种英文且未在 CONFLICT_OVERRIDES 中指定，取字典序第一个：")
        for zh, ens in conflicts:
            print(f"  {zh!r}: {ens}")

    for lang, lines in (("en", en_lines), ("zh-Hans", zh_lines)):
        out = ROOT / f"App/{lang}.lproj/Localizable.strings"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"{out.relative_to(ROOT)}: {len(lines)} 条")


if __name__ == "__main__":
    table = collect()
    print(f"收集到 {len(table)} 个唯一中文串")
    write_lproj(table)
