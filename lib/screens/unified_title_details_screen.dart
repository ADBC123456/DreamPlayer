import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../danmaku/binding/danmaku_binding_store.dart';
import '../danmaku/scraper/scrape_state.dart';
import '../danmaku/service/danmaku_service.dart';
import '../library/models/library_models.dart';
import '../library/title_playback_preferences.dart';
import '../library/unified_library_service.dart';
import '../l10n/app_localizations.dart';
import '../models/video_item.dart';
import '../services/continue_watching.dart';
import '../services/library_folders.dart';
import 'danmaku_scrape_screen.dart';
import 'player_screen.dart';

/// Aggregated title page. Homepage posters always land here; source browsing
/// remains a separate workflow on the library screen.
class UnifiedTitleDetailsScreen extends StatefulWidget {
  const UnifiedTitleDetailsScreen({super.key, required this.titleId});

  final String titleId;

  @override
  State<UnifiedTitleDetailsScreen> createState() =>
      _UnifiedTitleDetailsScreenState();
}

class _UnifiedTitleDetailsScreenState extends State<UnifiedTitleDetailsScreen> {
  static const _pageColor = Color(0xFF20212B);

  final UnifiedLibraryService _library = UnifiedLibraryService.instance;
  List<ContinueWatchingEntry> _progress = const [];
  int? _selectedSeason;
  bool _seasonChosen = false;
  bool _opening = false;
  bool _refreshing = false;
  bool _overviewExpanded = false;
  Map<String, ScrapeEpisodeState> _danmakuByFileKey = const {};
  String? _requestedDanmakuScope;

  ContinueWatchingEntry? get _resume => _progress.firstOrNull;

  @override
  void initState() {
    super.initState();
    _library.addListener(_onLibraryChanged);
    ContinueWatchingStore.changes.addListener(_loadProgress);
    _loadProgress();
  }

  @override
  void dispose() {
    _library.removeListener(_onLibraryChanged);
    ContinueWatchingStore.changes.removeListener(_loadProgress);
    super.dispose();
  }

  void _onLibraryChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadProgress() async {
    final entries =
        (await ContinueWatchingStore.load())
            .where((e) => e.video.metadataContext?.titleId == widget.titleId)
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (mounted) setState(() => _progress = entries);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _library.snapshot;
    final title = snapshot.titles[widget.titleId];
    if (title == null) {
      return Scaffold(
        backgroundColor: _pageColor,
        appBar: AppBar(backgroundColor: Colors.transparent),
        body: const Center(child: AppText('影片信息不可用')),
      );
    }

    final files = snapshot
        .filesForTitle(title.id)
        .where((f) => f.availability != MediaAvailability.missing)
        .toList();
    final episodes =
        snapshot.episodes.values
            .where(
              (e) =>
                  e.titleId == title.id &&
                  snapshot.versionsForEpisode(e.id).isNotEmpty,
            )
            .toList()
          ..sort(_compareEpisodes);
    final seasons =
        episodes.map((e) => e.seasonNumber).whereType<int>().toSet().toList()
          ..sort();
    if (!_seasonChosen && seasons.isNotEmpty) {
      _seasonChosen = true;
      _selectedSeason = seasons.firstWhere(
        (s) => s > 0,
        orElse: () => seasons.first,
      );
    }
    if (_selectedSeason != null && !seasons.contains(_selectedSeason)) {
      _selectedSeason = seasons.firstOrNull;
    }
    final visibleEpisodes = seasons.length <= 1
        ? episodes
        : episodes.where((e) => e.seasonNumber == _selectedSeason).toList();
    final danmakuScope = '${title.id}:s${_selectedSeason ?? 'unknown'}';
    if (_requestedDanmakuScope != danmakuScope) {
      _requestedDanmakuScope = danmakuScope;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _loadDanmakuMatches(title, _selectedSeason),
      );
    }
    final duplicates = episodes
        .where((e) => snapshot.versionsForEpisode(e.id).length > 1)
        .toList();

