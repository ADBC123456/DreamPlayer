# 私人影视库聚合、季集详情与弹幕联动 PRD

## 1. 目标与范围

将当前“收藏文件夹显示封面”的首页升级为私人影视库，参照用户提供的网易爆米花截图，实现：

**添加来源目录 → 自动识别 → 聚合海报 → 查看实际拥有的季集 → 选择版本在线播放 → 使用刮削信息匹配弹幕。**

已确认的产品决策：

- 聚合海报库作为首页，原文件浏览保留为“来源”入口。
- 接入现有本地、WebDAV、SMB、FTP/SFTP、Jellyfin/Emby、UPnP 能力，遵循各平台已有支持范围。
- 同剧跨来源只显示一张海报，同集多个文件作为版本保留。
- 多版本首次选择，按剧记住来源偏好。
- 默认按 TMDB 季集组织，允许逐集校正和整季集号偏移。
- 播放自动匹配本集弹幕，详情页支持手动匹配整季。
- 保留 Android Media3/MPV 与 iOS AetherEngine。

不包含网盘直接登录、视频下载、跨设备同步，也不根据一张截图推定其他网易爆米花功能。

相关历史任务：

- `09-05-zh-en-localization-metadata-reliability`
- `09-04-danmaku-source-series-scrape`

本任务补充跨来源影片索引，不覆盖已有本地化、来源鉴权、弹幕渲染及缓存规范。

## 2. 当前问题与修复原则

| 当前实现 | 问题 | 修改方向 |
|---|---|---|
| 首页直接展示收藏文件夹 | 混合目录无法按影片分出海报 | 首页消费影片索引 |
| 按收藏目录名称搜索 TMDB | “动漫”“电影”等根目录可能被当作片名 | 先发现文件，再结合所在目录识别 |
| 网络海报点击进入文件浏览器 | 无统一季集页面 | 海报统一进入影片详情 |
| `FolderCard` 自行读取目录统计 | 请求重复，部分网络来源走错服务 | 统计由索引提供 |
| TMDB 匹配存在但海报为空 | 无法回退 Jellyfin 图片 | 按图片实际可用性回退 |
| 全局最近一次预取列表 | 不同目录任务上下文可能串用 | 每个识别任务携带独立上下文 |
| 元数据整体读取再写回 | 并发更新存在覆盖风险 | 写入串行化，结果按最新状态合并 |
| 季缓存拒绝第 0 季 | 特别篇无法加载 | 区分第 0 季和未知季号 |
| 弹幕自动匹配只有文件身份 | 正式剧名未参与播放匹配 | 传递独立的刮削身份上下文 |

工作区现有修改必须保留，不批量回滚、不覆盖此前本地化和弹幕实现。

## 3. 数据模型与接口

### 3.1 三层身份

严格区分作品、剧集和文件：

```dart
MediaTitle {
  id;                   // tmdb:<movie|tv>:<id>
  kind;
  tmdbId;
  displayTitle;
  originalTitle;
  year;
  poster;
  backdrop;
  overview;
  rating;
  metadataState;
}

LibraryEpisode {
  id;                   // <titleId>:s<season>:e<episode>
  titleId;
  seasonNumber;         // 0 = 特别篇；null = 未确定
  episodeNumber;
  displayName;
  still;
  runtime;
}

MediaFile {
  id;                   // 来源限定的稳定文件身份
  rootIds;              // 同一文件可属于多个重叠收藏根
  sourceRef;            // 服务器 ID、路径或 itemId
  originalFileName;
  sizeBytes;
  modifiedAt;
  titleId;
  episodeId;
  matchOrigin;          // 自动识别、服务端、人工
  availability;
  legacyResumeKey;      // 保留原播放器身份
}
```

未识别文件以稳定文件 ID 保存，不创建猜测性的跨来源作品合并关系。电影通过 `titleId` 关联多个版本，不创建虚假的“第 1 集”。

补充状态：

```dart
LibraryOverride {
  fileId;
  pinnedTitleId;
  seasonNumber;
  episodeNumber;
}

TitlePlaybackPreference {
  titleId;
  preferredSourceId;
  lastPlayedFileId;
  lastPlayedEpisodeId;
  lastPlayedAt;
}

MetadataContext {
  titleId;
  displayTitle;
  originalTitle;
  seasonNumber;
  episodeNumber;
  episodeTitle;
  revision;
}
```

影片匹配修订号用于阻止过期请求写回；不替换原文件续播键，也不把 TMDB ID 当作弹幕服务的剧集 ID。

### 3.2 服务边界

