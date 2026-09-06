/// Pure state models for the whole-series danmaku scrape task
/// (任务 .trellis/tasks/09-04-danmaku-source-series-scrape).
///
/// No I/O here: everything is data + computed counters so the orchestrator
/// ([SeriesScraper]) and the persistence layer ([ScrapeStore]) stay testable.
library;

/// Per-episode scrape lifecycle. Terminal states are [cached], [success],
/// [empty], [noMatch] and [failed]; [cancelled] marks an episode whose
/// in-flight work was abandoned by a cancel/new-generation.
enum ScrapeStatus {
  /// Waiting to be processed.
  pending,

  /// A valid danmaku cache already exists for this video — skipped.
  cached,

  /// A remote episode ref is resolved (catalog mapping or /match), not
  /// downloaded yet.
  matched,

  /// Downloading + caching the comments.
  fetching,

  /// Downloaded and cached; count > 0.
  success,

  /// Matched and downloaded, but the remote episode has 0 comments.
  empty,

  /// Neither the catalog mapping nor /match could resolve this video.
  noMatch,

  /// Network/decode failure after the limited retries.
  failed,

  /// The run was cancelled (or superseded) while this episode was in flight.
  cancelled;

  bool get isTerminal =>
      this == cached ||
      this == success ||
      this == empty ||
      this == noMatch ||
      this == failed;

  /// Lower-case name used by [ScrapeStore] JSON and UI badges.
  String get wire => name;

  /// Inverse of [wire]; unknown strings fall back to [pending].
  static ScrapeStatus fromWire(String? name) =>
      ScrapeStatus.values.asNameMap()[name] ?? ScrapeStatus.pending;
}

/// Overall batch-task phase (PRD: 未开始/扫描中/匹配中/下载中/已完成/已取消/
/// 部分失败/失败).
enum ScrapePhase {
  idle,
  scanning,
  matching,
  downloading,
  completed,
  cancelled,
  partialFailure,
  failed;

  String get wire => name;

  /// Inverse of [wire]; unknown strings fall back to [failed].
  static ScrapePhase fromWire(String? name) =>
      ScrapePhase.values.asNameMap()[name] ?? ScrapePhase.failed;
}

/// One locally-enumerated video of the series (a playable episode file).
class ScrapeVideo {
  const ScrapeVideo({
    required this.key,
    required this.fileName,
    this.sizeBytes,
    this.fileHash,
    this.season,
    this.episode,
  });

  /// Stable video identity (the same key the rest of the app uses:
  /// `TmdStore.identityKeyFor` / resumeKey / path).
  final String key;

  /// File name (or last URL segment) sent to /match and used for parsing.
  final String fileName;

  final int? sizeBytes;

  /// Optional first-16MiB MD5 (Agent B). Null when unavailable — the
  /// degraded identity is stable URI/path + name + size (PRD 缓存与刮削结果).
  final String? fileHash;

  /// Parsed season number (0/1-based; null when unknown).
  final int? season;

  /// Parsed episode number (null when unknown, e.g. OVA/SP filenames).
  final int? episode;

  Map<String, dynamic> toJson() => {
    'key': key,
    'fileName': fileName,
    if (sizeBytes != null) 'sizeBytes': sizeBytes,
    if (fileHash != null) 'fileHash': fileHash,
    if (season != null) 'season': season,
    if (episode != null) 'episode': episode,
  };

  factory ScrapeVideo.fromJson(Map<String, dynamic> json) => ScrapeVideo(
    key: json['key'] as String? ?? '',
    fileName: json['fileName'] as String? ?? '',
    sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
    fileHash: json['fileHash'] as String?,
    season: (json['season'] as num?)?.toInt(),
    episode: (json['episode'] as num?)?.toInt(),
  );
}

/// The series the user asked to scrape: identity + where the videos came
/// from. [sourceId]/[sourceBaseUrl] isolate persisted task state per danmaku
/// source deployment (PRD: 缓存按弹幕源、源地址…隔离).
class SeriesScope {
  const SeriesScope({
    required this.sourceId,
    required this.sourceBaseUrl,
    required this.seriesTitle,
    required this.seriesKey,
    this.season,
  });

  /// Danmaku source identifier, e.g. `danmu_api`.
  final String sourceId;

  /// The deployment base URL the source talks to (never contains a token).
  final String sourceBaseUrl;

  /// Title used for `GET /api/v2/search/episodes?anime=`.
  final String seriesTitle;

  /// Stable series identity (TMDB id / folder path) — scopes the persisted
  /// task state.
  final String seriesKey;

  /// Season this scope covers (null = whole series / unknown).
  final int? season;

  /// Persisted-store key isolating this (source, deployment, series).
  String get storeKey {
    final base = sourceBaseUrl.replaceAll(RegExp(r'^https?://'), '');
    return '$sourceId|$base|$seriesKey';
  }
}

/// A resolved remote episode: which anime/episode on the danmaku server this
/// local video maps to. IDs are strings on purpose — the danmu_api protocol
/// allows numeric and string IDs and forcing ints loses them (PRD).
class DanmakuEpisodeRef {
  const DanmakuEpisodeRef({
    required this.animeId,
    required this.episodeId,
    this.animeTitle,
    this.episodeTitle,
    this.shift = 0,
  });