    final media = MediaQuery.of(context);
    final heroHeight = media.orientation == Orientation.landscape
        ? (media.size.height * .73).clamp(440.0, 720.0)
        : (media.size.height * .62).clamp(440.0, 610.0);

    return Scaffold(
      backgroundColor: _pageColor,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(
              height: heroHeight,
              child: _TitleHero(
                title: title,
                ownedEpisodes: episodes.length,
                playLabel: _primaryLabel(),
                opening: _opening,
                refreshing: _refreshing,
                canPlay: files.isNotEmpty,
                onBack: () => Navigator.maybePop(context),
                onPlay: () => _playPrimary(title, episodes, files),
                onPlayMpv: Platform.isAndroid
                    ? () => _playPrimary(
                        title,
                        episodes,
                        files,
                        engine: PlayEngine.mpv,
                      )
                    : null,
                onMenu: (value) =>
                    _handleMenu(value, title, files, visibleEpisodes),
              ),
            ),
          ),
          if (title.overview.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () =>
                      setState(() => _overviewExpanded = !_overviewExpanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: AppText(
                      title.overview,
                      maxLines: _overviewExpanded ? null : 3,
                      overflow: _overviewExpanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        height: 1.55,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (title.kind == MediaTitleKind.tv) ...[
            SliverToBoxAdapter(
              child: _SeasonHeader(
                seasons: seasons,
                selected: _selectedSeason,
                onSelected: (season) {
                  _requestedDanmakuScope = null;
                  setState(() => _selectedSeason = season);
                },
                onDanmaku: visibleEpisodes.isEmpty
                    ? null
                    : () =>
                          _openDanmaku(title, _selectedSeason, visibleEpisodes),
              ),
            ),
            if (visibleEpisodes.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(24, 20, 24, 32),
                  child: AppText(
                    '这一季暂时没有可播放的剧集',
                    style: TextStyle(color: Colors.white60),
                  ),
                ),
              )
            else
              SliverToBoxAdapter(
                child: _EpisodeRail(
                  episodes: visibleEpisodes,
                  versionsFor: snapshot.versionsForEpisode,
                  progressFor: _episodeProgress,
                  danmakuFor: _episodeDanmaku,
                  onPlay: (episode, versions) =>
                      _chooseAndPlay(title, episode, versions),
                  onMore: (episode, versions) =>
                      _showEpisodeActions(title, episode, versions),
                ),
              ),
            if (duplicates.isNotEmpty)
              SliverToBoxAdapter(
                child: _DuplicateNotice(
                  count: duplicates.length,
                  onTap: () => _showDuplicates(title, duplicates),
                ),
              ),
          ] else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              sliver: SliverList.builder(
                itemCount: files.length,
                itemBuilder: (_, index) => ListTile(
                  minTileHeight: 62,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.movie_outlined),
                  title: AppText(files[index].originalFileName),
                  subtitle: AppText(
                    '${_sourceLabel(files[index])} · ${_sizeLabel(files[index].sizeBytes)}',
                  ),
                  trailing: const Icon(Icons.play_arrow_rounded),
                  onTap: () => _playVersion(title, null, files[index]),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 42)),
        ],
      ),
    );
  }

  static int _compareEpisodes(LibraryEpisode a, LibraryEpisode b) {
    final season = (a.seasonNumber ?? 1 << 20).compareTo(
      b.seasonNumber ?? 1 << 20,
    );
    return season == 0 ? a.episodeNumber.compareTo(b.episodeNumber) : season;
  }

  _EpisodeProgress? _episodeProgress(List<MediaFile> versions) {
    for (final file in versions) {
      final entry = _progress
          .where(
            (e) =>
                ContinueWatchingStore.keyFor(e.video) == file.legacyResumeKey,
          )
          .firstOrNull;
      if (entry == null) continue;
      final duration = entry.video.duration;
      return _EpisodeProgress(
        entry.position,
        duration > Duration.zero
            ? (entry.position.inMilliseconds / duration.inMilliseconds).clamp(
                0.0,
                1.0,
              )
            : null,
      );
    }
    return null;
  }

  ScrapeEpisodeState? _episodeDanmaku(List<MediaFile> versions) {
    for (final file in versions) {
      final key = file.legacyResumeKey;
      final state = _danmakuByFileKey[key] ?? _danmakuByFileKey['danmaku:$key'];
      if (state?.ref != null &&
          (state!.status == ScrapeStatus.matched ||
              state.status == ScrapeStatus.success ||
              state.status == ScrapeStatus.empty ||
              state.status == ScrapeStatus.cached)) {
        return state;
      }
    }
    return null;
  }

  Future<void> _loadDanmakuMatches(MediaTitle title, int? season) async {
    final service = DanmakuService.instance;
    await service.init();
    final source = service.primarySource;
    if (source == null || !mounted) return;
    final folder = LibraryFolder(
      id: 'unified:${title.id}:s${season ?? 'unknown'}',
      name: title.displayTitle,
      path: 'unified:${title.id}',
      addedAt: DateTime.now(),
    );
    final scope = SeriesScope(
      sourceId: source.id,
      sourceBaseUrl: source.baseUrl,
      seriesTitle: title.displayTitle,
      seriesKey: folder.metadataKey,
    );
    final bindings = await DanmakuBindingStore.loadForScope(scope);
    if (!mounted ||
        _requestedDanmakuScope != '${title.id}:s${season ?? 'unknown'}') {
      return;
    }
    setState(() {
      _danmakuByFileKey = {
        for (final entry in bindings.entries)
          entry.key: ScrapeEpisodeState(
            key: entry.key,
            fileName: entry.key,
            status: ScrapeStatus.matched,
            ref: entry.value.ref,
          ),
      };
    });
  }

  String _primaryLabel() {
    final entry = _resume;
    if (entry == null) return '播放';
    final episode = entry.video.metadataContext?.episodeNumber;
    return episode == null
        ? '继续播放  ${_clock(entry.position)}'
        : '播放第 $episode 集  ${_clock(entry.position)}';
  }

  Future<void> _handleMenu(
    String value,
    MediaTitle title,
    List<MediaFile> files,
    List<LibraryEpisode> episodes,
  ) async {
    if (value == 'refresh') {
      await _refreshTitle(files);
      return;
    }
    if (value == 'danmaku') {
      await _openDanmaku(title, _selectedSeason, episodes);
      return;
    }
    if (value == 'copy') {
      await Clipboard.setData(ClipboardData(text: title.displayTitle));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: AppText('片名已复制')));
      }
    }
  }

  Future<void> _refreshTitle(List<MediaFile> files) async {
    if (_refreshing) return;
    final rootIds = files.expand((file) => file.rootIds).toSet();
    final folders = (await LibraryFoldersStore.load())
        .where((folder) => rootIds.contains(folder.id))
        .toList();
    if (!mounted) return;
    if (folders.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('没有找到可刷新的来源目录')));
      return;
    }
    setState(() => _refreshing = true);
    try {
      await _library.refresh(folders);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: AppText('刮削信息已刷新')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: AppText('刷新失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _playPrimary(
    MediaTitle title,
    List<LibraryEpisode> episodes,
    List<MediaFile> files, {
    PlayEngine engine = PlayEngine.media3,
  }) async {
    if (title.kind == MediaTitleKind.movie) {
      await _chooseAndPlay(title, null, files, engine: engine);
      return;
    }
    if (episodes.isEmpty) return;
    final resumeKey = _resume?.video.resumeKey;
    final resumeFile = resumeKey == null
        ? null
        : files.where((f) => f.legacyResumeKey == resumeKey).firstOrNull;
    if (resumeFile != null) {
      final episode = resumeFile.episodeId == null
          ? null
          : _library.snapshot.episodes[resumeFile.episodeId];
      await _playVersion(title, episode, resumeFile, engine: engine);
      return;
    }
    final first = episodes.first;
    await _chooseAndPlay(
      title,
      first,
      _library.snapshot.versionsForEpisode(first.id),
      engine: engine,
    );
  }

  Future<void> _chooseAndPlay(
    MediaTitle title,
    LibraryEpisode? episode,
    List<MediaFile> versions, {
    PlayEngine engine = PlayEngine.media3,
  }) async {
    if (versions.isEmpty) return;
    if (versions.length == 1) {
      await _playVersion(title, episode, versions.single, engine: engine);
      return;
    }
    final preference = await TitlePlaybackPreferences.load(title.id);
    final preferred = versions
        .where((f) => f.sourceRef.sourceId == preference?.preferredSourceId)
        .toList();
    if (preferred.length == 1) {
      await _playVersion(title, episode, preferred.single, engine: engine);
      return;
    }
    if (!mounted) return;
    final selected = await showModalBottomSheet<_VersionChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFF292A35),
      builder: (_) => _VersionSheet(episode: episode, versions: versions),
    );
    if (selected == null) return;
    if (selected.remember) {
      await TitlePlaybackPreferences.save(
        titleId: title.id,
        preferredSourceId: selected.file.sourceRef.sourceId,
      );
    }
    await _playVersion(title, episode, selected.file, engine: engine);
  }

  Future<void> _playVersion(
    MediaTitle title,
    LibraryEpisode? episode,
    MediaFile file, {
    PlayEngine engine = PlayEngine.media3,
  }) async {
    setState(() => _opening = true);
    try {
      final resolved = await _library.resolvePlayable(file);
      final video = resolved.withMetadataContext(
        VideoMetadataContext(
          titleId: title.id,
          displayTitle: title.displayTitle,
          originalTitle: title.originalTitle,
          seasonNumber: episode?.seasonNumber,
          episodeNumber: episode?.episodeNumber,
          episodeTitle: episode?.displayName,
          revision: title.revision,
        ),
      );
      await TitlePlaybackPreferences.save(
        titleId: title.id,
        lastPlayedFileId: file.id,
        lastPlayedEpisodeId: episode?.id,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(video: video, initialEngine: engine),
        ),
      );
      await _loadProgress();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: AppText('无法打开这个版本：$error')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _showEpisodeActions(
    MediaTitle title,
    LibraryEpisode episode,
    List<MediaFile> versions,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF292A35),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: AppText(
                '第 ${episode.episodeNumber} 集 · ${episode.displayName}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              minTileHeight: 56,
              leading: const Icon(Icons.play_arrow_rounded),
              title: AppText(versions.length > 1 ? '选择播放版本' : '播放本集'),
              onTap: () => Navigator.pop(context, 'play'),
            ),
            ListTile(
              minTileHeight: 56,
              leading: const Icon(Icons.subtitles_outlined),
              title: const AppText('匹配本集弹幕'),
              onTap: () => Navigator.pop(context, 'danmaku'),
            ),
          ],
        ),
      ),
    );
    if (action == 'play') {
      await _chooseAndPlay(title, episode, versions);
    } else if (action == 'danmaku') {
      final seasonEpisodes =
          _library.snapshot.episodes.values
              .where(
                (candidate) =>
                    candidate.titleId == title.id &&
                    candidate.seasonNumber == episode.seasonNumber &&
                    _library.snapshot
                        .versionsForEpisode(candidate.id)
                        .isNotEmpty,
              )
              .toList()
            ..sort(_compareEpisodes);
      await _openDanmaku(title, episode.seasonNumber, seasonEpisodes);
    }
  }

  Future<void> _showDuplicates(
    MediaTitle title,
    List<LibraryEpisode> episodes,
  ) async {
    final selected = await showModalBottomSheet<LibraryEpisode>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFF292A35),
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 6, 20, 8),
                child: AppText(
                  '重复剧集版本',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: AppText(
                  '同一集只显示一张卡片，所有来源版本都保留。',
                  style: TextStyle(color: Colors.white60),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final episode in episodes)
                      ListTile(
                        minTileHeight: 58,
                        title: AppText(
                          '第 ${episode.episodeNumber} 集 · ${episode.displayName}',
                        ),
                        subtitle: AppText(
                          '${_library.snapshot.versionsForEpisode(episode.id).length} 个版本',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pop(context, episode),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) {
      await _chooseAndPlay(
        title,
        selected,
        _library.snapshot.versionsForEpisode(selected.id),
      );
    }
  }

  Future<void> _openDanmaku(
    MediaTitle title,
    int? season,
    List<LibraryEpisode> episodes,
  ) async {
    final videos = <ScrapeVideo>[];
    for (final episode in episodes) {
      for (final file in _library.snapshot.versionsForEpisode(episode.id)) {
        videos.add(
          ScrapeVideo(
            key: file.legacyResumeKey,
            fileName: file.originalFileName,
            sizeBytes: file.sizeBytes,
            season: episode.seasonNumber,
            episode: episode.episodeNumber,
          ),
        );
      }
    }
    if (videos.isEmpty || !mounted) return;
    final folder = LibraryFolder(
      id: 'unified:${title.id}:s${season ?? 'unknown'}',
      name: title.displayTitle,
      path: 'unified:${title.id}',
      addedAt: DateTime.now(),
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DanmakuScrapeScreen(
          folder: folder,
          seriesTitle: title.displayTitle,
          initialVideos: videos,
          enumerateFolder: false,
        ),
      ),
    );
    _requestedDanmakuScope = '${title.id}:s${season ?? 'unknown'}';
    await _loadDanmakuMatches(title, season);
  }
}