```dart
abstract interface class LibrarySourceAdapter {
  Future<ListingPage> list(
    SourceDirectory directory, {
    String? cursor,
  });

  Future<VideoItem> resolvePlayable(MediaFile file);
}

abstract interface class LibraryRepository {
  Stream<LibrarySnapshot> watch();
  Future<void> applyScanBatch(ScanBatch batch);
  Future<void> applyOverrides(List<LibraryOverride> overrides);
  Future<SearchResult> search(LibraryQuery query);
}

abstract interface class LibraryScanner {
  Future<void> refreshRoots(List<LibraryRoot> roots);
  void cancel(String scanId);
}

abstract interface class MetadataResolver {
  Future<MatchResult> resolve(
    MediaFile file,
    DiscoveryContext context,
  );
}
```

枚举负责发现稳定引用；播放解析负责获取当前鉴权、URL 和字幕。不能把仅用于弹幕枚举的不完整 `VideoItem` 直接交给播放器。

## 4. 扫描、识别和存储

### 4.1 扫描规则

- 用户添加目录后自动递归扫描。
- 启动先读取缓存，后台刷新距上次成功扫描超过 30 分钟的根目录。
- 同时最多扫描两个来源，同一来源顺序执行目录请求。
- 不限制为两层目录；使用来源限定的规范化目录身份去重，避免循环。
- 必须处理来源分页。
- 支持取消、进度显示、单来源失败重试。
- 每累计 100 个文件或经过 1 秒提交一次发现批次。
- 认证失败、超时、取消均不等价于空目录。
- 只有整个根目录成功扫描后，才能将未再发现的旧文件标记为缺失。
- 一个来源失败不阻塞其他来源。

```text
refreshRoot(root):
    generation = beginScan(root)
    queue = [root.directory]
    visited = set()
    seenFiles = set()

    while queue not empty:
        checkCancelled(generation)
        directory = queue.popFront()

        if canonicalIdentity(directory) in visited:
            continue
        visited.add(canonicalIdentity(directory))

        for each page from adapter.listAllPages(directory):
            checkCancelled(generation)

            for entry in page.entries:
                if entry.isDirectory:
                    queue.push(entry.directory)
                else if isSupportedVideo(entry):
                    file = makeStableFileReference(entry, root)
                    seenFiles.add(file.id)
                    stageDiscoveredFile(file)
                    scheduleIdentification(file, directory.context)

            flushBatchWhenDue()

    flushRemainingBatch()
    markMissingOnlyWithinCompletedRoot(root, seenFiles)
    finishScan(root, generation)
```

识别请求独立于目录遍历，不因 TMDB 暂时不可用而丢失已发现文件。缺失记录保留原身份和播放历史；其他来源仍存在同集时继续可播。

### 4.2 影片识别

识别优先级：

1. 已保存的人工绑定。
2. Jellyfin/Emby 返回的有效 TMDB 身份及季集信息。
3. 文件名中的明确片名、年份、季集。
4. 最近的有效剧名目录与季目录上下文。
5. 无足够依据时进入待整理。

不能把混合根目录的匹配结果传播给所有子文件。纯数字文件只有在已确认剧集目录中才按集号解析。

复用现有 TMDB 标题评分与原名匹配。自动绑定要求：

- 最佳候选得分至少 0.8；
- 存在第二候选时，领先至少 0.1；
- 与明确媒体类型、年份或已有人工信息冲突时，进入待确认。

阈值定义为命名常量，并通过真实文件名样本回归测试。按规范化查询、类型、年份和语言共享请求；元数据请求并发为 2，请求开始间隔至少 300 毫秒，沿用已有有限重试。

```text
identify(file, context):
    if overrideExists(file.id):
        return applyOverride(file)

    if validServerIdentityExists(file):
        return matchFromServer(file)

    parsed = parse(file.originalName, context)
    candidates = searchShared(parsed)

    if confidentAndUnambiguous(candidates, parsed):
        return matched(bestCandidate, parsed.seasonEpisode)

    return needsReview(candidates)
```

无网络、未配置密钥、无匹配、候选歧义分别保存状态。信息不足的文件仍可以直接播放。

### 4.3 存储与一致性

- 索引保存在应用私有目录，使用带 `schemaVersion` 的分片 JSON。
- 所有提交通过单一写队列；临时文件、备份与替换机制保证中断后可恢复。
- 启动遇到损坏分片时恢复备份；无法恢复则提示重扫该来源，不清空全部媒体库。
- 原 `TmdStore` 的写入同样串行化；详情与季集响应合并到最新缓存，不使用请求开始时的完整旧快照覆盖。
- 相同详情请求共享 Future，后来的调用者等待结果。
- 人工更正增加修订号；旧版本请求返回后丢弃。
- 保存元数据语言，切换语言刷新显示字段，作品和文件身份不变。
- 首次迁移已有收藏根、可复用元数据和续播引用；不删除旧偏好数据。
- 扫描不下载视频，也不逐个读取远程视频做哈希。

