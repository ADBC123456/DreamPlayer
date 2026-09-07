# 私人影视库实施索引

更新时间：2026-09-07

## 当前进度

| 模块 | 状态 | 代码入口 |
|---|---|---|
| 统一作品、剧集、文件索引 | 已实现首版 | `lib/library/models/library_models.dart`、`lib/library/unified_library_service.dart` |
| 来源目录扫描与 TMDB 聚合 | 已实现首版 | `lib/library/library_scanner.dart`、`lib/library/metadata_resolver.dart` |
| 首页海报库、最近观看按作品去重 | 已实现 | `lib/screens/home_screen.dart` |
| 资源库保存服务器快捷入口 | 已实现 | `lib/screens/library_screen.dart`、各来源 Screen 的 `initialServerId` 入口 |
| 聚合详情页、季集卡片与版本播放 | 已实现首版 | `lib/screens/unified_title_details_screen.dart` |
| 弹幕人工绑定、整季绑定与按需缓存 | 已实现 | `lib/danmaku/binding/danmaku_binding_store.dart`、`lib/danmaku/scraper/series_scraper.dart` |
| 预告弹幕冲突过滤 | 已实现并完成 Android 真机复验 | 见下方“预告过滤索引” |
| 详情页弹幕匹配直达流程 | 已实现并完成 Android 真机复验 | `lib/screens/danmaku_scrape_screen.dart` |

## 预告过滤索引

2026-09-07 使用手机当前配置的 danmu_api 查询“凡人修仙传”：返回 7 个系列候选，其中检测到 107 个标题含预告标记的哔哩哔哩条目，典型标题为 `【bilibili1】 星海飞驰第1集预告`。旧逻辑会读取其中的“第1集”，使它与正片第 1 集形成重复候选。

处理位置：

- `lib/danmaku/model/episode_title_classifier.dart`：统一识别预告、先导、PV、Trailer、Teaser、Preview、宣传片、特报、片花、抢先看、花絮及制作特辑。
- `lib/danmaku/scraper/episode_mapper.dart`：宣传内容的集号固定视为 0，不进入正片集号索引。
- `lib/danmaku/source/danmu_api_source.dart`：`/match` 自动结果先排除宣传内容，再进行唯一性检查。
- `lib/danmaku/service/danmaku_service.dart`：TMDB 元数据回退匹配排除宣传内容，并清除旧版自动保存的预告绑定。
- `lib/danmaku/scraper/series_scraper.dart`：恢复整季任务时清除旧版自动预告绑定。
- `lib/danmaku/repository/danmaku_cache.dart`：缓存 schema 升级到 v2，使旧版可能缓存的预告弹幕失效并按需重新获取。
- `lib/screens/danmaku_scrape_screen.dart`：系列集数和手动集列表隐藏宣传条目；详情页进入后自动打开系列选择，选中系列后按当前集优先排列。
- `lib/screens/unified_title_details_screen.dart`：季入口使用当前续播集作为远程集列表定位点；单集入口使用被点击的集号。
- `lib/screens/tmd_details_screen.dart`：旧详情入口同样直接打开系列选择。

## 回归测试索引

- `test/danmaku_episode_mapper_test.dart`：预告标题解析、同集正片/预告去冲突、仅有预告时不自动绑定。
- `test/danmu_api_source_http_test.dart`：`/match` 返回预告在前、正片在后时选择正片；仅返回预告时返回无匹配。
- `test/danmaku_binding_store_test.dart`：旧自动绑定的定点删除能力。
- `test/danmaku_scrape_screen_test.dart`：整季弹幕页面的扫描、缓存入口和无来源状态回归。

## 验证记录

- 自动测试：完整 `flutter test` 共 465 项通过；`flutter analyze` 无问题。
- 构建安装：Android Debug APK 构建成功，并安装到 PJD110 / CPH2573（Android 16）。
- 真机复验：打开“凡人修仙传”详情页点击“匹配当前季弹幕”，直接显示系列选择；哔哩哔哩系列过滤后显示 190 集；点开后首项为当前续播第 119 集，随后按距离显示 120、118、121，未出现预告条目。
- 尚未改动用户数据：真机验证停在远程集选择页，没有确认整季绑定。

## 最近提交索引

| 提交 | 内容 |
|---|---|
| `1e01940` | 资源库显示已保存来源服务器快捷入口 |
| `a29a991` | 首页布局调整、最近观看按作品聚合、四列海报 |
| `4edfe12` | 播放前确认绑定弹幕已缓存 |
| `1580bcc` | 弹幕绑定与弹幕缓存分离 |
| `705cf35` | 手动选择弹幕系列和具体剧集 |
| `ec563ac` | 文件名解析支持四位集号 |
| `eea5f74` | 移除待整理入口 |
| `cac2740` | 弹幕动画重绘性能优化 |
| `46ab1a2` | 统一影视库、聚合详情页与弹幕上下文首版 |