class _TitleHero extends StatelessWidget {
  const _TitleHero({
    required this.title,
    required this.ownedEpisodes,
    required this.playLabel,
    required this.opening,
    required this.refreshing,
    required this.canPlay,
    required this.onBack,
    required this.onPlay,
    required this.onPlayMpv,
    required this.onMenu,
  });

  final MediaTitle title;
  final int ownedEpisodes;
  final String playLabel;
  final bool opening;
  final bool refreshing;
  final bool canPlay;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final VoidCallback? onPlayMpv;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF171820)),
        _Artwork(primary: title.backdrop, fallback: title.poster),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, .46, .78, 1],
              colors: [
                Color(0x28000000),
                Color(0x08000000),
                Color(0xB520212B),
                Color(0xFF20212B),
              ],
            ),
          ),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(wide ? 28 : 12, 10, wide ? 28 : 12, 0),
            child: Align(
              alignment: Alignment.topCenter,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _CircleButton(
                    tooltip: '返回',
                    icon: Icons.arrow_back_ios_new_rounded,
                    onPressed: onBack,
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多操作',
                    onSelected: onMenu,
                    color: const Color(0xFF30313B),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'refresh',
                        child: _MenuRow(Icons.refresh, '刷新刮削信息'),
                      ),
                      if (title.kind == MediaTitleKind.tv)
                        const PopupMenuItem(
                          value: 'danmaku',
                          child: _MenuRow(Icons.subtitles_outlined, '匹配当前季弹幕'),
                        ),
                      const PopupMenuItem(
                        value: 'copy',
                        child: _MenuRow(Icons.copy_outlined, '复制片名'),
                      ),
                    ],
                    child: _CircleSurface(loading: refreshing),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: wide ? 38 : 20,
          right: wide ? 38 : 20,
          bottom: wide ? 24 : 18,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AppText(
                title.displayTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: wide ? 34 : 28,
                  height: 1.08,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.4,
                  shadows: const [
                    Shadow(color: Colors.black54, blurRadius: 12),
                  ],
                ),
              ),
              const SizedBox(height: 17),
              if (wide)
                Row(
                  children: [
                    _PlayButton(
                      label: playLabel,
                      loading: opening,
                      enabled: canPlay,
                      onTap: onPlay,
                    ),
                    if (onPlayMpv != null) ...[
                      const SizedBox(width: 10),
                      _MpvButton(
                        enabled: canPlay && !opening,
                        onTap: onPlayMpv!,
                      ),
                    ],
                    const SizedBox(width: 20),
                    Expanded(
                      child: _Metadata(title: title, owned: ownedEpisodes),
                    ),
                  ],
                )
              else ...[
                _Metadata(title: title, owned: ownedEpisodes),
                const SizedBox(height: 13),
                Row(
                  children: [
                    Expanded(
                      child: _PlayButton(
                        label: playLabel,
                        loading: opening,
                        enabled: canPlay,
                        onTap: onPlay,
                      ),
                    ),
                    if (onPlayMpv != null) ...[
                      const SizedBox(width: 10),
                      _MpvButton(
                        enabled: canPlay && !opening,
                        onTap: onPlayMpv!,
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({this.primary, this.fallback});
  final String? primary;
  final String? fallback;

  @override
  Widget build(BuildContext context) {
    final url = primary ?? fallback;
    if (url == null) {
      return const Center(
        child: Icon(Icons.movie_outlined, size: 72, color: Colors.white24),
      );
    }
    return Image.network(
      url,
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => fallback != null && fallback != url
          ? Image.network(
              fallback!,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            )
          : const SizedBox.shrink(),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: .24),
    shape: const CircleBorder(side: BorderSide(color: Colors.white38)),
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      color: Colors.white,
    ),
  );
}

class _CircleSurface extends StatelessWidget {
  const _CircleSurface({required this.loading});
  final bool loading;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: .24),
    shape: const CircleBorder(side: BorderSide(color: Colors.white38)),
    child: SizedBox.square(
      dimension: 48,
      child: Center(
        child: loading
            ? const SizedBox.square(
                dimension: 19,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.more_horiz_rounded, color: Colors.white),
      ),
    ),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) =>
      Row(children: [Icon(icon), const SizedBox(width: 12), AppText(label)]);
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.label,
    required this.loading,
    required this.enabled,
    required this.onTap,
  });
  final String label;
  final bool loading;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    style: FilledButton.styleFrom(
      minimumSize: const Size(250, 54),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      backgroundColor: Colors.white,
      foregroundColor: const Color(0xFF171820),
      disabledBackgroundColor: Colors.white24,
      disabledForegroundColor: Colors.white54,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
    ),
    onPressed: enabled && !loading ? onTap : null,
    icon: loading
        ? const SizedBox.square(
            dimension: 19,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.play_arrow_rounded, size: 27),
    label: AppText(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  );
}