## 5. UX 与页面流程

### 5.1 首页

布局顺序：

1. “影视库”标题、搜索、添加来源。
2. 继续观看。
3. 全部／电影／电视剧／待整理。
4. 来源筛选、排序。
5. 自适应海报网格。

默认按最近入库排序。搜索对已索引正式片名、原名、集名和文件名执行不区分大小写的包含匹配，输入防抖 250 毫秒。

搜索结果：

- 作品匹配显示一张海报。
- 集名或文件名命中时显示对应集数提示。
- 点击集数命中结果进入详情并定位该集。
- 离线仍能搜索缓存，页面提示来源当前不可达。

扫描进度使用轻量状态条：“正在扫描 · 已发现 328 个文件”。可查看各来源任务、取消或重试，不弹出阻断全屏的等待框。

空库显示“添加来源目录”；待整理显示原文件名及来源，不伪造海报。

### 5.2 影片详情

宽屏布局参考截图：

- 全宽背景图及底部暗色渐变。
- 左上返回，右上更多操作。
- 标题、主播放按钮、评分、年份、类型。
- “共 X 集 · 库中 Y 集”。
- 简介默认三行，点击展开。
- 季选择与横向剧集卡片。

主按钮规则：

- 存在未完成观看记录：`继续播放 第 93 集 · 17:09`。
- 没有续播记录：播放第一集未看且可用的正片。
- 全部已看：显示“重新播放”，从第一集开始。
- 没有可播放文件：禁用播放，并展示来源或整理原因。

总集数只来自有效元数据；不知道时只显示库中数量。Y 对季集去重，多个版本只算一集。

每张剧集卡显示：

- 16:9 剧照；
- 集号与正式集名；
- 已知时长、进度条或已看标记；
- 多版本时显示“2 个版本”。

卡片点击播放；更多操作提供版本选择、已看切换、季集校正和本集弹幕匹配。触控目标至少 48 逻辑像素，不能依赖长按才能发现关键功能。

手机宽度不足 600 时采用上下排列；较宽屏幕播放按钮与资料并排。支持大字体与遥控器焦点，不使用硬编码高度截断文字。

### 5.3 版本选择

多版本首次点击打开底部面板：

```text
第 12 集 · 选择播放版本

○ WebDAV · 家庭网盘
  原文件名 · 4K（文件名标记）· 3.2 GB

○ Jellyfin · 客厅服务器
  原文件名 · 1080p · 1.1 GB

☑ 此剧优先使用该来源

[播放]
```

- 来源状态仅在有检查依据时展示，不将未知状态标成可用。
- 没有实际探测的画质应标注来自文件名。
- 只有一个版本直接播放。
- 偏好来源只有一个可用候选时直接播放。
- 偏好失效或有多个候选时重新选择。
- 播放失败提供“重试”和“选择其他版本”，不无限循环换源。

不同版本可能存在片头、剪辑差异，因此不自动套用其他文件的播放时间点。

### 5.4 整理与纠错

“更正识别”展示当前匹配、搜索框和候选海报。

季集校正支持：

- 单文件指定作品、季号、集号。
- 选中文件批量指定季号。
- 整季集号偏移，例如“原第 53 集 → 第 2 季第 1 集”。

提交前展示前后映射及冲突。负集号、无效季号禁止提交；映射到同一集时明确提示将形成多版本，需要确认后保存。

取消不修改数据；保存后重建受影响的聚合，提供撤销本次校正。重新扫描不得覆盖人工结果。

## 6. 播放与弹幕联动

### 6.1 播放

```text
playEpisode(episode):
    version = selectUsingTitlePreference(episode.files)
    if version is null:
        return

    video = await sourceAdapter.resolvePlayable(version)
    video.metadataContext = contextFromLibrary(episode)

    openExistingPlayer(
        video,
        selectedEngine,
        logicalEpisodeQueue
    )
```

来源解析必须恢复现有鉴权、字幕和稳定续播身份。播放主流程不等待弹幕匹配。

下一集使用当前季已入库、去重后的正片顺序，遵循现有自动播放开关。每次切集重新解析播放地址，不预存整季临时链接。

### 6.2 弹幕匹配

扩展现有服务接口，保持旧调用兼容：

