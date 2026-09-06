import 'package:flutter/material.dart';

import '../danmaku/scraper/scrape_state.dart';
import '../danmaku/scraper/series_scraper.dart';
import '../danmaku/scraper/video_enumerator.dart';
import '../danmaku/service/danmaku_service.dart';
import '../danmaku/identity/video_identity.dart' as danmaku_identity;
import '../services/library_folders.dart';
import 'danmaku_settings_screen.dart';
import '../l10n/app_localizations.dart';

typedef SeriesScraperFactory =
    SeriesScraper Function(
      DanmakuScrapeSource source,
      DanmakuScrapeRepository repository,
      VoidCallback onChanged,
    );

/// Progress surface for scraping every playable episode below one library
/// folder.  The dependencies are injectable to keep the UI deterministic in
/// widget tests while production uses the shared danmaku service.
class DanmakuScrapeScreen extends StatefulWidget {
  const DanmakuScrapeScreen({
    super.key,
    required this.folder,
    required this.seriesTitle,
    this.enumerator,
    this.service,
    this.scraperFactory,
    this.initialVideos = const [],
    this.enumerateFolder = true,
  });

  final LibraryFolder folder;
  final String seriesTitle;
  final DanmakuVideoEnumerator? enumerator;
  final DanmakuService? service;
  final SeriesScraperFactory? scraperFactory;
  final List<ScrapeVideo> initialVideos;

  /// Unified-library callers already have the complete, season-scoped file
  /// list. Disabling enumeration prevents an unrelated rescan of the source
  /// root and keeps other titles out of the task.
  final bool enumerateFolder;

  @override
  State<DanmakuScrapeScreen> createState() => _DanmakuScrapeScreenState();
}

class _DanmakuScrapeScreenState extends State<DanmakuScrapeScreen> {
  late final DanmakuService _service =
      widget.service ?? DanmakuService.instance;
  late final DanmakuVideoEnumerator _enumerator =
      widget.enumerator ?? DanmakuVideoEnumerator();
  SeriesScraper? _scraper;
  SeriesScope? _scope;
  List<ScrapeVideo> _videos = const [];
  bool _preparing = true;
  String? _setupError;
  bool _noSource = false;