class _MpvButton extends StatelessWidget {
  const _MpvButton({required this.enabled, required this.onTap});
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton.outlined(
    tooltip: '使用 MPV 播放',
    onPressed: enabled ? onTap : null,
    style: IconButton.styleFrom(
      minimumSize: const Size(54, 54),
      foregroundColor: Colors.white,
      side: const BorderSide(color: Colors.white38),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    icon: const Icon(Icons.smart_display_outlined),
  );
}

class _Metadata extends StatelessWidget {
  const _Metadata({required this.title, required this.owned});
  final MediaTitle title;
  final int owned;

  @override
  Widget build(BuildContext context) {
    final facts = <String>[
      if (title.rating > 0) 'TMDB ${title.rating.toStringAsFixed(1)}',
      if (title.releaseDate?.isNotEmpty == true)
        title.releaseDate!
      else if (title.year != null)
        '${title.year}',
      if (title.kind == MediaTitleKind.tv)
        title.totalEpisodeCount == null
            ? '库中 $owned 集'
            : '共 ${title.totalEpisodeCount} 集 · 库中 $owned 集'
      else
        '电影',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 5,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var i = 0; i < facts.length; i++) ...[
              if (i > 0)
                const Text('·', style: TextStyle(color: Colors.white38)),
              AppText(
                facts[i],
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
        if (title.genres.isNotEmpty) ...[
          const SizedBox(height: 7),
          AppText(
            title.genres.take(4).join('  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ],
    );
  }
}

class _SeasonHeader extends StatelessWidget {
  const _SeasonHeader({
    required this.seasons,
    required this.selected,
    required this.onSelected,
    required this.onDanmaku,
  });
  final List<int> seasons;
  final int? selected;
  final ValueChanged<int> onSelected;
  final VoidCallback? onDanmaku;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 4, 12, 7),
    child: Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final season in seasons)
                  _SeasonTab(
                    label: season == 0 ? '特别篇' : '第 $season 季',
                    selected: season == selected,
                    onTap: () => onSelected(season),
                  ),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: '匹配当前季弹幕',
          onPressed: onDanmaku,
          icon: const Icon(Icons.subtitles_outlined),
          color: Colors.white70,
        ),
      ],
    ),
  );
}