```dart
ensureForVideo(
  VideoIdentity identity, {
  MetadataContext? metadata,
  bool forceRefresh = false,
});
```

匹配顺序：

1. 人工确认的弹幕绑定。
2. 当前文件及当前弹幕源的有效缓存。
3. 刮削剧名查询目录，按季号、集号和集名寻找唯一候选。
4. 正式名无结果时尝试原名。
5. 文件名、大小与可用哈希辅助匹配。
6. 仍有歧义则展示候选，不默认选择第一项。

TMDB 身份与弹幕身份保持独立。校正信息优先于再次解析原文件名。

详情页提供：

- 匹配本集；
- 匹配当前季；
- 查看匹配结果；
- 手动更正；
- 重试失败项。

整季匹配直接接收当前季的索引文件列表及明确季集上下文，不再次从收藏根扫描。不同版本保留各自缓存，不能默认共用时间偏移。

未启用弹幕时不自动请求；手动点击匹配但没有配置源时引导到设置。

```text
loadDanmaku(file, metadata):
    generation = currentPlaybackGeneration

    outcome = await service.ensureForVideo(
        originalFileIdentity(file),
        metadata: metadata
    )

    if generation != currentPlaybackGeneration:
        discard(outcome)
        return

    showOutcomeWithoutInterruptingPlayback(outcome)
```

沿用现有每源隔离、有限重试、取消、时间偏移仅应用一次和播放器时钟驱动原则。

## 7. 分阶段实施

### 阶段一：修复基础刮削可靠性

- 修复封面空值及图片失败回退。
- 修复元数据持久化并发与旧请求覆盖。
- 将全局预取列表改为任务上下文。
- 支持第 0 季及明确的元数据失败状态。
- 增加针对上述问题的回归测试。

完成标准：并发加载、人工更正、重启和图片失败不导致错误封面或数据丢失。

### 阶段二：建立统一索引

- 添加三层数据模型、仓库、扫描协调器。
- 为各现有来源实现枚举与播放解析适配器。
- 实现递归、分页、批次提交、取消、失败隔离和迁移。
- 实现识别结果、人工绑定和跨来源聚合。

完成标准：两个来源中的同剧能够合并，重复版本不增加集数；失败扫描保留旧库。

### 阶段三：首页与详情 UX

- 首页替换为影片索引数据。
- 新建影片卡片，旧目录卡保留在来源浏览。
- 实现聚合详情、季选择、剧集卡、版本面板、纠错及搜索。
- 连接播放解析、续播及逻辑下一集。

完成标准：从首页海报可看到实际拥有的季集，点击即可进入现有播放器。

### 阶段四：弹幕与整体回归

- 为播放、继续观看及下一集传递刮削上下文。
- 扩展自动匹配及整季任务入口。
- 增加手动匹配、状态展示和校正失效处理。
- 完成手机、平板及已有播放器功能回归。

完成标准：正式剧名与原文件名不同时仍能按刮削季集匹配；匹配失败不影响播放。

## 8. 验收方案

### 数据与服务测试

- 同一混合目录包含电影和多部剧。
- 同剧跨来源、多版本、重叠收藏根。
- 深层目录、分页、目录循环、取消后重启。
- 来源离线、鉴权失败、部分扫描成功。
- 人工改匹配后旧响应返回。
- 同时加载多个季后保存与重启。
- 特别篇、未知季号、纯数字文件及连续集号偏移。
- 删除一个收藏根后，另一个根仍引用同文件。
- 索引损坏恢复与旧数据迁移。

### UI 与用户流程测试

- 首次空库、扫描中、部分失败、未识别、无图和无集数状态。
- 搜索正式名、原名、集名和文件名。
- 单版本直接播放，多版本选择及记忆。
- 续播按钮定位正确，重复版本不进入下一集。
- 校正预览、冲突提示、保存和撤销。
- 手机、平板横竖屏、大字体与遥控器焦点。

### 弹幕测试

- 刮削名优先，原名回退，歧义不误选。
- 校正季集后相关自动匹配失效。
- 整季任务不混入其他作品。
- 切集、取消、源切换时旧请求不覆盖新结果。
- 多版本缓存独立，时间偏移只应用一次。

执行相关测试后运行完整 `flutter test` 与 `flutter analyze`。Android 真机验证在线起播、拖动、字幕、续播、HDR 路径及弹幕；iOS 使用现有 CI 构建，再在 iPad 验证。

验收报告区分自动测试通过、构建通过与真机确认。网络不可达时记录具体阻塞项，不把未验证结果写成已通过。