  final String animeId;
  final String episodeId;
  final String? animeTitle;
  final String? episodeTitle;

  /// Comment time offset (seconds) reported by /match.
  final num shift;

  Map<String, dynamic> toJson() => {
    'animeId': animeId,
    'episodeId': episodeId,
    if (animeTitle != null) 'animeTitle': animeTitle,
    if (episodeTitle != null) 'episodeTitle': episodeTitle,
    if (shift != 0) 'shift': shift,
  };

  factory DanmakuEpisodeRef.fromJson(Map<String, dynamic> json) =>
      DanmakuEpisodeRef(
        animeId: _id(json['animeId']),
        episodeId: _id(json['episodeId']),
        animeTitle: json['animeTitle'] as String?,
        episodeTitle: json['episodeTitle'] as String?,
        shift: (json['shift'] as num?) ?? 0,
      );

  /// Accepts int / num / String IDs without losing string-form IDs.
  static String _id(Object? raw) => raw == null ? '' : '$raw';
}

/// One anime (season grouping) entry from the remote catalog
/// (`GET /api/v2/search/episodes` → `animes[]`), with its episodes.
class DanmakuCatalogAnime {
  const DanmakuCatalogAnime({
    required this.animeId,
    required this.animeTitle,
    required this.episodes,
    this.typeDescription,
  });

  final String animeId;
  final String animeTitle;
  final String? typeDescription;

  /// Catalog episodes; [DanmakuCatalogEpisode.episodeNumber] may be null
  /// (server sends `episodeNumber` as a string, or nothing at all — then the
  /// orchestrator parses [episodeTitle]).
  final List<DanmakuCatalogEpisode> episodes;
}

class DanmakuCatalogEpisode {
  const DanmakuCatalogEpisode({
    required this.episodeId,
    required this.episodeTitle,
    this.episodeNumber,
  });

  final String episodeId;
  final String episodeTitle;
  final int? episodeNumber;
}

/// Per-video scrape state as exposed to the UI.
class ScrapeEpisodeState {
  const ScrapeEpisodeState({
    required this.key,
    required this.fileName,
    required this.status,
    this.season,
    this.episode,
    this.ref,
    this.commentCount,
    this.error,
    this.fetchedAt,
  });

  final String key;
  final String fileName;
  final ScrapeStatus status;
  final int? season;
  final int? episode;
  final DanmakuEpisodeRef? ref;
  final int? commentCount;

  /// Human-readable failure reason (already friendly — no raw URLs/tokens).
  final String? error;
  final DateTime? fetchedAt;

  ScrapeEpisodeState copyWith({
    ScrapeStatus? status,
    DanmakuEpisodeRef? ref,
    int? commentCount,
    String? error,
    DateTime? fetchedAt,
    bool clearRef = false,
    bool clearError = false,
  }) => ScrapeEpisodeState(
    key: key,
    fileName: fileName,
    status: status ?? this.status,
    season: season,
    episode: episode,
    ref: clearRef ? null : (ref ?? this.ref),
    commentCount: commentCount ?? this.commentCount,
    error: clearError ? null : (error ?? this.error),
    fetchedAt: fetchedAt ?? this.fetchedAt,
  );
}

/// Whole-task snapshot; [SeriesScraper.state] is the live instance and the
/// counters are derived from the episode map on read.
class SeriesScrapeState {
  SeriesScrapeState({
    required this.scope,
    List<ScrapeEpisodeState> episodes = const [],
    this.phase = ScrapePhase.idle,
    this.generation = 0,
  }) : episodes = List.of(episodes);

  final SeriesScope scope;

  /// Live per-episode states, in the order the videos were submitted.
  final List<ScrapeEpisodeState> episodes;

  /// Coarse phase for the progress UI.
  ScrapePhase phase;

  /// Bumped by every new run; results from older generations are discarded.
  int generation;

  int get total => episodes.length;

  int count(ScrapeStatus s) => episodes.where((e) => e.status == s).length;

  int get pendingCount => count(ScrapeStatus.pending);
  int get cachedCount => count(ScrapeStatus.cached);
  int get matchedCount => count(ScrapeStatus.matched);
  int get fetchingCount => count(ScrapeStatus.fetching);
  int get successCount => count(ScrapeStatus.success);
  int get emptyCount => count(ScrapeStatus.empty);
  int get noMatchCount => count(ScrapeStatus.noMatch);
  int get failedCount => count(ScrapeStatus.failed);
  int get cancelledCount => count(ScrapeStatus.cancelled);

  /// Number of episodes that still need network work (not terminal and not
  /// cancelled).
  int get remainingCount => episodes
      .where((e) => !e.status.isTerminal && e.status != ScrapeStatus.cancelled)
      .length;

  bool get hasFailure => failedCount > 0;
}

/// Typed error surface between the source/repository adapters and the
/// orchestrator. [retryable] classifies 429/5xx/timeout (limited retry with
/// backoff) vs 401/403/4xx (credentials or config problems — fail fast).
class DanmakuScrapeException implements Exception {
  const DanmakuScrapeException(
    this.message, {
    this.statusCode,
    this.retryable = false,
  });

  final String message;
  final int? statusCode;
  final bool retryable;

  @override
  String toString() => message;
}