class _SeasonTab extends StatelessWidget {
  const _SeasonTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(4),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(13, 10, 13, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppText(
            label,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white54,
              fontSize: 18,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          const SizedBox(height: 7),
          AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            width: selected ? 48 : 0,
            height: 3,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    ),
  );
}

class _EpisodeProgress {
  const _EpisodeProgress(this.position, this.fraction);
  final Duration position;
  final double? fraction;
}

class _EpisodeRail extends StatelessWidget {
  const _EpisodeRail({
    required this.episodes,
    required this.versionsFor,
    required this.progressFor,
    required this.danmakuFor,
    required this.onPlay,
    required this.onMore,
  });
  final List<LibraryEpisode> episodes;
  final List<MediaFile> Function(String) versionsFor;
  final _EpisodeProgress? Function(List<MediaFile>) progressFor;
  final ScrapeEpisodeState? Function(List<MediaFile>) danmakuFor;
  final void Function(LibraryEpisode, List<MediaFile>) onPlay;
  final void Function(LibraryEpisode, List<MediaFile>) onMore;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width >= 600 ? 214.0 : 174.0;
    return SizedBox(
      height: width * 9 / 16 + 94,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
        scrollDirection: Axis.horizontal,
        itemCount: episodes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (_, index) {
          final episode = episodes[index];
          final versions = versionsFor(episode.id);
          return SizedBox(
            width: width,
            child: _EpisodeCard(
              episode: episode,
              versions: versions,
              progress: progressFor(versions),
              danmaku: danmakuFor(versions),
              onPlay: () => onPlay(episode, versions),
              onMore: () => onMore(episode, versions),
            ),
          );
        },
      ),
    );
  }
}