  SeriesScrapeState? get _state => _scraper?.state;
  bool get _running =>
      _preparing ||
      switch (_state?.phase) {
        ScrapePhase.scanning ||
        ScrapePhase.matching ||
        ScrapePhase.downloading => true,
        _ => false,
      };

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    if (_running) _scraper?.cancel();
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      await _service.init();
      final config = _service.primarySource;
      if (config == null) {
        if (mounted) {
          setState(() {
            _preparing = false;
            _noSource = true;
          });
        }
        return;
      }
      final found = widget.enumerateFolder
          ? await _enumerator.enumerate(
              VideoSource.fromLibraryFolder(widget.folder),
              folderName: widget.folder.name,
            )
          : const <EnumeratedVideo>[];
      final enumerated = <ScrapeVideo>[];
      for (final video in found) {
        final identity = await danmaku_identity.identityForAsync(video.item);
        enumerated.add(
          ScrapeVideo(
            key: identity.stableKey,
            fileName: identity.fileName,
            fileHash: identity.fileHash,
            sizeBytes: identity.fileSize,
            season: video.episode.season > 0 ? video.episode.season : null,
            episode: video.episode.episode > 0 ? video.episode.episode : null,
          ),
        );
      }
      // The details page already owns the authoritative direct-child listing
      // (notably SAF bookmarks and Jellyfin indices). Merge that with the
      // recursive enumerator and de-duplicate by stable playback identity.
      final byKey = <String, ScrapeVideo>{};
      for (final video in enumerated) {
        byKey.putIfAbsent(video.key, () => video);
      }
      for (final video in widget.initialVideos) {
        final normalized = _withNamespacedKey(video);
        byKey.putIfAbsent(normalized.key, () => normalized);
      }
      final videos = byKey.values.toList();
      final scope = SeriesScope(
        sourceId: config.id,
        sourceBaseUrl: config.baseUrl,
        seriesTitle: widget.seriesTitle.trim().isEmpty
            ? widget.folder.name
            : widget.seriesTitle.trim(),
        seriesKey: widget.folder.metadataKey,
      );
      late final SeriesScraper scraper;
      scraper =
          widget.scraperFactory?.call(
            _service.scrapeSourceFor(config),
            _service.scrapeRepositoryFor(config),
            _changed,
          ) ??
          SeriesScraper(
            source: _service.scrapeSourceFor(config),
            repository: _service.scrapeRepositoryFor(config),
            onChanged: _changed,
          );
      final restored = await scraper.restore(scope);
      if (!mounted) return;
      setState(() {
        _videos = videos;
        _scope = scope;
        _scraper = scraper;
        _preparing = false;
      });
      final currentKeys = videos.map((video) => video.key).toSet();
      final restoredKeys = restored?.episodes
          .map((episode) => episode.key)
          .toSet();
      final listingChanged =
          restoredKeys == null ||
          restoredKeys.length != currentKeys.length ||
          !restoredKeys.containsAll(currentKeys);
      if (videos.isNotEmpty &&
          (restored == null || restored.remainingCount > 0 || listingChanged)) {
        await _run();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _preparing = false;
          _setupError = 'Could not scan this series: $error';
        });
      }
    }
  }

  ScrapeVideo _withNamespacedKey(ScrapeVideo video) => ScrapeVideo(
    key: video.key.startsWith('danmaku:') ? video.key : 'danmaku:${video.key}',
    fileName: video.fileName,
    fileHash: video.fileHash,
    sizeBytes: video.sizeBytes,
    season: video.season,
    episode: video.episode,
  );

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run({bool force = false}) async {
    final scraper = _scraper;
    final scope = _scope;
    if (scraper == null || scope == null || _videos.isEmpty) return;
    setState(() {});
    await scraper.start(scope, _videos, forceRefresh: force);
    _changed();
  }

  Future<void> _retryFailed() async {
    final scraper = _scraper;
    final scope = _scope;
    if (scraper == null || scope == null) return;
    await scraper.retryFailed(scope);
    _changed();
  }

  Future<void> _configureSource() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DanmakuSettingsScreen(service: _service),
      ),
    );
    if (!mounted || _service.primarySource == null) return;
    setState(() {
      _preparing = true;
      _noSource = false;
      _setupError = null;
    });
    await _prepare();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const AppText('Scrape series danmaku')),
      body: SafeArea(
        child: _preparing
            ? const Center(child: CircularProgressIndicator())
            : _noSource
            ? _NoSource(onConfigure: _configureSource)
            : _setupError != null
            ? _Message(icon: Icons.error_outline, text: _setupError!)
            : _videos.isEmpty
            ? const _Message(
                icon: Icons.video_library_outlined,
                text: 'No playable episodes were found in this folder.',
              )
            : _content(theme),
      ),
    );
  }

  Widget _content(ThemeData theme) {
    final state = _state;
    final finished =
        state?.episodes
            .where(
              (e) => e.status.isTerminal || e.status == ScrapeStatus.cancelled,
            )
            .length ??
        0;
    final total = state?.total ?? _videos.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppText(
                    widget.seriesTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: total == 0 ? 0 : finished / total,
                  ),
                  const SizedBox(height: 8),
                  AppText('$finished / $total · ${_phaseLabel(state?.phase)}'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (_running)
                        OutlinedButton.icon(
                          key: const Key('cancel-scrape'),
                          onPressed: _scraper?.cancel,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const AppText('Cancel'),
                        ),
                      if (!_running &&
                          ((state?.failedCount ?? 0) > 0 ||
                              (state?.noMatchCount ?? 0) > 0))
                        FilledButton.tonalIcon(
                          key: const Key('retry-failed'),
                          onPressed: _retryFailed,
                          icon: const Icon(Icons.refresh),
                          label: const AppText('Retry failed'),
                        ),
                      if (!_running)
                        OutlinedButton.icon(
                          key: const Key('force-rescrape'),
                          onPressed: () => _run(force: true),
                          icon: const Icon(Icons.cloud_download_outlined),
                          label: const AppText('Force re-scrape'),
                        ),
                    ],
                  ),
                  if ((state?.noMatchCount ?? 0) > 0) ...[
                    const SizedBox(height: 12),
                    AppText(
                      'Unmatched or duplicate candidates need manual matching. '
                      'Manual selection is not supported here yet; no candidate was silently chosen.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: state?.episodes.length ?? _videos.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final episode = state?.episodes.elementAt(index);
              final video = _videos[index];
              return _EpisodeTile(
                fileName: episode?.fileName ?? video.fileName,
                season: episode?.season ?? video.season,
                episode: episode?.episode ?? video.episode,
                status: episode?.status ?? ScrapeStatus.pending,
                commentCount: episode?.commentCount,
                error: episode?.error,
              );
            },
          ),
        ),
      ],
    );
  }

  static String _phaseLabel(ScrapePhase? phase) => switch (phase) {
    ScrapePhase.scanning => 'Scanning',
    ScrapePhase.matching => 'Matching',
    ScrapePhase.downloading => 'Downloading',
    ScrapePhase.completed => 'Completed',
    ScrapePhase.cancelled => 'Cancelled',
    ScrapePhase.partialFailure => 'Partially completed',
    ScrapePhase.failed => 'Failed',
    _ => 'Ready',
  };
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.fileName,
    required this.status,
    this.season,
    this.episode,
    this.commentCount,
    this.error,
  });
  final String fileName;
  final ScrapeStatus status;
  final int? season;
  final int? episode;
  final int? commentCount;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = season != null && episode != null
        ? 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
        : fileName;
    return Card(
      child: ListTile(
        dense: true,
        leading: Icon(_statusIcon(status), color: _statusColor(theme, status)),
        title: AppText(label),
        subtitle: AppText(
          error ?? (label == fileName ? '' : fileName),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Semantics(
          label: 'Status ${status.name}',
          child: Chip(label: AppText(_statusLabel(status, commentCount))),
        ),
      ),
    );
  }

  static String _statusLabel(ScrapeStatus status, int? count) =>
      switch (status) {
        ScrapeStatus.cached => 'cached',
        ScrapeStatus.success => 'success${count == null ? '' : ' · $count'}',
        ScrapeStatus.empty => 'empty',
        ScrapeStatus.noMatch => 'noMatch',
        ScrapeStatus.failed => 'failed',
        ScrapeStatus.cancelled => 'cancelled',
        ScrapeStatus.matched => 'matched',
        ScrapeStatus.fetching => 'fetching',
        ScrapeStatus.pending => 'pending',
      };

  static IconData _statusIcon(ScrapeStatus status) => switch (status) {
    ScrapeStatus.cached => Icons.inventory_2_outlined,
    ScrapeStatus.success => Icons.check_circle_outline,
    ScrapeStatus.empty => Icons.comments_disabled_outlined,
    ScrapeStatus.noMatch => Icons.link_off,
    ScrapeStatus.failed => Icons.error_outline,
    ScrapeStatus.cancelled => Icons.cancel_outlined,
    _ => Icons.downloading_outlined,
  };

  static Color _statusColor(ThemeData theme, ScrapeStatus status) =>
      status == ScrapeStatus.failed || status == ScrapeStatus.noMatch
      ? theme.colorScheme.error
      : status == ScrapeStatus.success || status == ScrapeStatus.cached
      ? theme.colorScheme.primary
      : theme.colorScheme.onSurfaceVariant;
}

class _NoSource extends StatelessWidget {
  const _NoSource({required this.onConfigure});
  final VoidCallback onConfigure;
  @override
  Widget build(BuildContext context) => _Message(
    icon: Icons.settings_outlined,
    text:
        'No danmaku source is enabled. Add and enable one in Settings → Danmaku sources, then try again.',
    action: OutlinedButton.icon(
      key: const Key('configure-source'),
      onPressed: onConfigure,
      icon: const Icon(Icons.settings_outlined),
      label: const AppText('Configure source'),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            AppText(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    ),
  );
}