class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({
    required this.episode,
    required this.versions,
    required this.progress,
    required this.danmaku,
    required this.onPlay,
    required this.onMore,
  });
  final LibraryEpisode episode;
  final List<MediaFile> versions;
  final _EpisodeProgress? progress;
  final ScrapeEpisodeState? danmaku;
  final VoidCallback onPlay;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AspectRatio(
        aspectRatio: 16 / 9,
        child: Material(
          color: const Color(0xFF30313A),
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: onPlay,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (episode.still != null)
                  Image.network(
                    episode.still!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  )
                else
                  const Center(
                    child: Icon(
                      Icons.movie_outlined,
                      color: Colors.white24,
                      size: 36,
                    ),
                  ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0x8C000000)],
                    ),
                  ),
                ),
                const Center(
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 34,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
                  ),
                ),
                if (episode.runtime != null)
                  Positioned(
                    right: 8,
                    bottom: 7,
                    child: AppText(
                      _clock(episode.runtime!),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        shadows: [Shadow(color: Colors.black, blurRadius: 5)],
                      ),
                    ),
                  ),
                if (progress?.fraction != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: progress!.fraction,
                      minHeight: 3,
                      color: const Color(0xFF3F8CFF),
                      backgroundColor: Colors.white24,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 7),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: AppText(
              '${episode.episodeNumber}. ${episode.displayName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(
            width: 48,
            height: 40,
            child: IconButton(
              padding: EdgeInsets.zero,
              alignment: Alignment.topRight,
              tooltip: '剧集操作',
              onPressed: onMore,
              icon: const Icon(Icons.more_horiz, size: 21),
              color: Colors.white60,
            ),
          ),
        ],
      ),
      if (versions.length > 1)
        AppText(
          '${versions.length} 个版本',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        )
      else if (progress != null)
        AppText(
          '看到 ${_clock(progress!.position)}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      if (danmaku?.ref != null)
        Tooltip(
          message: danmaku!.ref!.animeTitle ?? '',
          child: AppText(
            '弹幕：${danmaku!.ref!.episodeTitle ?? '第 ${episode.episodeNumber} 集'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFF7CB5FF), fontSize: 12),
          ),
        ),
    ],
  );
}

class _DuplicateNotice extends StatelessWidget {
  const _DuplicateNotice({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
    child: Material(
      color: const Color(0xFF292A34),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const Icon(
                Icons.copy_all_outlined,
                size: 19,
                color: Colors.white60,
              ),
              const SizedBox(width: 10),
              Expanded(child: AppText('检测到 $count 集存在重复版本未展开显示')),
              const AppText('查看解决办法', style: TextStyle(color: Colors.white70)),
              const SizedBox(width: 3),
              const Icon(Icons.chevron_right, color: Colors.white60),
            ],
          ),
        ),
      ),
    ),
  );
}

class _VersionChoice {
  const _VersionChoice(this.file, this.remember);
  final MediaFile file;
  final bool remember;
}

class _VersionSheet extends StatefulWidget {
  const _VersionSheet({required this.episode, required this.versions});
  final LibraryEpisode? episode;
  final List<MediaFile> versions;

  @override
  State<_VersionSheet> createState() => _VersionSheetState();
}

class _VersionSheetState extends State<_VersionSheet> {
  late MediaFile _selected = widget.versions.first;
  bool _remember = true;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText(
            widget.episode == null
                ? '选择播放版本'
                : '第 ${widget.episode!.episodeNumber} 集 · 选择播放版本',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          for (final file in widget.versions)
            RadioListTile<MediaFile>(
              value: file,
              // ignore: deprecated_member_use
              groupValue: _selected,
              // ignore: deprecated_member_use
              onChanged: (value) {
                if (value != null) setState(() => _selected = value);
              },
              contentPadding: EdgeInsets.zero,
              title: AppText(_sourceLabel(file)),
              subtitle: AppText(
                '${file.originalFileName} · ${_sizeLabel(file.sizeBytes)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          CheckboxListTile(
            value: _remember,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: (value) => setState(() => _remember = value ?? false),
            title: const AppText('此剧优先使用该来源'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            onPressed: () =>
                Navigator.pop(context, _VersionChoice(_selected, _remember)),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const AppText('播放'),
          ),
        ],
      ),
    ),
  );
}

String _clock(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

String _sourceLabel(MediaFile file) => switch (file.sourceRef.sourceType) {
  'webdav' => 'WebDAV',
  'jellyfin' => 'Jellyfin',
  'smb' => 'SMB',
  'ftp' => 'FTP / SFTP',
  'upnp' => 'DLNA',
  _ => Platform.isIOS ? 'Files' : '本地存储',
};

String _sizeLabel(int? bytes) {
  if (bytes == null || bytes <= 0) return '大小未知';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}
